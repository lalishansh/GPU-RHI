#import "Basic";
#import "Math";
#import "String";
ImGui :: #import "ImGui";
#import "CrossWindow";

GPU :: #import "GPU";

#if OS == .LINUX || OS == .ANDROID {
    // ImGui's static library calls libm. Android's linker will not load libm.so
    // unless this shared object lists it, so sincosf/acosf fail at startup.
    #library,system,link_always "libm";
}

// Host slangc bake. Linux/Android consume SPIR-V; web consumes WGSL.
// The helper is declared inside each #run: a WASM cross-compile host workspace
// cannot see procedures declared in the target module.
IMGUI_BAKED_SPIRV :: #run,host -> string {
    #import "Basic";
    #import "String";
    File :: #import "File";
    Process :: #import "Process";
    shader := tprint("%/../../assets/shaders/imgui.slang", #filepath);
    File.make_directory_if_it_does_not_exist(".bin/.build", recursive = true);
    out := ".bin/.build/imgui.spv";
    result, stdout, stderr := Process.run_command(
        "env", "-u", "LD_LIBRARY_PATH",
        "slangc", shader,
        "-target", "spirv",
        "-matrix-layout-row-major",
        "-fvk-use-entrypoint-name",
        "-entry", "vs_imgui", "-stage", "vertex",
        "-entry", "fs_imgui", "-stage", "fragment",
        "-o", out,
        capture_and_return_output = true,
    );
    assert(result.type != .FAILED_TO_LAUNCH, "slangc not found on PATH");
    assert(result.exit_code == 0, "slangc imgui spirv failed:\n%\n%", stdout, stderr);
    data, ok := File.read_entire_file(out);
    assert(ok && data.count > 0, "read imgui.spv failed");
    builder: String_Builder;
    print_to_builder(*builder, "code :: u8.[\n");
    for i: 0..data.count-1 {
        print_to_builder(*builder, "%,", data[i]);
        if (i + 1) % 16 == 0 then print_to_builder(*builder, "\n");
    }
    print_to_builder(*builder, "\n];\n");
    return builder_to_string(*builder);
};

IMGUI_BAKED_WGSL :: #run,host -> string {
    #import "Basic";
    #import "String";
    File :: #import "File";
    Process :: #import "Process";
    shader := tprint("%/../../assets/shaders/imgui.slang", #filepath);
    File.make_directory_if_it_does_not_exist(".bin/.build", recursive = true);
    out := ".bin/.build/imgui.wgsl";
    result, stdout, stderr := Process.run_command(
        "env", "-u", "LD_LIBRARY_PATH",
        "slangc", shader,
        "-target", "wgsl",
        "-matrix-layout-row-major",
        "-fvk-use-entrypoint-name",
        "-entry", "vs_imgui", "-stage", "vertex",
        "-entry", "fs_imgui", "-stage", "fragment",
        "-o", out,
        capture_and_return_output = true,
    );
    assert(result.type != .FAILED_TO_LAUNCH, "slangc not found on PATH");
    assert(result.exit_code == 0, "slangc imgui wgsl failed:\n%\n%", stdout, stderr);
    data, ok := File.read_entire_file(out);
    assert(ok && data.count > 0, "read imgui.wgsl failed");
    builder: String_Builder;
    print_to_builder(*builder, "code :: u8.[\n");
    for i: 0..data.count-1 {
        print_to_builder(*builder, "%,", data[i]);
        if (i + 1) % 16 == 0 then print_to_builder(*builder, "\n");
    }
    print_to_builder(*builder, "\n];\n");
    return builder_to_string(*builder);
};

#if OS == .WASM {
    ImGuiShaderBytes :: struct {
        #insert -> string { return IMGUI_BAKED_WGSL; }
    }
    #load "web.jai";
} else {
    ImGuiShaderBytes :: struct {
        #insert -> string { return IMGUI_BAKED_SPIRV; }
    }
    #import "Vulkan";
    #load "vulkan.jai";
}

// Call after ImGui.SetCurrentContext. Quit / focus stay with the app.
ImGuiBackend_ProcessEvent :: (ev: BaseEvent) {
    ctx := ImGui.GetCurrentContext();
    if !ctx return;
    io := ImGui.GetIO();

    if ev == .WINDOW_RESIZE {
        _, w, h := WindowResizeEvent(ev);
        if w > 0 && h > 0 {
            io.DisplaySize = .{cast(float) w, cast(float) h};
            io.DisplayFramebufferScale = .{1.0, 1.0};
        }
        return;
    }

    if ev == .INPUT_MOUSE {
        _, button, action, x, y := MouseEvent(ev);
        io.AddMouseSourceEvent(io, .Mouse);
        io.AddMousePosEvent(io, cast(float) x, cast(float) y);

        if button == .WHEEL_UP || button == .WHEEL_DOWN {
            if action == .PRESS || action == .REPEAT {
                wheel := ifx button == .WHEEL_UP then 1.0 else -1.0;
                io.AddMouseWheelEvent(io, 0.0, wheel);
            }
            return;
        }

        // CrossWindow encodes move as LEFT + REPEAT.
        if action == .REPEAT return;

        btn := imgui_mouse_button(button);
        if btn < 0 return;
        io.AddMouseButtonEvent(io, btn, action == .PRESS);
        return;
    }

    if ev == .INPUT_KEYBOARD {
        _, key, action := KeyboardEvent(ev);
        down := action == .PRESS || action == .REPEAT;
        imgui_key := imgui_key_from_native(key);
        if imgui_key != .None {
            io.AddKeyEvent(io, imgui_key, down);
        }
        // No dedicated TEXT_INPUT yet — feed printable ASCII on press for text fields.
        if down && key >= 32 && key < 127 {
            io.AddInputCharacter(io, cast(u32) key);
        }
    }
}

imgui_mouse_button :: (button: MOUSE_BUTTON) -> s32 {
    if button == .LEFT   return 0;
    if button == .RIGHT  return 1;
    if button == .MIDDLE return 2;
    if button == .X1     return 3;
    if button == .X2     return 4;
    return -1;
}

imgui_key_from_native :: (key: u8) -> ImGui.Key {
    if key >= KEY_A && key <= KEY_Z {
        return cast(ImGui.Key) (cast(s32) ImGui.Key.A + (cast(s32) key - KEY_A));
    }
    if key >= #char "a" && key <= #char "z" {
        return cast(ImGui.Key) (cast(s32) ImGui.Key.A + (cast(s32) key - #char "a"));
    }
    if key >= #char "0" && key <= #char "9" {
        return cast(ImGui.Key) (cast(s32) ImGui.Key._0 + (cast(s32) key - #char "0"));
    }

    if key == KEY_BACKSPACE return .Backspace;
    if key == KEY_TAB       return .Tab;
    if key == KEY_RETURN    return .Enter;
    if key == KEY_ESCAPE    return .Escape;
    if key == KEY_SPACE     return .Space;
    if key == KEY_DELETE    return .Delete;
    if key == KEY_LEFT || key == KEY_ANDROID_DPAD_LEFT  return .LeftArrow;
    if key == KEY_RIGHT || key == KEY_ANDROID_DPAD_RIGHT return .RightArrow;
    if key == KEY_UP || key == KEY_ANDROID_DPAD_UP       return .UpArrow;
    if key == KEY_DOWN || key == KEY_ANDROID_DPAD_DOWN   return .DownArrow;
    if key >= KEY_F1 && key <= KEY_F12 {
        return cast(ImGui.Key) (cast(s32) ImGui.Key.F1 + (cast(s32) key - KEY_F1));
    }
    return .None;
}
