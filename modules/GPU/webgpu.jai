DEBUG :: true;

WGpuHandle :: u64;

// JSPI: runtime.js wraps this in WebAssembly.Suspending so Present can yield.
jsWaitForFrame :: (fps: u32) #foreign;

WebGpuContext :: struct {
    ok: bool;
}

Context :: ($api: API) -> WebGpuContext
    #modify { return api == .WEBGPU, "This overload is for API.WEBGPU."; }
{
    ctx: WebGpuContext;
    // Device is requested in runtime.js before wasm_init; confirm it is ready.
    ctx.ok = jsWebGpuHasDevice() != 0;
    assert(ctx.ok, "WebGPU device not ready (runtime.js must requestDevice before wasm_init)");
    return ctx;
}

Context :: () -> WebGpuContext {
    return Context(.WEBGPU);
}

Destroy :: (ctx: *WebGpuContext) {
    ctx.ok = false;
}

WebGpuDevice :: struct {
    gpu_context: *WebGpuContext;
}

Device :: (ctx: *WebGpuContext) -> WebGpuDevice {
    assert(ctx && ctx.ok, "Device: invalid context");
    return .{gpu_context = ctx};
}

Destroy :: (dev: *WebGpuDevice) {
    dev.gpu_context = null;
}

WebGpuBuffer :: struct {
    device: *WebGpuDevice;
    size: u64;
    usage: BUFFER_USAGE;
    handle: WGpuHandle;
}

Buffer :: (dev: *WebGpuDevice, data: [] $T) -> WebGpuBuffer {
    usage := buffer_usage_for(T);
    buf: WebGpuBuffer;
    buf.device = dev;
    buf.size = xx (data.count * size_of(T));
    buf.usage = usage;

    // GPUBufferUsage: COPY_DST=0x8, INDEX=0x10, VERTEX=0x20, UNIFORM=0x40
    gpu_usage: u32 = 0x8; // COPY_DST (mappedAtCreation / writeBuffer)
    if usage == .VERTEX {
        gpu_usage |= 0x20;
    } else if usage == .INDEX {
        gpu_usage |= 0x10;
    } else {
        gpu_usage |= 0x40; // UNIFORM
    }

    data_ptr: *u8 = null;
    data_len: s64 = 0;
    if data.count {
        data_ptr = cast(*u8) data.data;
        data_len = xx buf.size;
    }
    buf.handle = jsCreateBuffer(gpu_usage, xx buf.size, data_ptr, data_len);
    return buf;
}

Destroy :: (buf: *WebGpuBuffer) {
    if buf.handle {
        jsDestroyHandle(buf.handle);
        buf.handle = 0;
    }
}

WebGpuTexture :: struct {
    device: *WebGpuDevice;
    size: Size2D;
    handle: WGpuHandle;
    depth_handle: WGpuHandle;
}

Texture :: (dev: *WebGpuDevice, size: Size2D) -> WebGpuTexture {
    tex: WebGpuTexture;
    tex.device = dev;
    tex.size = size;
    // TEXTURE_BINDING | RENDER_ATTACHMENT | COPY_SRC
    usage: u32 = 0x04 | 0x10 | 0x01;
    tex.handle = jsCreateTexture(size.width, size.height, usage, 0);
    return tex;
}

Get :: (tex: *WebGpuTexture) -> []u8 {
    // Optional readback — not used on web demo path.
    byte_count := cast(s64) (tex.size.width * tex.size.height * 4);
    out, _ := NewArray(byte_count, u8);
    return out;
}

Destroy :: (tex: *WebGpuTexture) {
    if tex.handle { jsDestroyHandle(tex.handle); tex.handle = 0; }
    if tex.depth_handle { jsDestroyHandle(tex.depth_handle); tex.depth_handle = 0; }
}

Update :: (tex: *WebGpuTexture, new_size: Size2D) {
    assert(tex.device != null, "Update: invalid texture");
    assert(new_size.width > 0 && new_size.height > 0, "Update: size must be non-zero");
    if tex.size.width == new_size.width && tex.size.height == new_size.height return;

    if tex.handle {
        jsDestroyHandle(tex.handle);
        tex.handle = 0;
    }
    // TEXTURE_BINDING | RENDER_ATTACHMENT | COPY_SRC
    usage: u32 = 0x04 | 0x10 | 0x01;
    tex.handle = jsCreateTexture(new_size.width, new_size.height, usage, 0);
    tex.size = new_size;
}

