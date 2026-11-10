OUT_DIR :: ".bin";
BUILD_DIR :: ".bin/.build";
ASSETS_DIR :: "assets";

OUTPUT_EXECUTABLE_NAME :: "main";
ANDROID_APP_NAME :: "GPU-RHI Native";
ANDROID_APP_ID   :: "jai.gpu_rhi_native";

// Host example suite (NVRHI-style). Filter: jai build.jai - host 06_draw_geometry
HOST_EXAMPLES :: string.[
    "01_device_and_debug",
    "02_surface",
    "02b_multiwindow",
    "03_graphics_pipeline",
    "04_resources",
    "05_fill_resources",
    "06_draw_geometry",
    "07_headless",
    "08_deferred",
    "09_cubemaps",
    "10_gpu_particles",
    "11_threaded_rendering",
    "12_shader_stages",
    "13_slang_features",
    "14_cornell_raster",
    "15_cornell_compute",
    "16_imgui",
    "rt01_acceleration_structures",
    "rt02_ray_pipelines",
    "rt03_dispatch_rays",
];

// Web examples (filter: jai build.jai - web 02_surface). Emits .bin/<name>.js with embedded wasm.
WEB_EXAMPLES :: string.[
    "01_device_and_debug",
    "02_surface",
    "02b_multiwindow",
    "03_graphics_pipeline",
    "04_resources",
    "05_fill_resources",
    "06_draw_geometry",
    "07_headless",
    "14_cornell_raster",
    "15_cornell_compute",
    "16_imgui",
];

// Android NativeActivity examples (filter: jai build.jai - android 02_surface install).
// Default when no filter: 02_surface. APK lib is still named libmain.so (NativeActivity meta-data).
ANDROID_EXAMPLES :: string.[
    "02_surface",
    "14_cornell_raster",
    "15_cornell_compute",
    "16_imgui",
];

#run {
    set_build_options_dc(.{do_output = false});

    make_directory_if_it_does_not_exist(OUT_DIR);

    if OS == .LINUX {
        for split(to_string(getenv("LD_LIBRARY_PATH")), ":") {
            if it.count compiler_add_library_search_directory(it);
        }
    }

    args := get_build_options().compile_time_command_line;
    wants_web     := array_find(args, "web") || array_find(args, "-web");
    wants_host    := array_find(args, "host") || array_find(args, "-host");
    wants_android := array_find(args, "android") || array_find(args, "-android");
    target_x64    := array_find(args, "x64") || array_find(args, "-x64");
    target_arm    := array_find(args, "arm64") || array_find(args, "-arm64");
    do_install    := array_find(args, "install") || array_find(args, "-install");

    target_count := 0;
    if wants_web     target_count += 1;
    if wants_host    target_count += 1;
    if wants_android target_count += 1;
    if target_count > 1 {
        log_error("Specify one of: host, web, android.\n");
        exit(1);
    }
    if target_count == 0 then wants_host = true;

    if wants_web {
        build_web(args);
    } else if wants_android {
        build_android(args, target_x64, target_arm, do_install);
    } else {
        build_host(args);
    }
}

Debug_Executable :: struct {
    workspace_name: string;
    executable_name: string;
    output_path: string; // directory containing the executable
}

add_host_executable :: (workspace_name: string, source_file: string, executable_name: string, debug_targets: *[..] Debug_Executable) {
    w := compiler_create_workspace(workspace_name);
    options := get_build_options();
    options.output_type = .EXECUTABLE;
    options.output_executable_name = executable_name;
    options.output_path = OUT_DIR;
    options.intermediate_path = BUILD_DIR;
    options.emit_debug_info = .DWARF;
    set_optimization(*options, .VERY_DEBUG);
    set_build_options(options, w);
    add_build_file(source_file, w);
    array_add(debug_targets, .{
        workspace_name = workspace_name,
        executable_name = executable_name,
        output_path = OUT_DIR,
    });
}

