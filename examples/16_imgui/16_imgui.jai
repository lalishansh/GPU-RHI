// CrossWindow + Surface + ImGui overlay — host (Vulkan), WASM (WebGPU), Android (Vulkan).
#if OS == .WASM {
    WINDOW_BACKEND :: WINDOW_TYPE.JS_CANVAS;
} else #if OS == .ANDROID {
    WINDOW_BACKEND :: WINDOW_TYPE.ANDROID;
} else {
    WINDOW_BACKEND :: WINDOW_TYPE.X11;
}

#if OS == .ANDROID {
    #import "Android"()(main, USE_GLUE_NATIVE_PORT = true);
}

#if OS == .WASM {
    #program_export
    main :: () { imgui_main(); }
} else {
    main :: () { imgui_main(); }
}

imgui_main :: () {
    win := CrossWindow(960, 600, "16_imgui", WINDOW_BACKEND);
    defer Destroy(win);

    ctx := Context(flags = .ENABLE_DEBUG | .ENABLE_SURFACE);
    defer Destroy(*ctx);

    dev := Device(*ctx);
    defer Destroy(*dev);

    srf := Surface(*dev, win);
    tex := Texture(*dev, Size2D.{srf.width, srf.height}, usage = .COLOR_ATTACHMENT | .SAMPLED | .COPY_SRC);
    fb := FrameBuffer(*tex, clear_color = .{0.12, 0.14, 0.22, 1.0});
    defer Destroy(*tex);
    defer Destroy(*fb);
    defer Destroy(*srf);

    shdr := Spawn(*dev, UNLIT_COLOR_SLANG, .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    verts := shdr.Vertex_t.[
        .{.{ 0.0,  0.55, 0}, .{1,0.45,0.2}, .{0,0,1}},
        .{.{-0.55, -0.55, 0}, .{0.2,1,0.45}, .{0,0,1}},
        .{.{ 0.55, -0.55, 0}, .{0.35,0.45,1}, .{0,0,1}},
    ];
    indices := IndexU32_t.[0, 1, 2];
    vbo := Buffer(*dev, verts); defer Destroy(*vbo);
    ibo := Buffer(*dev, indices); defer Destroy(*ibo);

    ui := ImGui.CreateContext();
    defer ImGui.DestroyContext(ui);
    ImGui.SetCurrentContext(ui);
    io := ImGui.GetIO();
    io.DisplaySize = .{cast(float) srf.width, cast(float) srf.height};
    io.IniFilename = null;
    #if OS == .ANDROID {
        io.FontGlobalScale = 2.0;
        style := ImGui.GetStyle();
        style.ScaleAllSizes(style, 2.0);
        style.ScrollbarSize = 26.0;
    }
    ImGuiBackend_Init(*dev);
    defer ImGuiBackend_Destroy(*dev);

    print("ImGui surface %x% on CrossWindow(%)\n", srf.width, srf.height, WINDOW_BACKEND);

    mouse_x, mouse_y: s32;
    show_demo := true;
    frames := 0;
    quit := false;
    max_frames := 180;
    #if OS == .ANDROID {
        max_frames = 0x7FFF_FFFF;
    }
    while !quit && frames < max_frames {
        reset_temporary_storage();

        for PollEvents(win) {
            ImGui.SetCurrentContext(ui);
            ImGuiBackend_ProcessEvent(it);
            if it == .WINDOW_QUIT {
                quit = true;
                break;
            }
            if it == .WINDOW_RESIZE {
                _, rw, rh := WindowResizeEvent(it);
                if rw > 0 && rh > 0 {
                    Update(*fb, Size2D.{rw, rh});
                    io.DisplaySize = .{cast(float) rw, cast(float) rh};
                }
            }
            if it == .INPUT_MOUSE {
                _, _, _, mx, my := MouseEvent(it);
                mouse_x = mx;
                mouse_y = my;
            }
        }
        if quit break;

        #if OS == .ANDROID {
            if win.host == null {
                sleep_milliseconds(16);
                continue;
            }
        }

        ImGui.NewFrame();
        ImGui.Begin(temp_c_string("GPU-RHI"));
        ImGui.Text("mouse %, %", mouse_x, mouse_y);
        ImGui.Text("fb %x%", tex.size.x, tex.size.y);
        ImGui.Checkbox(temp_c_string("Demo Window"), *show_demo);
        ImGui.End();
        if show_demo ImGui.ShowDemoWindow(*show_demo);
        ImGui.Render();

        q := Queue(*dev, .GRAPHICS);
        Bind(*q, *fb);
        for Pass(*q, *shdr) {
            Set(*vbo); Set(*ibo);
            Set(shdr.MVP, Matrix4_Identity);
            Record();
        }
        ImGuiBackend_RenderDrawData(*q, ImGui.GetDrawData());
        Submit(*q, wait = true);

        Present(*srf, *tex, fps = 60);
        frames += 1;
    }

    print("Presented % frames with ImGui\n", frames);
}

#import "Basic";
#import "Math";
#import "String";
#import "CrossWindow";
#import "GPU";
#import "ImGuiBackend";
#load "../_common/shaders.jai";
