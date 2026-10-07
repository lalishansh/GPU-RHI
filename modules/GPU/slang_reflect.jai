SlangVaryingType :: struct {
    name: string;
    type: *Type_Info;
}

SlangUniformType :: struct {
    name: string;
    type: *Type_Info;
    offset: u32;
    set: u32;
    binding: u32;
    stage_flags: u32;
}

SlangShaderType :: enum u8 {
    COMPUTE_SHADER;
    VERTEX_SHADER;
    FRAGMENT_SHADER;
};

SlangShaderEntryPointType :: struct {
    name: string;
    type: SlangShaderType;
    threadGroupSize: [3]u32 = .[1, 1, 1];
    inputs: []SlangVaryingType;
    outputs: []SlangVaryingType;
    uniforms: []SlangUniformType;
};

ShaderBlueprint :: struct {
    entry_points: [..]SlangShaderEntryPointType;
    uniforms: [..]SlangUniformType;
    spirv: [..]u8;
};

// Compiles + reflects a .slang file path (e.g. inside VulkanShader #insert).
Shader :: ($path: string) -> ShaderBlueprint {
    blueprint: ShaderBlueprint;
    reflect_via_slang_api(path, *blueprint);
    return blueprint;
}

// Compiles + reflects an in-memory Slang source string (no file I/O).
ShaderString :: (slang_shader_str: string, module_name := "embedded") -> ShaderBlueprint {
    blueprint: ShaderBlueprint;
    reflect_via_slang_source(slang_shader_str, module_name, *blueprint);
    return blueprint;
}

slang_create_session :: () -> *slang.ISession {
    if !slang_global_session {
        assert(
            slang.SLANG_SUCCEEDED(slang.slang_createGlobalSession(slang.SLANG_API_VERSION, *slang_global_session)),
            "slang_createGlobalSession failed",
        );
    }

    target: slang.TargetDesc;
    #if OS == .WASM {
        target.format = .WGSL;
        target.profile = slang.IGlobalSession_findProfile(slang_global_session, temp_c_string("spirv_1_3"));
    } else {
        target.format = .SPIRV;
        target.profile = slang.IGlobalSession_findProfile(slang_global_session, temp_c_string("spirv_1_3"));
    }

    session_desc: slang.SessionDesc;
    session_desc.targets = *target;
    session_desc.targetCount = 1;
    // Match Math::Matrix4 (row-major). Equivalent to slangc -matrix-layout-row-major.
    session_desc.defaultMatrixLayoutMode = .ROW_MAJOR;

    session: *slang.ISession;
    assert(
        slang.SLANG_SUCCEEDED(slang.IGlobalSession_createSession(slang_global_session, *session_desc, *session)),
        "createSession failed",
    );
    return session;
}

// Mirrors VkPlayground GPU/module.jai: loadModule → entry points → compose → link → getLayout + getTargetCode
reflect_via_slang_api :: (path: string, blueprint: *ShaderBlueprint) {
    session := slang_create_session();
    defer slang_release(session);

    diagnostics: *slang.IBlob;
    module := slang.ISession_loadModule(session, temp_c_string(path), *diagnostics);
    slang_print_diagnostics(diagnostics);
    assert(module != null, "loadModule failed for '%'", path);

    reflect_loaded_module(session, module, path, blueprint);
}

reflect_via_slang_source :: (source: string, module_name: string, blueprint: *ShaderBlueprint) {
    session := slang_create_session();
    defer slang_release(session);

    diagnostics: *slang.IBlob;
    name_c := temp_c_string(module_name);
    // path arg is only used for diagnostics / include resolution.
    module := slang.ISession_loadModuleFromSourceString(
        session, name_c, name_c, temp_c_string(source), *diagnostics,
    );
    slang_print_diagnostics(diagnostics);
    assert(module != null, "loadModuleFromSourceString failed for '%'", module_name);

    reflect_loaded_module(session, module, module_name, blueprint);
}

