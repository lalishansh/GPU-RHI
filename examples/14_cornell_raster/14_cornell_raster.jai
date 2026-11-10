// Cornell box via graphics pipeline — host (Vulkan), WASM (WebGPU), Android (Vulkan).
// Move: W/Up forward, S/Down back, A/Left strafe left, D/Right strafe right.
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
    main :: () { cornell_raster_main(); }
} else {
    main :: () { cornell_raster_main(); }
}

cornell_raster_main :: () {
    #if OS == .LINUX {
        path := path_strip_filename(get_path_of_running_executable());
        set_working_directory(path);
    }

    win := CrossWindow(CORNELL_W, CORNELL_H, "14_cornell_raster", WINDOW_BACKEND);
    defer Destroy(win);

    // SURFACE is requested on Context; Surface() DbC-asserts if the flag is missing.
    ctx := Context(flags = .ENABLE_DEBUG | .ENABLE_SURFACE);
    defer Destroy(*ctx);

    dev := Device(*ctx);
    defer Destroy(*dev);

    srf := Surface(*dev, win);
    tex := Texture(*dev, Size2D.{srf.width, srf.height}, usage = .COLOR_ATTACHMENT | .SAMPLED | .COPY_SRC);
    fb := FrameBuffer(*tex, clear_color = .{0.02, 0.02, 0.03, 1.0});
    defer Destroy(*tex);
    defer Destroy(*fb);
    defer Destroy(*srf);

    shdr := Spawn(*dev, LIT_SLANG, .["vs_main", "fs_main"]);
    defer Destroy(*shdr);

    scene := build_cornell_mesh();
    defer Destroy(*scene);

    verts := NewArray(scene.verts.count, shdr.Vertex_t);
    defer free(verts.data);
    copy_cornell_vertices(verts, scene.verts);

    indices := NewArray(scene.indices.count, IndexU32_t);
    defer free(indices.data);
    for i: 0..scene.indices.count-1 indices[i] = scene.indices[i];

    vbo := Buffer(*dev, verts);
    defer Destroy(*vbo);
    ibo := Buffer(*dev, indices);
    defer Destroy(*ibo);

    light_dir := Vector3.{0.15, -1.0, 0.05};
    ambient: float = 0.12;

    cam_pos := cornell_camera_eye();
    look_at := cornell_camera_target();
    cam_fwd := normalize(look_at - cam_pos);

    held_fwd := false;
    held_back := false;
    held_left := false;
    held_right := false;

    print("Cornell raster %x% — WASD / arrows move camera (%)\n",
        srf.width, srf.height, WINDOW_BACKEND);

    frames := 0;
    quit := false;
    max_frames := 180;
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
            if it == .INPUT_KEYBOARD {
                _, key, action := KeyboardEvent(it);
                down := action == .PRESS || action == .REPEAT;
                up := action == .RELEASE;
                if key_is_forward(key) { if down held_fwd = true; if up held_fwd = false; }
                if key_is_back(key)    { if down held_back = true; if up held_back = false; }
                if key_is_left(key)    { if down held_left = true; if up held_left = false; }
                if key_is_right(key)   { if down held_right = true; if up held_right = false; }
            }
        }
        if quit break;

        #if OS == .ANDROID {
            if win.host == null {
                sleep_milliseconds(16);
                continue;
            }
        }

        w := tex.size.x;
        h := tex.size.y;
        if w < 1 || h < 1 {
            #if OS != .WASM {
                sleep_milliseconds(16);
            }
            continue;
        }

        cornell_apply_camera_keys(*cam_pos, cam_fwd, held_fwd, held_back, held_left, held_right);
        // Keep looking in the same world direction while moving.
        target := cam_pos + cam_fwd;
        aspect := cast(float) w / cast(float) h;
        mvp := cornell_mvp(aspect, cam_pos, target);

        q := Queue(*dev, .GRAPHICS);
        Bind(*q, *fb);
        for Pass(*q, *shdr) {
            Set(*vbo);
            Set(*ibo);
            Set(shdr.MVP, mvp);
            Set(shdr.LightDir, light_dir);
            Set(shdr.Ambient, ambient);
            Record();
        }
        Submit(*q, wait = true);

        Present(*srf, *tex, fps = 60);
        frames += 1;
    }

    print("Cornell raster presented % frames\n", frames);
}

#import "Basic";
#import "Math";
#import "String";
#import "CrossWindow";
#import "GPU";
#if OS == .LINUX {
    #import "System";
}
#load "../_common/shaders.jai";
#load "../_common/cornell.jai";