build_host :: (args: [] string) {
    debug_targets: [..] Debug_Executable;

    if OS == .LINUX {
        compiler_add_library_search_directory("modules/slang/linux");
        for split(to_string(getenv("JAI_LD_LIBRARY_PATH")), ":") {
            if it.count compiler_add_library_search_directory(it);
        }
    }

    filter := "";
    for args {
        if it == "host" || it == "-host" || it == "web" || it == "-web" || it == "android" || it == "-android" continue;
        if begins_with(it, "-") continue;
        filter = it;
        break;
    }

    built := 0;
    for HOST_EXAMPLES {
        if filter.count && filter != it continue;
        source := tprint("examples/%/%.jai", it, it);
        workspace := tprint("Example %", it);
        add_host_executable(workspace, source, it, *debug_targets);
        built += 1;
    }
    if !built {
        log_error("No host examples matched filter '%'.\n", filter);
        exit(1);
    }
    log("Building % host example(s).", built);

    copy_assets_to_out(ASSETS_DIR, string.[
        "display.py",
    ]);
    copy_assets_to_out(tprint("%/%", ASSETS_DIR, "lib"), string.[
        "libslang-glslang-2025.24.so",
        "libslang-compiler.so.0.2025.24",
    ]);

    generate_vscode_gdb_debug_tasks(debug_targets);
}

// Writes .vscode/tasks.json + launch.json with a Build & Debug (gdb) entry
// for every host workspace that emits an executable.
generate_vscode_gdb_debug_tasks :: (targets: [] Debug_Executable) {
    if !targets.count return;

    make_directory_if_it_does_not_exist(".vscode");

    // --- tasks.json ---
    tasks: String_Builder;
    print_to_builder(*tasks, "{\n");
    print_to_builder(*tasks, "    // Auto-generated by build.jai (host). Do not edit by hand.\n");
    print_to_builder(*tasks, "    \"version\": \"2.0.0\",\n");
    print_to_builder(*tasks, "    \"tasks\": [\n");
    print_to_builder(*tasks, "        {\n");
    print_to_builder(*tasks, "            \"label\": \"build: host\",\n");
    print_to_builder(*tasks, "            \"type\": \"shell\",\n");
    print_to_builder(*tasks, "            \"command\": \"jai build.jai - host\",\n");
    print_to_builder(*tasks, "            \"options\": {\n");
    print_to_builder(*tasks, "                \"cwd\": \"${workspaceFolder}\"\n");
    print_to_builder(*tasks, "            },\n");
    print_to_builder(*tasks, "            \"group\": {\n");
    print_to_builder(*tasks, "                \"kind\": \"build\",\n");
    print_to_builder(*tasks, "                \"isDefault\": true\n");
    print_to_builder(*tasks, "            },\n");
    print_to_builder(*tasks, "            \"problemMatcher\": [\n");
    print_to_builder(*tasks, "                {\n");
    print_to_builder(*tasks, "                    \"owner\": \"jai\",\n");
    print_to_builder(*tasks, "                    \"fileLocation\": \"absolute\",\n");
    print_to_builder(*tasks, "                    \"pattern\": [\n");
    print_to_builder(*tasks, "                        {\n");
    print_to_builder(*tasks, "                            \"regexp\": \"^(.*):(\\\\d+),(\\\\d+): Error: (.*)$\",\n");
    print_to_builder(*tasks, "                            \"file\": 1,\n");
    print_to_builder(*tasks, "                            \"line\": 2,\n");
    print_to_builder(*tasks, "                            \"column\": 3,\n");
    print_to_builder(*tasks, "                            \"message\": 4\n");
    print_to_builder(*tasks, "                        }\n");
    print_to_builder(*tasks, "                    ]\n");
    print_to_builder(*tasks, "                }\n");
    print_to_builder(*tasks, "            ]\n");
    print_to_builder(*tasks, "        }\n");
    print_to_builder(*tasks, "    ]\n");
    print_to_builder(*tasks, "}\n");

    tasks_path := ".vscode/tasks.json";
    if !write_entire_file(tasks_path, *tasks) {
        log_error("Failed to write %\n", tasks_path);
    } else {
        log("Wrote %", tasks_path);
    }

    // --- launch.json ---
    launch: String_Builder;
    print_to_builder(*launch, "{\n");
    print_to_builder(*launch, "    // Auto-generated by build.jai (host). Do not edit by hand.\n");
    print_to_builder(*launch, "    \"version\": \"0.2.0\",\n");
    print_to_builder(*launch, "    \"configurations\": [\n");

    for it, i: targets {
        program_rel := tprint("%/%", it.output_path, it.executable_name);
        name := tprint("Build & Debug: %", it.workspace_name);

        print_to_builder(*launch, "        {\n");
        print_to_builder(*launch, "            \"name\": \"%\",\n", name);
        print_to_builder(*launch, "            \"type\": \"cppdbg\",\n");
        print_to_builder(*launch, "            \"request\": \"launch\",\n");
        print_to_builder(*launch, "            \"program\": \"${workspaceFolder}/%\",\n", program_rel);
        print_to_builder(*launch, "            \"args\": [],\n");
        print_to_builder(*launch, "            \"cwd\": \"${workspaceFolder}/%\",\n", it.output_path);
        print_to_builder(*launch, "            \"environment\": [\n");
        print_to_builder(*launch, "                {\n");
        print_to_builder(*launch, "                    \"name\": \"LD_LIBRARY_PATH\",\n");
        print_to_builder(*launch, "                    \"value\": \"${workspaceFolder}/%:${env:LD_LIBRARY_PATH}\"\n", it.output_path);
        print_to_builder(*launch, "                }\n");
        print_to_builder(*launch, "            ],\n");
        print_to_builder(*launch, "            \"externalConsole\": false,\n");
        print_to_builder(*launch, "            \"MIMode\": \"gdb\",\n");
        print_to_builder(*launch, "            \"miDebuggerPath\": \"gdb\",\n");
        print_to_builder(*launch, "            \"preLaunchTask\": \"build: host\",\n");
        print_to_builder(*launch, "            \"setupCommands\": [\n");
        print_to_builder(*launch, "                {\n");
        print_to_builder(*launch, "                    \"description\": \"Enable pretty-printing for gdb\",\n");
        print_to_builder(*launch, "                    \"text\": \"-enable-pretty-printing\",\n");
        print_to_builder(*launch, "                    \"ignoreFailures\": true\n");
        print_to_builder(*launch, "                }\n");
        print_to_builder(*launch, "            ]\n");
        print_to_builder(*launch, "        }");
        if i + 1 < targets.count {
            print_to_builder(*launch, ",\n");
        } else {
            print_to_builder(*launch, "\n");
        }
    }

    print_to_builder(*launch, "    ]\n");
    print_to_builder(*launch, "}\n");

    launch_path := ".vscode/launch.json";
    if !write_entire_file(launch_path, *launch) {
        log_error("Failed to write %\n", launch_path);
    } else {
        log("Wrote %", launch_path);
    }
}