reflect_loaded_module :: (
    session: *slang.ISession,
    module: *slang.IModule,
    label: string,
    blueprint: *ShaderBlueprint,
) {
    ep_count := slang.IModule_getDefinedEntryPointCount(module);
    components: [..]*slang.IComponentType;
    defer array_free(components);

    // Module must be part of the composite (see slang compilation-api docs).
    array_add(*components, xx module);

    for i: 0..ep_count-1 {
        entry: *slang.IEntryPoint;
        assert(
            slang.SLANG_SUCCEEDED(slang.IModule_getDefinedEntryPoint(module, xx i, *entry)),
            "getDefinedEntryPoint(%) failed", i,
        );
        array_add(*components, xx entry);
    }

    composed: *slang.IComponentType;
    diagnostics: *slang.IBlob = null;
    assert(
        slang.SLANG_SUCCEEDED(slang.ISession_createCompositeComponentType(
            session, components.data, xx components.count, *composed, *diagnostics,
        )),
        "createCompositeComponentType failed",
    );
    defer slang_release(composed);
    slang_print_diagnostics(diagnostics);

    linked: *slang.IComponentType;
    diagnostics = null;
    assert(
        slang.SLANG_SUCCEEDED(slang.IComponentType_link(composed, *linked, *diagnostics)),
        "link failed",
    );
    defer slang_release(linked);
    slang_print_diagnostics(diagnostics);

    // SPIR-V first so layout reflection has a fully lowered target program.
    code_blob: *slang.IBlob;
    diagnostics = null;
    assert(
        slang.SLANG_SUCCEEDED(slang.IComponentType_getTargetCode(linked, 0, *code_blob, *diagnostics)),
        "getTargetCode failed for '%'", label,
    );
    defer slang_release(code_blob);
    slang_print_diagnostics(diagnostics);
    assert(code_blob != null, "getTargetCode returned null for '%'", label);

    size := slang.ISlangBlob_getBufferSize(code_blob);
    assert(size > 0, "empty shader target code for '%'", label);
    ptr := cast(*u8) slang.ISlangBlob_getBufferPointer(code_blob);
    array_reserve(*blueprint.spirv, xx size);
    for i: 0..size-1 {
        array_add(*blueprint.spirv, ptr[i]);
    }

    diagnostics = null;
    layout := slang.IComponentType_getLayout(linked, 0, *diagnostics);
    slang_print_diagnostics(diagnostics);
    assert(layout != null, "getLayout failed");

    reflection := cast(*slang.SlangReflection) layout;
    collect_from_program_layout(reflection, blueprint);
}

collect_from_program_layout :: (reflection: *slang.SlangReflection, blueprint: *ShaderBlueprint) {
    ep_count := slang.spReflection_getEntryPointCount(reflection);
    for i: 0..ep_count-1 {
        ep := slang.spReflection_getEntryPointByIndex(reflection, xx i);
        if !ep continue;

        name_c := slang.spReflectionEntryPoint_getName(ep);
        assert(name_c != null, "entry point % has no name", i);

        stage := slang.spReflectionEntryPoint_getStage(ep);
        ep_info: SlangShaderEntryPointType;
        ep_info.name = copy_string(to_string(name_c));
        ep_info.type = slang_stage_to_shader_type(stage);

        if stage == .COMPUTE {
            sizes: [3]slang.SlangUInt = .[1, 1, 1];
            slang.spReflectionEntryPoint_getComputeThreadGroupSize(ep, 3, *sizes[0]);
            ep_info.threadGroupSize = .[xx sizes[0], xx sizes[1], xx sizes[2]];
        }

        inputs: [..]SlangVaryingType;
        outputs: [..]SlangVaryingType;
        uniforms: [..]SlangUniformType;

        param_count := slang.spReflectionEntryPoint_getParameterCount(ep);
        for p: 0..param_count-1 {
            param := slang.spReflectionEntryPoint_getParameterByIndex(ep, p);
            if !param continue;
            collect_variable_layout(param, *inputs, *outputs, *uniforms, *blueprint.uniforms, stage);
        }

        result_layout := slang.spReflectionEntryPoint_getResultVarLayout(ep);
        if result_layout {
            collect_variable_layout(result_layout, *inputs, *outputs, *uniforms, *blueprint.uniforms, stage);
        }

        ep_info.inputs = inputs;
        ep_info.outputs = outputs;
        ep_info.uniforms = uniforms;
        array_add(*blueprint.entry_points, ep_info);
    }
}

