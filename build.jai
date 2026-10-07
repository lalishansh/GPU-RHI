OUT_DIR :: ".bin";
BUILD_DIR :: ".bin/.build";
ASSETS_DIR :: "assets";

OUTPUT_EXECUTABLE_NAME :: "main";
ANDROID_APP_NAME :: "GPU-RHI Native";
ANDROID_APP_ID   :: "jai.gpu_rhi_native";

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
        build_web();
    } else if wants_android {
        build_android(target_x64, target_arm, do_install);
    } else {
        build_host();
    }
}

build_host :: () {
    w := compiler_create_workspace("Target Program");
    options := get_build_options();
    options.output_type = .EXECUTABLE;
    options.output_executable_name = OUTPUT_EXECUTABLE_NAME;
    options.output_path = OUT_DIR;
    options.intermediate_path = BUILD_DIR;

    if OS == .LINUX {
        compiler_add_library_search_directory("modules/slang/linux");
        for split(to_string(getenv("LD_LIBRARY_PATH")), ":") {
            if it.count compiler_add_library_search_directory(it);
        }
    }

    set_build_options(options, w);
    add_build_file("src/main.jai", w);

    copy_assets_to_out(ASSETS_DIR, string.[
        "display.py",
    ]);
    copy_assets_to_out(tprint("%/%", ASSETS_DIR, "lib"), string.[
        "libslang-glslang-2025.24.so",
        "libslang-compiler.so.0.2025.24",
    ]);
}

build_web :: () {
    w := compiler_create_workspace("Native WASM");
    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);

    options.output_type = .EXECUTABLE;
    options.backend = .LLVM;
    options.os_target = .WASM;
    options.cpu_target = .CUSTOM;
    options.emit_debug_info = .DWARF;
    options.backtrace_on_crash = .OFF;
    options.output_path = OUT_DIR;
    options.intermediate_path = BUILD_DIR;
    options.output_executable_name = OUTPUT_EXECUTABLE_NAME;
    options.llvm_options.target_system_features = "+bulk-memory";
    options.llvm_options.enable_split_modules = false;
    options.llvm_options.function_sections = true;

    import_paths: [..]string;
    array_add(*import_paths, tprint("%/modules", #filepath));
    for options.import_path array_add(*import_paths, it);
    options.import_path = import_paths;

    walloc_path := tprint("%/walloc.o", ASSETS_DIR);
    STACK_SIZE :: 1024 * 1024;
    options.additional_linker_arguments = .[
        "--stack-first",
        "-z", tprint("stack-size=%", STACK_SIZE),
        "--export-table",
        walloc_path,
    ];

    set_build_options(options, w);
    remap_import(w, "*", "Default_Allocator", "Walloc");
    add_build_file("src/main.jai", w);

    copy_assets_to_out(ASSETS_DIR, string.[
        "runtime.js",
        "serve.py",
        "walloc.o",
        "webgpu.js",
    ]);
}

build_android :: (target_x64: bool, target_arm: bool, do_install: bool) {
    cpu_target := CPU.ARM64;
    if target_x64 cpu_target = .X64;
    if target_arm cpu_target = .ARM64;

    _, target_triple_with_sdk := get_android_target_triple(cpu_target);

    if do_install {
        android_check_for_adb_and_select_device("to install app to device");
    }

    log("Compiling for ANDROID %", cpu_target);

    // Prefer patched modules tree when present (Nix store modules are read-only).
    patched_modules := tprint("%/../../Jai-Compiler/modules", get_working_directory());
    use_patched_modules := file_exists(patched_modules);
    if use_patched_modules log("Will use patched modules at %", patched_modules);

    android_project_config: Android_Project_Config;
    using android_project_config;
    app_name = ANDROID_APP_NAME;
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

    w := compiler_create_workspace("Native Android");
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

    compiler_begin_intercept(w);
    add_build_file("src/main.jai", w);

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
    android_options.output_apk_name = OUTPUT_EXECUTABLE_NAME;
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