build_web_example_filter :: (args: [] string) -> string {
    for args {
        if it == "host" || it == "-host" || it == "web" || it == "-web" || it == "android" || it == "-android" continue;
        if begins_with(it, "-") continue;
        return it;
    }
    return "";
}

build_one_web_example :: (example: string) -> bool {
    source := tprint("examples/%/%.jai", example, example);
    if !file_exists(source) {
        log_error("Missing example source: %\n", source);
        return false;
    }

    workspace := tprint("Web %", example);
    w := compiler_create_workspace(workspace);
    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);

    options.output_type = .EXECUTABLE;
    options.backend = .LLVM;
    options.os_target = .WASM;
    options.cpu_target = .CUSTOM;
    options.emit_debug_info = .DWARF;
    options.backtrace_on_crash = .OFF;
    options.output_path = OUT_DIR;
    options.intermediate_path = tprint("%/%", BUILD_DIR, example);
    options.output_executable_name = example;
    options.llvm_options.target_system_features = "+bulk-memory";
    options.llvm_options.enable_split_modules = false;
    options.llvm_options.function_sections = true;

    patched_modules := tprint("%/../../Jai-Compiler/modules", get_working_directory());
    use_patched_modules := file_exists(patched_modules);

    import_paths: [..]string;
    array_add(*import_paths, tprint("%/modules", #filepath));
    if use_patched_modules array_add(*import_paths, patched_modules);
    for get_build_options().import_path array_add(*import_paths, it);
    options.import_path = import_paths;

    walloc_path := tprint("%/walloc.o", ASSETS_DIR);
    wasm_libc_path := tprint("%/wasm_libc.o", ASSETS_DIR);
    STACK_SIZE :: 1024 * 1024;
    options.additional_linker_arguments = .[
        "--stack-first",
        "-z", tprint("stack-size=%", STACK_SIZE),
        "--export-table",
        "--export=main",
        walloc_path,
        wasm_libc_path,
    ];

    set_build_options(options, w);
    remap_import(w, "*", "Default_Allocator", "Walloc");

    compiler_begin_intercept(w);
    add_build_file(source, w);

    ok := true;
    while true {
        message := compiler_wait_for_message();
        if message.kind == {
            case .COMPLETE;
                mc := cast(*Message_Complete) message;
                if mc.error_code != .NONE {
                    ok = false;
                    log_error("Web build failed for % (error %)\n", example, mc.error_code);
                }
                break;
        }
    }
    compiler_end_intercept(w);
    if !ok return false;

    wasm_path := tprint("%/%.wasm", OUT_DIR, example);
    bare := tprint("%/%", OUT_DIR, example);
    if !file_exists(wasm_path) && file_exists(bare) {
        copy_file(bare, wasm_path);
    }
    if !file_exists(wasm_path) {
        log_error("Expected wasm at % after build\n", wasm_path);
        return false;
    }

    js_out := tprint("%/%.js", OUT_DIR, example);
    Process :: #import "Process";
    result, stdout, stderr := Process.run_command(
        "python3",
        tprint("%/embed_example_js.py", ASSETS_DIR),
        "--webgpu", tprint("%/webgpu.js", ASSETS_DIR),
        "--wasm", wasm_path,
        "--out", js_out,
        "--name", example,
        capture_and_return_output = true,
    );
    if result.type == .FAILED_TO_LAUNCH || result.exit_code != 0 {
        log_error("embed_example_js failed for %:\n%\n%\n", example, stdout, stderr);
        return false;
    }
    log("Embedded %", js_out);
    return true;
}

build_web :: (args: [] string) {
    make_directory_if_it_does_not_exist(OUT_DIR);
    make_directory_if_it_does_not_exist(BUILD_DIR, recursive = true);

    patched_modules := tprint("%/../../Jai-Compiler/modules", get_working_directory());
    if file_exists(patched_modules) log("Will use patched modules at %", patched_modules);

    filter := build_web_example_filter(args);
    built := 0;
    for WEB_EXAMPLES {
        if filter.count && filter != it continue;
        if build_one_web_example(it) built += 1;
        else exit(1);
    }
    if !built {
        log_error("No web examples matched filter '%'.\n", filter);
        exit(1);
    }
    log("Building % web example(s) → self-contained .js", built);

    copy_assets_to_out(ASSETS_DIR, string.[
        "serve.py",
        "embed_example_js.py",
        "webgpu.js",
        "runtime.js",
    ]);
}

build_android :: (args: [] string, target_x64: bool, target_arm: bool, do_install: bool) {
    cpu_target := CPU.ARM64;
    if target_x64 cpu_target = .X64;
    if target_arm cpu_target = .ARM64;

    filter := "";
    for args {
        if it == "host" || it == "-host" || it == "web" || it == "-web" || it == "android" || it == "-android" continue;
        if it == "x64" || it == "-x64" || it == "arm64" || it == "-arm64" continue;
        if it == "install" || it == "-install" continue;
        if begins_with(it, "-") continue;
        filter = it;
        break;
    }
    example := "02_surface";
    if filter.count {
        matched := false;
        for ANDROID_EXAMPLES {
            if it == filter {
                example = it;
                matched = true;
                break;
            }
        }
        if !matched {
            log_error("No Android example matched filter '%'. Known: %\n", filter, ANDROID_EXAMPLES);
            exit(1);
        }
    }

    _, target_triple_with_sdk := get_android_target_triple(cpu_target);

    if do_install {
        android_check_for_adb_and_select_device("to install app to device");
    }

    log("Compiling ANDROID % example \"%\"", cpu_target, example);

    // Prefer patched modules tree when present (Nix store modules are read-only).
    patched_modules := tprint("%/../../Jai-Compiler/modules", get_working_directory());
    use_patched_modules := file_exists(patched_modules);
    if use_patched_modules log("Will use patched modules at %", patched_modules);

    android_project_config: Android_Project_Config;
    using android_project_config;
    app_name = tprint("% (%)", ANDROID_APP_NAME, example);
    app_id   = ANDROID_APP_ID;
    lib_name = OUTPUT_EXECUTABLE_NAME;
    project_path = tprint("%/AndroidProject", BUILD_DIR);

    if !generate_android_project(android_project_config) {
        compiler_report(tprint("Failed to create android project \"%\"", project_path));
        return;
    }
    log("Created or updated android project \"%\".", project_path);

    android_main_directory := tprint("%/app/src/main", project_path);
    build_output_directory := tprint(
        "%/jniLibs/%",
        android_main_directory,
        get_android_project_jni_architecture_name(cpu_target),
    );
    make_directory_if_it_does_not_exist(build_output_directory, recursive = true);

    w := compiler_create_workspace(tprint("Android %", example));
    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);
    {
        import_paths: [..] string;
        array_add(*import_paths, tprint("%/modules", #filepath));
        if use_patched_modules array_add(*import_paths, patched_modules);
        for get_build_options().import_path array_add(*import_paths, it);
        options.import_path = import_paths;
    }
    options.cpu_target = cpu_target;
    options.os_target  = .ANDROID;
    options.output_executable_name = OUTPUT_EXECUTABLE_NAME;
    options.intermediate_path = BUILD_DIR;
    options.output_type = .DYNAMIC_LIBRARY;
    options.use_custom_link_command = true;
    options.backend = .LLVM;
    options.llvm_options.target_system_triple = target_triple_with_sdk;
    options.llvm_options.function_sections = true;
    options.output_path = build_output_directory;
    if cpu_target == .ARM64 {
        options.llvm_options.target_system_features = "+lse";
    }

    // Host slang for compile-time #run / #insert reflection while cross-compiling.
    compiler_add_library_search_directory("modules/slang/linux");
    for split(to_string(getenv("LD_LIBRARY_PATH")), ":") {
        if it.count compiler_add_library_search_directory(it);
    }

    set_build_options(options, w);

    source := tprint("examples/%/%.jai", example, example);
    compiler_begin_intercept(w);
    add_build_file(source, w);

    while true {
        message := compiler_wait_for_message();
        if message.kind == {
            case .PHASE;
                phase_message := cast(*Message_Phase) message;
                if phase_message.phase == .READY_FOR_CUSTOM_LINK_COMMAND {
                    // Host libslang.so is x86_64 — never pass it to the Android NDK link.
                    // SPIR-V is baked via #insert; runtime must not call slang.
                    filtered_libs: [..] string;
                    for phase_message.user_libraries {
                        if contains(it, "slang") {
                            log("Android link: skipping host library %", it);
                            continue;
                        }
                        array_add(*filtered_libs, it);
                    }
                    phase_message.user_libraries = filtered_libs;

                    run_android_link_command(phase_message, options, string.["--gc-sections"]);
                }

            case .COMPLETE;
                mc := cast(*Message_Complete) message;
                if mc.error_code != .NONE exit(1);
                break;
        }
    }
    compiler_end_intercept(w);

    log("Generating apk...");

    android_options: Android_Build_Options;
    android_options.cpu_target = cpu_target;
    android_options.output_path = OUT_DIR;
    android_options.output_apk_name = example; // .bin/<example>.apk; lib inside remains libmain.so
    android_options.shared_library_path = build_output_directory;
    android_options.intermediate_path = tprint("%/android", BUILD_DIR);
    android_options.mode = .ILL_WRITE_IT_AND_WELL_DO_IT_LIVE_FUCKING_THING_SUCKS;

    success, apk_path := android_generate_apk(android_options, android_project_config);
    if !success {
        compiler_report("Apk generation failed, see above for errors.");
    }
    log("Apk written to %", apk_path);

    if do_install {
        if !adb_install(apk_path, reinstall_keeping_data = false) {
            compiler_report("Failed to install apk, see above for errors.");
        }
        log("Installed successfully.");
    }
}

copy_assets_to_out :: (dir: string, files: [] string) {
    for files {
        src := tprint("%/%", dir, it);
        dst := tprint("%/%", OUT_DIR, it);
        print("copying asset: % -> %\n", src, dst);
        if file_exists(src) {
            copy_file(src, dst);
        }
    }
}

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "POSIX";
#import "String";
#import "Android/Toolchain";