collect_variable_layout :: (
    var_layout: *slang.SlangReflectionVariableLayout,
    inputs: *[..]SlangVaryingType,
    outputs: *[..]SlangVaryingType,
    entry_uniforms: *[..]SlangUniformType,
    blueprint_uniforms: *[..]SlangUniformType,
    entry_stage: slang.SlangStage,
) {
    variable := slang.spReflectionVariableLayout_GetVariable(var_layout);
    type_layout := slang.spReflectionVariableLayout_GetTypeLayout(var_layout);
    if !variable || !type_layout return;

    type := slang.spReflectionTypeLayout_GetType(type_layout);
    if !type return;

    name_c := slang.spReflectionVariable_GetName(variable);
    name := ifx name_c then copy_string(to_string(name_c)) else "";

    category := slang.spReflectionTypeLayout_GetParameterCategory(type_layout);

    if category == .VARYING_INPUT || category == .VERTEX_INPUT {
        append_reflected_varyings(type, name, inputs);
        return;
    }

    if category == .VARYING_OUTPUT || category == .FRAGMENT_OUTPUT {
        append_reflected_varyings(type, name, outputs);
        return;
    }

    if category == .UNIFORM || category == .PUSH_CONSTANT_BUFFER || category == .CONSTANT_BUFFER {
        leaf := unwrap_container_type(type);
        offset := cast(u32) slang.spReflectionVariableLayout_GetOffset(var_layout, category);

        // Descriptor binding if ConstantBuffer; entry-point `uniform T` → push constant.
        set: u32 = VULKAN_UNIFORM_PUSH_CONSTANT;
        binding: u32 = VULKAN_UNIFORM_PUSH_CONSTANT;
        if category == .CONSTANT_BUFFER {
            set = cast(u32) slang.spReflectionVariableLayout_GetSpace(var_layout, .DESCRIPTOR_TABLE_SLOT);
            binding = cast(u32) slang.spReflectionVariableLayout_GetOffset(var_layout, .DESCRIPTOR_TABLE_SLOT);
        }

        uniform := SlangUniformType.{
            name = name,
            type = slang_type_to_type_info(leaf),
            offset = offset,
            set = set,
            binding = binding,
            stage_flags = slang_stage_to_vk_flags(entry_stage),
        };

        for blueprint_uniforms.* {
            if it.name == name return;
        }
        array_add(entry_uniforms, uniform);
        array_add(blueprint_uniforms, uniform);
    }
}

append_reflected_varyings :: (type: *slang.SlangReflectionType, fallback_name: string, out: *[..]SlangVaryingType) {
    kind := slang.spReflectionType_GetKind(type);
    if kind == .STRUCT {
        field_count := slang.spReflectionType_GetFieldCount(type);
        for f: 0..field_count-1 {
            field_var := slang.spReflectionType_GetFieldByIndex(type, f);
            if !field_var continue;
            fname_c := slang.spReflectionVariable_GetName(field_var);
            ftype := slang.spReflectionVariable_GetType(field_var);
            if !fname_c || !ftype continue;
            array_add(out, .{
                name = copy_string(to_string(fname_c)),
                type = slang_type_to_type_info(ftype),
            });
        }
    } else {
        array_add(out, .{
            name = fallback_name,
            type = slang_type_to_type_info(type),
        });
    }
}

unwrap_container_type :: (type: *slang.SlangReflectionType) -> *slang.SlangReflectionType {
    t := type;
    // Cap iterations — a self-referential element type would loop forever.
    for _i: 0..7 {
        if !t break;
        kind := slang.spReflectionType_GetKind(t);
        if kind != .CONSTANT_BUFFER && kind != .PARAMETER_BLOCK && kind != .TEXTURE_BUFFER && kind != .SHADER_STORAGE_BUFFER {
            break;
        }
        next := slang.spReflectionType_GetElementType(t);
        if !next || next == t break;
        t = next;
    }
    return t;
}

