// CrossWindow + Surface + Present
#if OS == .WASM {
    WINDOW_BACKEND :: WINDOW_TYPE.JS_CANVAS;
} else {
    WINDOW_BACKEND :: WINDOW_TYPE.X11;
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

    print("Surface %x% ready on CrossWindow(%) — presenting a few frames\n",
        srf.width, srf.height, WINDOW_BACKEND);

    frames := 0;
    quit := false;
    while !quit && frames < 90 {
        for PollEvents(win) {
            cat := cast(EVENT_CATEGORY) it.dataU8[0];
            print("event cat=% (raw=%)\n", cat, it.dataU8[0]);
            if it == .WINDOW_QUIT {
                print("  WINDOW_QUIT\n");
                quit = true;
                break;
            }
            if it == .WINDOW_RESIZE {
                _, rw, rh := WindowResizeEvent(it);
                print("  WINDOW_RESIZE %x%\n", rw, rh);
                if rw > 0 && rh > 0 {
                    Update(*fb, Size2D.{rw, rh});
                }
            }
            if it == .WINDOW_FOCUS || it == .WINDOW_FOCUS_LOST || it == .WINDOW_MOVE {
                print("  window event\n");
            }
            if it == .INPUT_KEYBOARD {
                _, key, action := KeyboardEvent(it);
                print("  KEY key=% action=%\n", key, cast(u8) action);
            }
            if it == .INPUT_MOUSE {
                _, btn, action, mx, my := MouseEvent(it);
                print("  MOUSE btn=% action=% @ %,%)\n", cast(u8) btn, cast(u8) action, mx, my);
            }
        }
        if quit break;

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