WebGpuSurface :: struct {
    device: *WebGpuDevice;
    window: *CrossWindowType;
    canvas_handle: WGpuHandle;
    last_time: float64;
    delta_time: float64;
    present_pipeline: WGpuHandle;
    sample_layout: WGpuHandle;
    sample_bind_group: WGpuHandle;
    sampler: WGpuHandle;
    present_shader: WGpuHandle;
}

Surface :: (dev: *WebGpuDevice, window: *CrossWindowType) -> WebGpuSurface {
    srf: WebGpuSurface;
    srf.device = dev;
    srf.window = window;
    srf.last_time = app_time();
    srf.canvas_handle = jsCreateSurface(window.name_id.data, xx window.name_id.count);
    jsConfigureSurface(srf.canvas_handle, window.width, window.height);

    srf.sample_layout = jsCreateBindGroupLayoutSampled();
    srf.sampler = jsCreateSampler();

    // Minimal fullscreen present shader (inline WGSL).
    present_wgsl := #string END
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;
struct VSOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f }
@vertex fn vs_fullscreen(@builtin(vertex_index) vid: u32) -> VSOut {
  var o: VSOut;
  let x = f32(i32(vid & 1u) * 4 - 1);
  let y = f32(i32(vid >> 1u) * 4 - 1);
  o.pos = vec4f(x, y, 0.0, 1.0);
  o.uv = vec2f((x + 1.0) * 0.5, (1.0 - y) * 0.5);
  return o;
}
@fragment fn fs_fullscreen(i: VSOut) -> @location(0) vec4f {
  return textureSample(tex, samp, i.uv);
}
END;
    srf.present_shader = jsCreateShaderModule(present_wgsl.data, xx present_wgsl.count);

    format_buf: [64]u8;
    n := jsGetPreferredSwapFormat(format_buf.data, 64);
    srf.present_pipeline = jsCreatePresentPipeline(
        srf.present_shader, srf.present_shader,
        srf.sample_layout,
        format_buf.data, n,
    );
    return srf;
}

Present :: (srf: *WebGpuSurface, tex: *WebGpuTexture, fps: u32) {
    assert(srf.canvas_handle && tex.handle, "Present: invalid args");

    if srf.window.width != tex.size.width || srf.window.height != tex.size.height {
        // Keep canvas in sync with offscreen when resized via PollWindowEvents.
        jsConfigureSurface(srf.canvas_handle, srf.window.width, srf.window.height);
    }

    if srf.sample_bind_group {
        jsDestroyHandle(srf.sample_bind_group);
    }
    srf.sample_bind_group = jsCreateBindGroupSampled(srf.sample_layout, srf.sampler, tex.handle);

    jsBeginCommands();
    jsBeginRenderPassToSurface(srf.canvas_handle, 0, 0, 0, 1);
    jsSetPipeline(srf.present_pipeline);
    jsSetBindGroup(0, srf.sample_bind_group);
    jsDraw(3);
    jsEndRenderPass();
    jsSubmit();

    // Yield to the browser (JSPI Suspending import). Resumes after rAF and
    // any extra frames needed to match `fps`, same role as sleep on host.
    jsWaitForFrame(fps);

    current_time := app_time();
    if srf.last_time > 0 {
        srf.delta_time = current_time - srf.last_time;
    }
    srf.last_time = current_time;
}

Destroy :: (srf: *WebGpuSurface) {
    if srf.sample_bind_group { jsDestroyHandle(srf.sample_bind_group); }
    if srf.present_pipeline { jsDestroyHandle(srf.present_pipeline); }
    if srf.present_shader { jsDestroyHandle(srf.present_shader); }
    if srf.sampler { jsDestroyHandle(srf.sampler); }
    if srf.sample_layout { jsDestroyHandle(srf.sample_layout); }
    if srf.canvas_handle { jsDestroyHandle(srf.canvas_handle); }
    srf.* = .{};
}

WebGpuFrameBuffer :: struct {
    device: *WebGpuDevice;
    textures: [..]*WebGpuTexture;
    depth_handle: WGpuHandle;
    depth_size: Size2D;
}

FrameBuffer :: (textures: .. *WebGpuTexture) -> WebGpuFrameBuffer {
    assert(textures.count > 0, "FrameBuffer requires a color texture");
    tex := textures[0];
    fb: WebGpuFrameBuffer;
    fb.device = tex.device;
    // Own a copy — the `..` slice is temporary and must not outlive this call.
    for textures array_add(*fb.textures, it);
    // DEPTH | RENDER_ATTACHMENT
    fb.depth_handle = jsCreateTexture(tex.size.width, tex.size.height, 0x10, 1);
    fb.depth_size = tex.size;
    tex.depth_handle = fb.depth_handle;
    return fb;
}

