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

#if OS != .WASM {
    Input :: #import "Input";
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

// Call after ImGui.SetCurrentContext. Quit / background / foreground stay with the app.
ImGuiBackend_ProcessEvent :: (ev: CrossEvent) {
    ctx := ImGui.GetCurrentContext();
    if !ctx return;
    io := ImGui.GetIO();

    if ev.kind == .WINDOW {
        if ev.window.type == .RESIZE {
            io.DisplaySize = .{cast(float) ev.window.width, cast(float) ev.window.height};
            io.DisplayFramebufferScale = .{1.0, 1.0};
        }
        return;
    }

    if ev.kind == .MOUSE {
        io.AddMouseSourceEvent(io, .Mouse);
        if ev.mouse.type == .MOVE {
            io.AddMousePosEvent(io, cast(float) ev.mouse.posn[0], cast(float) ev.mouse.posn[1]);
        } else if ev.mouse.type == .KEY_DOWN || ev.mouse.type == .KEY_UP {
            io.AddMouseButtonEvent(io, imgui_mouse_button(ev.mouse.key), ev.mouse.type == .KEY_DOWN);
        } else if ev.mouse.type == .SCROLL {
            #if OS == .WASM {
                // DOM wheel: positive deltaY is scroll down.
                io.AddMouseWheelEvent(
                    io,
                    -cast(float) ev.mouse.scroll[0] / 100.0,
                    -cast(float) ev.mouse.scroll[1] / 100.0,
                );
            } else {
                // Host wheel_delta is vertical, +120 per notch upward.
                io.AddMouseWheelEvent(io, 0.0, cast(float) ev.mouse.scroll[0] / 120.0);
            }
        }
        return;
    }

    if ev.kind == .TOUCH {
        io.AddMouseSourceEvent(io, .TouchScreen);
        io.AddMousePosEvent(io, cast(float) ev.touch.posn[0], cast(float) ev.touch.posn[1]);
        down := ev.touch.type == .TOUCH_START || ev.touch.type == .TOUCH_MOVE;
        if ev.touch.type == .TOUCH_START || ev.touch.type == .TOUCH_END || ev.touch.type == .TOUCH_CANCEL {
            io.AddMouseButtonEvent(io, 0, ev.touch.type == .TOUCH_START);
        } else if down {
            // Move keeps the button implied by the last start.
        }
        return;
    }

    if ev.kind == .KEYBOARD {
        if ev.keyboard.type == .TEXT_INPUT {
            if ev.keyboard.key > 0 io.AddInputCharacter(io, cast(u32) ev.keyboard.key);
            return;
        }
        key := imgui_key_from_native(ev.keyboard.key);
        if key == .None return;
        down := ev.keyboard.type == .KEY_DOWN || ev.keyboard.type == .KEY_REPEAT;
        io.AddKeyEvent(io, key, down);
    }
}

imgui_mouse_button :: (key: s32) -> s32 {
    #if OS != .WASM {
        code := cast(Input.Key_Code) key;
        if code == .MOUSE_BUTTON_LEFT return 0;
        if code == .MOUSE_BUTTON_RIGHT return 1;
        if code == .MOUSE_BUTTON_MIDDLE return 2;
        if code == .MOUSE_BUTTON_EXTRA_1 return 3;
        if code == .MOUSE_BUTTON_EXTRA_2 return 4;
    }
    // DOM MouseEvent.button: 0 left, 1 middle, 2 right.
    if key == 0 return 0;
    if key == 1 return 2;
    if key == 2 return 1;
    if key == 3 return 3;
    if key == 4 return 4;
    return 0;
}

imgui_key_from_native :: (key: s32) -> ImGui.Key {
    if key >= #char "A" && key <= #char "Z" {
        return cast(ImGui.Key) (cast(s32) ImGui.Key.A + (key - #char "A"));
    }
    if key >= #char "a" && key <= #char "z" {
        return cast(ImGui.Key) (cast(s32) ImGui.Key.A + (key - #char "a"));
    }
    if key >= #char "0" && key <= #char "9" {
        return cast(ImGui.Key) (cast(s32) ImGui.Key._0 + (key - #char "0"));
    }

    // Shared ASCII controls (host Key_Code and DOM keyCode).
    if key == 8  return .Backspace;
    if key == 9  return .Tab;
    if key == 13 return .Enter;
    if key == 27 return .Escape;
    if key == 32 return .Space;

    #if OS == .WASM {
        if key == 46 return .Delete;
        if key == 37 return .LeftArrow;
        if key == 38 return .UpArrow;
        if key == 39 return .RightArrow;
        if key == 40 return .DownArrow;
        if key == 33 return .PageUp;
        if key == 34 return .PageDown;
        if key == 36 return .Home;
        if key == 35 return .End;
        if key == 45 return .Insert;
        if key == 16 return .LeftShift;
        if key == 17 return .LeftCtrl;
        if key == 18 return .LeftAlt;
        if key == 91 || key == 93 return .LeftSuper;
        if key >= 112 && key <= 123 {
            return cast(ImGui.Key) (cast(s32) ImGui.Key.F1 + (key - 112));
        }
    } else {
        code := cast(Input.Key_Code) key;
        if code == .DELETE return .Delete;
        if code == .ARROW_LEFT return .LeftArrow;
        if code == .ARROW_RIGHT return .RightArrow;
        if code == .ARROW_UP return .UpArrow;
        if code == .ARROW_DOWN return .DownArrow;
        if code == .PAGE_UP return .PageUp;
        if code == .PAGE_DOWN return .PageDown;
        if code == .HOME return .Home;
        if code == .END return .End;
        if code == .INSERT return .Insert;
        if code == .SHIFT return .LeftShift;
        if code == .CTRL return .LeftCtrl;
        if code == .ALT return .LeftAlt;
        if code == .META return .LeftSuper;
        if code >= .F1 && code <= .F12 {
            return cast(ImGui.Key) (cast(s32) ImGui.Key.F1 + (cast(s32) code - cast(s32) Input.Key_Code.F1));
        }
    }
    return .None;
}