slang_type_to_type_info :: (type: *slang.SlangReflectionType) -> *Type_Info {
    type = unwrap_container_type(type);
    kind := slang.spReflectionType_GetKind(type);

    if kind == {
    case .SCALAR;
        return scalar_to_type_info(slang.spReflectionType_GetScalarType(type));
    case .VECTOR;
        n := slang.spReflectionType_GetElementCount(type);
        scalar := slang.spReflectionType_GetScalarType(type);
        if scalar == .FLOAT32 {
            if n == 2 return type_info(Vector2);
            if n == 3 return type_info(Vector3);
            if n == 4 return type_info(Vector4);
        }
        return scalar_to_type_info(scalar);
    case .MATRIX;
        rows := slang.spReflectionType_GetRowCount(type);
        cols := slang.spReflectionType_GetColumnCount(type);
        scalar := slang.spReflectionType_GetScalarType(type);
        if scalar == .FLOAT32 && rows == 4 && cols == 4 return type_info(Matrix4);
        if scalar == .FLOAT32 && rows == 3 && cols == 3 return type_info(Matrix3);
        return type_info(Matrix4);
    }

    return type_info(void);
}

type_info_source_name :: (info: *Type_Info) -> string {
    if info == type_info(Matrix4)  return "Matrix4";
    if info == type_info(Matrix3)  return "Matrix3";
    if info == type_info(Vector4)  return "Vector4";
    if info == type_info(Vector3)  return "Vector3";
    if info == type_info(Vector2)  return "Vector2";
    if info == type_info(float)    return "float";
    if info == type_info(float64)  return "float64";
    if info == type_info(u32)      return "u32";
    if info == type_info(s32)      return "s32";
    if info == type_info(u64)      return "u64";
    if info == type_info(s64)      return "s64";
    if info == type_info(u16)      return "u16";
    if info == type_info(s16)      return "s16";
    if info == type_info(u8)       return "u8";
    if info == type_info(s8)       return "s8";
    if info == type_info(bool)     return "bool";
    if info.type == .STRUCT {
        si := cast(*Type_Info_Struct) info;
        if si.name.count return si.name;
    }
    return "void";
}

scalar_to_type_info :: (s: slang.SlangScalarType) -> *Type_Info {
    if s == {
    case .FLOAT32; return type_info(float);
    case .FLOAT64; return type_info(float64);
    case .INT32;   return type_info(s32);
    case .UINT32;  return type_info(u32);
    case .INT64;   return type_info(s64);
    case .UINT64;  return type_info(u64);
    case .INT16;   return type_info(s16);
    case .UINT16;  return type_info(u16);
    case .INT8;    return type_info(s8);
    case .UINT8;   return type_info(u8);
    case .BOOL;    return type_info(bool);
    case;          return type_info(float);
    }
}

slang_stage_to_shader_type :: (stage: slang.SlangStage) -> SlangShaderType {
    if stage == {
    case .VERTEX;   return .VERTEX_SHADER;
    case .FRAGMENT; return .FRAGMENT_SHADER;
    case .COMPUTE;  return .COMPUTE_SHADER;
    case;           return .FRAGMENT_SHADER;
    }
}

slang_stage_to_vk_flags :: (stage: slang.SlangStage) -> u32 {
    // VK_SHADER_STAGE_* bit values (avoid depending on Vulkan module during wasm builds).
    if stage == {
    case .VERTEX;   return 0x00000001;
    case .FRAGMENT; return 0x00000010;
    case .COMPUTE;  return 0x00000020;
    case;           return 0x00000001;
    }
}

slang_release :: (obj: *$T) {
    if obj then slang.ISlangUnknown_release(xx obj);
}

slang_print_diagnostics :: (blob: *slang.IBlob) {
    if !blob return;
    defer slang_release(blob);
    size := slang.ISlangBlob_getBufferSize(blob);
    if !size return;
    msg: string = .{data = xx slang.ISlangBlob_getBufferPointer(blob), count = xx size};
    print("%\n", msg);
}

slang_global_session: *slang.IGlobalSession;