update_depth_texture_on_size_changed :: (frm_buf: *WebGpuFrameBuffer) {
    if frm_buf.textures.count == 0 || frm_buf.textures[0] == null return;
    tex := frm_buf.textures[0];
    if frm_buf.depth_handle
        && frm_buf.depth_size.width == tex.size.width
        && frm_buf.depth_size.height == tex.size.height return;

    if frm_buf.depth_handle {
        jsDestroyHandle(frm_buf.depth_handle);
        frm_buf.depth_handle = 0;
    }
    // DEPTH | RENDER_ATTACHMENT
    frm_buf.depth_handle = jsCreateTexture(tex.size.width, tex.size.height, 0x10, 1);
    frm_buf.depth_size = tex.size;
    tex.depth_handle = frm_buf.depth_handle;
}

Destroy :: (frm_buf: *WebGpuFrameBuffer) {
    if frm_buf.depth_handle {
        jsDestroyHandle(frm_buf.depth_handle);
        frm_buf.depth_handle = 0;
    }
    array_free(frm_buf.textures);
}

// Host-baked triangle WGSL (slangc). No libslang in the .wasm.
WEBGPU_TRIANGLE_SHADER_MEMBERS :: #run,host -> string {
    #import "Basic";
    #import "String";
    File :: #import "File";
    Process :: #import "Process";

    File.make_directory_if_it_does_not_exist(".bin/.build", recursive = true);
    // Nix FHS LD_LIBRARY_PATH stack-smashes the host slangc binary — clear it.
    result, stdout, stderr := Process.run_command(
        "env", "-u", "LD_LIBRARY_PATH",
        "slangc", "assets/shaders/triangle.slang",
        "-target", "wgsl",
        "-matrix-layout-row-major",
        "-entry", "vs_main", "-stage", "vertex",
        "-entry", "fs_main", "-stage", "fragment",
        "-o", ".bin/.build/triangle.wgsl",
        capture_and_return_output = true,
    );
    assert(result.type != .FAILED_TO_LAUNCH, "slangc not found on PATH");
    assert(result.exit_code == 0, "slangc triangle→wgsl failed:\n%\n%", stdout, stderr);
    data, ok := File.read_entire_file(".bin/.build/triangle.wgsl");
    assert(ok && data.count > 0, "read triangle.wgsl failed");

    MATRIX4_BYTES :: 64;

    builder: String_Builder;
    print_to_builder(*builder, "Vertex_t :: struct {\n");
    print_to_builder(*builder, "    GPU_USAGE :: BUFFER_USAGE.VERTEX;\n");
    print_to_builder(*builder, "    Pos: Vector3;\n");
    print_to_builder(*builder, "    Color: Vector3;\n");
    print_to_builder(*builder, "};\n\n");
    print_to_builder(*builder, "MVP :: VulkanShaderUniformDefinition.{\n");
    print_to_builder(*builder, "    name = \"MVP\",\n");
    print_to_builder(*builder, "    type = type_of(Matrix4),\n");
    print_to_builder(*builder, "    offset = 0,\n");
    print_to_builder(*builder, "    set = 0,\n");
    print_to_builder(*builder, "    binding = 0,\n");
    print_to_builder(*builder, "    stage_flags = 1,\n");
    print_to_builder(*builder, "};\n\n");
    print_to_builder(*builder, "vs_entry :: \"vs_main\";\n");
    print_to_builder(*builder, "fs_entry :: \"fs_main\";\n");
    print_to_builder(*builder, "push_constant_bytes :: %;\n\n", MATRIX4_BYTES);
    // spirv_raw holds baked WGSL source bytes (name kept for parity with VulkanShader).
    print_to_builder(*builder, "spirv_raw :: u8.[\n");
    for i: 0..data.count-1 {
        print_to_builder(*builder, "%,", data[i]);
        if (i + 1) % 16 == 0 then print_to_builder(*builder, "\n");
    }
    print_to_builder(*builder, "\n];\n");
    return builder_to_string(*builder);
}

