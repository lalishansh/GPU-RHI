// Triangle :: "assets/shaders/triangle.slang";

WINDOW_WIDTH  :: 1920;
WINDOW_HEIGHT :: 1080;

// Web has no ImGui static library. Linux uses the host archive; Android uses the NDK archives.
#if OS == .WASM {
    USE_IMGUI :: true;
} else {
    USE_IMGUI :: true;
}

#if OS == .WASM {
    // JSPI: runtime.js awaits WebAssembly.promising(main).
    #program_export
    main :: () { app_main(); }
} else {
    main :: () { app_main(); }
}

app_main :: () {
    #if OS == .LINUX {
        // Android module already sets cwd to externalDataPath; WASM has no exe path.
        path := path_strip_filename(get_path_of_running_executable());
        set_working_directory(path);
    }

    w := CrossWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "app");
    defer Destroy_CrossWindow(*w);

    ctx := Context();
    defer Destroy(*ctx);

    dev := Device(*ctx);
    defer Destroy(*dev);

    tex := Texture(*dev, Size2D.{WINDOW_WIDTH, WINDOW_HEIGHT});
    defer Destroy(*tex);

    srf := Surface(*dev, *w);
    defer Destroy(*srf);

    shdr := Spawn(*dev, "assets/shaders/triangle.slang", .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    verts := shdr.Vertex_t.[
        .{.{ 0.5,  0.5, 0.0}, .{1.0, 0.0, 0.0}},
        .{.{-0.5,  0.5, 0.0}, .{0.0, 1.0, 0.0}},
        .{.{ 0.0, -0.5, 0.0}, .{0.0, 0.0, 1.0}},
    ];
    indices := IndexU32_t.[0, 1, 2];

    vtx_data := Buffer(*dev, verts);
    defer Destroy(*vtx_data);
    idx_data := Buffer(*dev, indices);
    defer Destroy(*idx_data);

    frm_buf := FrameBuffer(*tex);
    defer Destroy(*frm_buf);

    #if USE_IMGUI {
        ui := ImGui.CreateContext();
        defer ImGui.DestroyContext(ui);
        ImGui.SetCurrentContext(ui);
        io := ImGui.GetIO();
        io.DisplaySize = .{cast(float) WINDOW_WIDTH, cast(float) WINDOW_HEIGHT};
        io.IniFilename = null;
        ImGuiBackend_Init(*dev);
        defer ImGuiBackend_Destroy(*dev);
    }

    mouse_posn: [2]s32 = .[0, 0];

    quit := false;
    while !quit {
        // Poll before Present so Android TERM_WINDOW is seen before we touch Vulkan.
        // Touch and the synthetic mouse click for the same tap both arrive in one poll.
        // Count each touch start, and only count mouse clicks when there was no touch.

        for PollWindowEvents(*w) {
            #if USE_IMGUI {
                ImGui.SetCurrentContext(ui);
                ImGuiBackend_ProcessEvent(it);
            }
            if it.kind == .WINDOW {
                if it.window.type == .QUIT then quit = true;
            } else if it.kind == .MOUSE && it.mouse.type == .MOVE {
                mouse_posn = it.mouse.posn; print("mouse move %, %\n", it.mouse.posn[0], it.mouse.posn[1]);
            }
        }

        #if OS == .ANDROID {
            // CrossWindow sets host to INVALID on TERM_WINDOW (rotation / background).
            // TODO: fix
            if w.host == null {
                sleep_milliseconds(1);
                continue;
            }
        }

        #if USE_IMGUI {
            ImGui.NewFrame();
            ImGui.Begin(temp_c_string("Triangle"));
            ImGui.Text("mouse_posn %, %", mouse_posn[0], mouse_posn[1]);
            ImGui.Text("win_w %, win_h %", w.width, w.height);
            ImGui.Text("tex_w %, tex_h %", tex.size.width, tex.size.height);
            ImGui.End();
            ImGui.Render();
        }

        q := Queue(*dev, .GRAPHICS);
        defer {
            Submit(*q, wait = true);

            #if OS == .LINUX {
                bytes := Get(*tex);
                send_texture_buffer_over_network(bytes);
            }

            // WASM: Present → jsWaitForFrame (JSPI) yields to the browser and
            // resumes once the frame budget for `fps` has elapsed.
            Present(*srf, *tex, fps = 60);
            #if USE_IMGUI {
                if (tex.size.width != w.width || tex.size.height != w.height) {
                    Update(*tex, Size2D.{w.width, w.height});
                    io.DisplaySize = .{cast(float) w.width, cast(float) w.height};
                }
            }
        }

        Bind(*q, *frm_buf);
        for Pass(*q, *shdr) {
            Set(*vtx_data);
            Set(*idx_data);

            time: float64 = app_time();
            angle: float = xx time * 2.0 * PI;
            position: Vector3 = .{cos(angle) , 0.0, -3.0 + sin(angle) * 0.5};
            mvp := make_translation_matrix4(position);
            Set(shdr.MVP, mvp);
            Record();
        }
        #if USE_IMGUI {
            ImGuiBackend_RenderDrawData(*q, ImGui.GetDrawData());
        }
    }
}

#if OS == .LINUX {

DISPLAY_HOST :: "127.0.0.1";
DISPLAY_PORT :: 4321;

send_texture_buffer_over_network :: (bytes: []u8) {
    defer free(bytes.data);

    if !bytes.count return;
    if !socket_init() return;

    s := socket(AF_INET, .STREAM, .IP);
    if s == INVALID_SOCKET return;
    defer close_and_reset(*s);

    host_c := to_c_string(DISPLAY_HOST);
    defer free(host_c);

    addr: sockaddr_in;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(DISPLAY_PORT);
    addr.sin_addr.s_addr = inet_addr(host_c);

    if connect(s, cast(*sockaddr)*addr, xx size_of(sockaddr_in)) != 0 return;

    header := tprint(
        "POST /frame HTTP/1.1\r\nHost: %:%\r\nContent-Type: application/octet-stream\r\nContent-Length: %\r\nConnection: close\r\n\r\n",
        DISPLAY_HOST,
        DISPLAY_PORT,
        bytes.count,
    );

    if !socket_send_all(s, header.data, header.count) return;
    socket_send_all(s, bytes.data, bytes.count);
}

socket_send_all :: (s: Socket, data: *u8, count: s64) -> bool {
    sent: s64 = 0;
    while sent < count {
        n := send(s, data + sent, xx (count - sent), 0);
        if n <= 0 return false;
        sent += n;
    }
    return true;
}

#import "Socket";
}

#import "Basic";
#import "Math";
#import "String";
#import "GPU";
#import "CrossWindow";
#if USE_IMGUI {
    // ImGuiBackend exports the ImGui namespace.
    #import "ImGuiBackend";
}

#if OS == .LINUX {
    #import "System";
}

#if OS == .ANDROID  #import "Android"()(main, USE_GLUE_NATIVE_PORT = true);
