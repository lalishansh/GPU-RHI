// Cornell box via compute pipeline (raycast AABBs → RWTexture2D) — all 3 platforms.
// CameraPos/CameraFwd from main via Set(cs.CameraPos/Fwd, …).
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
    main :: () { cornell_compute_main(); }
} else {
    main :: () { cornell_compute_main(); }
}

cornell_compute_main :: () {
    #if OS == .LINUX {
        path := path_strip_filename(get_path_of_running_executable());
        set_working_directory(path);
    }

    win := CrossWindow(CORNELL_W, CORNELL_H, "15_cornell_compute", WINDOW_BACKEND);
    defer Destroy(win);

    // SURFACE/COMPUTE requested on Context; Surface/Queue DbC-assert if missing.
    ctx := Context(flags = .ENABLE_DEBUG | .ENABLE_SURFACE | .ENABLE_COMPUTE);
    defer Destroy(*ctx);

    dev := Device(*ctx);
    defer Destroy(*dev);

    srf := Surface(*dev, win);
    tex := Texture(
        *dev,
        Size2D.{CORNELL_W, CORNELL_H},
        usage = .STORAGE | .SAMPLED | .COPY_SRC,
    );
    defer Destroy(*tex);
    defer Destroy(*srf);

    cs := Spawn(*dev, CORNELL_COMPUTE_SLANG, .["cs_main"]);
    defer Destroy(*cs);

    cam_pos := cornell_camera_eye();
    cam_fwd := normalize(cornell_camera_target() - cam_pos);

    held_fwd := false;
    held_back := false;
    held_left := false;
    held_right := false;

    print("Cornell compute %x% — WASD / arrows move camera (%)\n",
        CORNELL_W, CORNELL_H, WINDOW_BACKEND);

    groups_x := cast(u32) ((CORNELL_W + 7) / 8);
    groups_y := cast(u32) ((CORNELL_H + 7) / 8);

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

        cornell_apply_camera_keys(*cam_pos, cam_fwd, held_fwd, held_back, held_left, held_right);

        cq := Queue(*dev, .COMPUTE);
        for Pass(*cq, *cs) {
            Set(cs.CameraPos, cam_pos);
            Set(cs.CameraFwd, cam_fwd);
            Set(*tex);
        }
        Submit(*cq, groups_x = groups_x, groups_y = groups_y);

        Present(*srf, *tex, fps = 60);
        frames += 1;
    }

    print("Cornell compute presented % frames\n", frames);
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