WebGpuShader :: struct ($path: string, $stages: []string) {
    device: *WebGpuDevice;
    module_handle: WGpuHandle;
    pipeline: WGpuHandle;
    uniform_layout: WGpuHandle;
    uniform_buffer: WGpuHandle;
    bind_group: WGpuHandle;
    #insert -> string {
        if equal(path, "assets/shaders/triangle.slang") || ends_with(path, "triangle.slang") {
            return WEBGPU_TRIANGLE_SHADER_MEMBERS;
        }
        assert(false, "WebGPU: no host-baked WGSL for '%'", path);
        return "";
    }
}

// Shared with vulkan Set path.
VulkanShaderUniformDefinition :: struct {
    name: string;
    type: Type;
    offset: u32;
    set: u32;
    binding: u32;
    stage_flags: u32;
}

is_push_constant :: (d: VulkanShaderUniformDefinition) -> bool {
    return d.set == VULKAN_UNIFORM_PUSH_CONSTANT && d.binding == VULKAN_UNIFORM_PUSH_CONSTANT;
}

Spawn :: (dev: *WebGpuDevice, $path: string, $stages: []string) -> WebGpuShader(path, stages) {
    Shader_t :: WebGpuShader(path, stages);
    shdr: Shader_t;
    shdr.device = dev;
    assert(Shader_t.spirv_raw.count > 0, "Spawn: empty WGSL for '%'", path);

    shdr.module_handle = jsCreateShaderModule(Shader_t.spirv_raw.data, xx Shader_t.spirv_raw.count);
    shdr.uniform_layout = jsCreateBindGroupLayoutUniform();
    shdr.uniform_buffer = jsCreateUniformBuffer(Shader_t.push_constant_bytes);
    shdr.bind_group = jsCreateBindGroupUniform(shdr.uniform_layout, shdr.uniform_buffer);

    stride := cast(u32) size_of(Shader_t.Vertex_t);
    shdr.pipeline = jsCreateRenderPipeline(
        shdr.module_handle, Shader_t.vs_entry.data, xx Shader_t.vs_entry.count,
        shdr.module_handle, Shader_t.fs_entry.data, xx Shader_t.fs_entry.count,
        stride, 1,
        0, 1,
        shdr.uniform_layout,
    );
    return shdr;
}

Destroy :: (shdr: *WebGpuShader($path, $stages)) {
    if shdr.bind_group { jsDestroyHandle(shdr.bind_group); }
    if shdr.uniform_buffer { jsDestroyHandle(shdr.uniform_buffer); }
    if shdr.uniform_layout { jsDestroyHandle(shdr.uniform_layout); }
    if shdr.pipeline { jsDestroyHandle(shdr.pipeline); }
    if shdr.module_handle { jsDestroyHandle(shdr.module_handle); }
}

WebGpuPass :: struct(WebGpuShader_t: Type) {
    queue: *WebGpuQueue;
    shader: *WebGpuShader_t;
}

WebGpuQueue :: struct {
    device: *WebGpuDevice;
    type: QUEUE_TYPE;
    bound_framebuffer: *WebGpuFrameBuffer;
    index_count: u32;
    vertex_handle: WGpuHandle;
    index_handle: WGpuHandle;
    recording: bool;
}

Queue :: (dev: *WebGpuDevice, type: QUEUE_TYPE) -> WebGpuQueue {
    assert(type == .GRAPHICS, "Only GRAPHICS queue implemented");
    return .{
        device = dev,
        type = type,
        bound_framebuffer = null,
        index_count = 0,
        recording = false,
    };
}

Bind :: (q: *WebGpuQueue, frm_buf: *WebGpuFrameBuffer) {
    update_depth_texture_on_size_changed(frm_buf);
    q.bound_framebuffer = frm_buf;
    q.index_count = 0;
    q.vertex_handle = 0;
    q.index_handle = 0;
    if !q.recording {
        jsBeginCommands();
        q.recording = true;
    }
    color := frm_buf.textures[0];
    jsBeginRenderPassToTexture(
        color.handle, frm_buf.depth_handle,
        0.0, 0.0, 0.2, 1.0,
    );
}

Pass :: (q: *WebGpuQueue, shdr: *WebGpuShader($path, $stages)) -> [1]WebGpuPass(WebGpuShader(path, stages)) {
    assert(q.bound_framebuffer != null, "Pass: Bind a FrameBuffer before Pass");
    jsSetPipeline(shdr.pipeline);
    return .[.{queue = q, shader = shdr}];
}

