// CrossWindow + Surface + Present — host (X11), WASM (canvas), Android (ANativeWindow)
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
    main :: () { surface_main(); }
} else {
    main :: () { surface_main(); }
}

surface_main :: () {
    win := CrossWindow(800, 600, "02_surface", WINDOW_BACKEND);
    defer Destroy(win);

    ctx := Context(flags = .ENABLE_DEBUG | .ENABLE_SURFACE);
    defer Destroy(*ctx);
    require_feature(*ctx, .SURFACE);

    dev := Device(*ctx);
    defer Destroy(*dev);

    srf := Surface(*dev, win);
    tex := Texture(*dev, Size2D.{srf.width, srf.height}, usage = .COLOR_ATTACHMENT | .SAMPLED | .COPY_SRC);
    fb := FrameBuffer(*tex, clear_color = .{0.1, 0.2, 0.45, 1.0});
    // Destroy surface before tex/fb (Present cmd may still reference the sampled image).
    defer Destroy(*tex);
    defer Destroy(*fb);
    defer Destroy(*srf);

    shdr := Spawn(*dev, UNLIT_COLOR_SLANG, .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    verts := shdr.Vertex_t.[
        .{.{ 0.0,  0.7, 0}, .{1,0.4,0.2}, .{0,0,1}},
        .{.{-0.7, -0.7, 0}, .{0.2,1,0.4}, .{0,0,1}},
        .{.{ 0.7, -0.7, 0}, .{0.3,0.4,1}, .{0,0,1}},
    ];
    indices := IndexU32_t.[0, 1, 2];
    vbo := Buffer(*dev, verts); defer Destroy(*vbo);
    ibo := Buffer(*dev, indices); defer Destroy(*ibo);

    print("Surface %x% ready on CrossWindow(%) — presenting\n",
        srf.width, srf.height, WINDOW_BACKEND);

    frames := 0;
    quit := false;
    // Host/WASM smoke a fixed frame count; Android runs until quit/background forever.
    max_frames := 90;
    #if OS == .ANDROID {
        max_frames = 0x7FFF_FFFF;
    }
    while !quit && frames < max_frames {
        reset_temporary_storage();

        for PollEvents(win) {
            if it == .WINDOW_QUIT {
                quit = true;
                break;
            }
            if it == .WINDOW_RESIZE {
                _, rw, rh := WindowResizeEvent(it);
                if rw > 0 && rh > 0 {
                    Update(*fb, Size2D.{rw, rh});
                }
            }
        }
        if quit break;

        #if OS == .ANDROID {
            if win.host == null {
                sleep_milliseconds(16);
                continue;
            }
        }

        q := Queue(*dev, .GRAPHICS);
        Bind(*q, *fb);
        for Pass(*q, *shdr) {
            Set(*vbo); Set(*ibo);
            Set(shdr.MVP, Matrix4_Identity);
            Record();
        }
        Submit(*q, wait = true);

        Present(*srf, *tex, fps = 60);
        frames += 1;
    }

    print("Presented % frames\n", frames);
}

#import "Basic";
#import "Math";
#import "String";
#import "CrossWindow";
#import "GPU";
#load "../_common/shaders.jai";
