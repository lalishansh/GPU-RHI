Triangle :: "assets/shaders/triangle.slang";

WINDOW_WIDTH  :: 1920;
WINDOW_HEIGHT :: 1080;

// Web has no ImGui static library. Linux uses the host archive; Android uses the NDK archives.
#if OS == .WASM {
    USE_IMGUI :: false;
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

    shdr := Spawn(*dev, Triangle, .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    verts := shdr.Vertex_t.[
        .{.{ 1.0,  1.0, 0.0}, .{1.0, 0.0, 0.0}},
        .{.{-1.0,  1.0, 0.0}, .{0.0, 1.0, 0.0}},
        .{.{ 0.0, -1.0, 0.0}, .{0.0, 0.0, 1.0}},
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

    fov := 70.0 * PI / 180.0;
    z_near: float = 0.1;
    z_far:  float = 256.0;
    aspect := cast(float) tex.size.width / cast(float) tex.size.height;
    half_h := tan(fov * 0.5) * z_near;
    half_w := half_h * aspect;
    proj := make_frustum_matrix(-half_w, half_w, -half_h, half_h, z_near, z_far, true);

    y_posn := float.[0.0, -.5, 0.0, .5];
    y_posn_idx := 0;
    test_count := 0;

    quit := false;
    while !quit {
        // Poll before Present so Android TERM_WINDOW is seen before we touch Vulkan.
        // Touch and the synthetic mouse click for the same tap both arrive in one poll.
        // Count each touch start, and only count mouse clicks when there was no touch.
        touch_starts := 0;
        mouse_clicks := 0;
        #if USE_IMGUI {
            ImGui.SetCurrentContext(ui);
        }
        for PollWindowEvents(*w) {
            #if USE_IMGUI {
                ImGuiBackend_ProcessEvent(it);
            }
            if it.kind == .WINDOW {
                if it.window.type == .QUIT then quit = true;
            } else if it.kind == .MOUSE {
                if it.mouse.type == .KEY_DOWN {
                    #if USE_IMGUI {
                        if ImGui.GetIO().WantCaptureMouse continue;
                    }
                    mouse_clicks += 1;
                    test_count += 1;
                    print("mouse click %\n", test_count);
                }
                else if it.mouse.type == .MOVE {print("mouse move %, %\n", it.mouse.posn[0], it.mouse.posn[1]);}
            } else if it.kind == .TOUCH {
                if it.touch.type == .TOUCH_START {
                    #if USE_IMGUI {
                        if !ImGui.GetIO().WantCaptureMouse touch_starts += 1;
                    } else {
                        touch_starts += 1;
                    }
                }
            }
        }
        if touch_starts > 0 {
            y_posn_idx += touch_starts;
        } else {
            y_posn_idx += mouse_clicks;
        }

        #if OS == .ANDROID {
            // CrossWindow sets host to INVALID on TERM_WINDOW (rotation / background).
            if w.host == null {
                sleep_milliseconds(1);
                continue;
            }
        }

        while y_posn_idx >= y_posn.count {
            y_posn_idx -= y_posn.count;
        }

        #if USE_IMGUI {
            ImGui.NewFrame();
            ImGui.Begin(temp_c_string("Triangle"));
            ImGui.Text("clicks %", test_count);
            ImGui.Text("y %", y_posn[y_posn_idx]);
            slot: s32 = cast(s32) y_posn_idx;
            if ImGui.SliderInt(temp_c_string("y index"), *slot, 0, cast(s32) y_posn.count - 1) {
                y_posn_idx = slot;
            }
            if ImGui.Button(temp_c_string("Next position")) {
                y_posn_idx += 1;
            }
            while y_posn_idx >= y_posn.count {
                y_posn_idx -= y_posn.count;
            }
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
                win_w: s32 = cast(s32) w.width;
                win_h: s32 = cast(s32) w.height;
                #if OS == .LINUX {
                    Window :: #import "Window_Creation";
                    _, _, win_w, win_h = Window.get_dimensions(srf.window.host, false);
                }
                if win_w > 0 && win_h > 0 && (tex.size.width != cast(u32) win_w || tex.size.height != cast(u32) win_h) {
                    Update(*tex, Size2D.{xx win_w, xx win_h});
                    aspect := cast(float) tex.size.width / cast(float) tex.size.height;
                    half_h := tan(fov * 0.5) * z_near;
                    half_w := half_h * aspect;
                    proj = make_frustum_matrix(-half_w, half_w, -half_h, half_h, z_near, z_far, true);
                    io.DisplaySize = .{cast(float) win_w, cast(float) win_h};
                }
            }
        }

        while y_posn_idx >= y_posn.count {
            y_posn_idx -= y_posn.count;
        }

        Bind(*q, *frm_buf);
        for Pass(*q, *shdr) {
            Set(*vtx_data);
            Set(*idx_data);

            time: float64 = app_time();
            angle: float = xx time * 2.0 * PI;
            position: Vector3 = .{cos(angle) * 1.5, y_posn[y_posn_idx], -3.0 + sin(angle) * 0.5};
            mvp := proj * make_translation_matrix4(position);
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