Set :: (buf: *WebGpuBuffer) #expand {
    Set(`it, buf);
}

Set :: (pass: WebGpuPass($S), buf: *WebGpuBuffer) {
    q := pass.queue;
    if buf.usage == .VERTEX {
        q.vertex_handle = buf.handle;
        jsSetVertexBuffer(0, buf.handle);
    } else if buf.usage == .INDEX {
        q.index_handle = buf.handle;
        q.index_count = cast(u32) (buf.size / size_of(u32));
        jsSetIndexBuffer(buf.handle);
    } else {
        assert(false, "Set(buffer): expected VERTEX or INDEX");
    }
}

Set :: (def: VulkanShaderUniformDefinition, val: $T) #expand {
    Set(`it, def, val);
}

Set :: (pass: WebGpuPass($S), def: VulkanShaderUniformDefinition, val: $T) {
    shdr := pass.shader;
    jsWriteBuffer(shdr.uniform_buffer, def.offset, cast(*u8)*val, xx size_of(T));
    jsSetBindGroup(0, shdr.bind_group);
}

Record :: () #expand {
    Record(`it);
}

Record :: (pass: WebGpuPass($S)) {
    q := pass.queue;
    assert(q.index_count > 0, "Record: no index buffer Set");
    jsDrawIndexed(q.index_count);
}

Submit :: (q: *WebGpuQueue, wait: bool) {
    if q.recording {
        jsEndRenderPass();
        jsSubmit();
        q.recording = false;
    }
}

// ---------- foreign JS imports ----------

jsWebGpuHasDevice :: () -> s32 #foreign;
jsCreateBuffer :: (usage: u32, size: u64, data: *u8, data_len: s64) -> WGpuHandle #foreign;
jsCreateTexture :: (width: u32, height: u32, usage: u32, format: u32) -> WGpuHandle #foreign;
jsCreateShaderModule :: (code: *u8, code_len: s64) -> WGpuHandle #foreign;
jsCreateUniformBuffer :: (size: u32) -> WGpuHandle #foreign;
jsWriteBuffer :: (buf: WGpuHandle, offset: u32, data: *u8, data_len: s64) #foreign;
jsCreateRenderPipeline :: (
    vs_mod: WGpuHandle, vs_entry: *u8, vs_entry_len: s64,
    fs_mod: WGpuHandle, fs_entry: *u8, fs_entry_len: s64,
    stride: u32, has_color_attr: s32,
    topology: s32, depth_enabled: s32,
    bind_group_layout: WGpuHandle,
) -> WGpuHandle #foreign;
jsCreatePresentPipeline :: (
    vs_mod: WGpuHandle, fs_mod: WGpuHandle, sample_layout: WGpuHandle,
    swap_format: *u8, swap_format_len: s64,
) -> WGpuHandle #foreign;
jsCreateBindGroupLayoutUniform :: () -> WGpuHandle #foreign;
jsCreateBindGroupLayoutSampled :: () -> WGpuHandle #foreign;
jsCreateBindGroupUniform :: (layout: WGpuHandle, buffer: WGpuHandle) -> WGpuHandle #foreign;
jsCreateBindGroupSampled :: (layout: WGpuHandle, sampler: WGpuHandle, tex: WGpuHandle) -> WGpuHandle #foreign;
jsCreateSampler :: () -> WGpuHandle #foreign;
jsCreateSurface :: (id: *u8, id_len: s64) -> WGpuHandle #foreign;
jsConfigureSurface :: (surface: WGpuHandle, width: u32, height: u32) -> WGpuHandle #foreign;
jsGetPreferredSwapFormat :: (out: *u8, out_cap: s64) -> s64 #foreign;
jsBeginCommands :: () -> s32 #foreign;
jsBeginRenderPassToTexture :: (color: WGpuHandle, depth: WGpuHandle, r: float, g: float, b: float, a: float) #foreign;
jsBeginRenderPassToSurface :: (surface: WGpuHandle, r: float, g: float, b: float, a: float) #foreign;
jsSetPipeline :: (pipe: WGpuHandle) #foreign;
jsSetVertexBuffer :: (slot: u32, buf: WGpuHandle) #foreign;
jsSetIndexBuffer :: (buf: WGpuHandle) #foreign;
jsSetBindGroup :: (index: u32, bg: WGpuHandle) #foreign;
jsDrawIndexed :: (index_count: u32) #foreign;
jsDraw :: (vertex_count: u32) #foreign;
jsEndRenderPass :: () #foreign;
jsSubmit :: () #foreign;
jsDestroyHandle :: (handle: WGpuHandle) #foreign;
