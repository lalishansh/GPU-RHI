// Multi-window smoke: two CrossWindows, independent PollEvents.
#if OS == .WASM {
    WINDOW_BACKEND :: WINDOW_TYPE.JS_CANVAS;
} else {
    WINDOW_BACKEND :: WINDOW_TYPE.X11;
}

#if OS == .WASM {
    #program_export
    main :: () { multiwindow_main(); }
} else {
    main :: () { multiwindow_main(); }
}

multiwindow_main :: () {
    a := CrossWindow(640, 480, "window-a", WINDOW_BACKEND);
    defer Destroy(a);
    b := CrossWindow(400, 300, "window-b", WINDOW_BACKEND);
    defer Destroy(b);

    ax, ay, aw, ah, aok := GetDimensions(a);
    bx, by, bw, bh, bok := GetDimensions(b);
    assert(aok && bok, "GetDimensions failed");
    assert(aw > 0 && ah > 0 && bw > 0 && bh > 0, "windows have zero size");
    print("A: %x% @ %,%;  B: %x% @ %,%)\n", aw, ah, ax, ay, bw, bh, bx, by);

    #if OS != .WASM {
        dpy_a, xid_a := GetNativeX11(a);
        dpy_b, xid_b := GetNativeX11(b);
        assert(dpy_a == dpy_b, "multi-window should share one Display");
        assert(xid_a != xid_b, "windows must have distinct Xids");
        print("Shared Display % — xids %, %\n", cast(*void) dpy_a, xid_a, xid_b);
    } else {
        print("WASM canvases: window-a + window-b\n");
    }

    a_quit := false;
    b_quit := false;
    for frame: 0..120 {
        for PollEvents(a) {
            if it == .WINDOW_QUIT {
                a_quit = true;
                w := WindowQuitEvent(it);
                assert(w == cast(*void) a, "quit event window pointer mismatch (A)");
            }
            if it == .WINDOW_RESIZE {
                _, w, h := WindowResizeEvent(it);
                print("A resize -> %x%\n", w, h);
            }
            if it == .WINDOW_FOCUS {
                assert(WindowFocusEvent(it) == cast(*void) a, "focus A pointer");
            }
            if it == .INPUT_KEYBOARD {
                _, key, action := KeyboardEvent(it);
                print("A key % action %\n", key, cast(u8) action);
            }
        }
        for PollEvents(b) {
            if it == .WINDOW_QUIT {
                b_quit = true;
                w := WindowQuitEvent(it);
                assert(w == cast(*void) b, "quit event window pointer mismatch (B)");
            }
            if it == .WINDOW_RESIZE {
                _, w, h := WindowResizeEvent(it);
                print("B resize -> %x%\n", w, h);
            }
            if it == .INPUT_MOUSE {
                _, btn, action, mx, my := MouseEvent(it);
                if action != .REPEAT {
                    print("B mouse btn % action % @ %,%)\n", cast(u8) btn, cast(u8) action, mx, my);
                }
            }
        }
        if a_quit && b_quit break;
        #if OS != .WASM {
            sleep_milliseconds(8);
        }
    }

    {
        e := WindowQuitEvent(cast(*void) a);
        assert(e == .WINDOW_QUIT);
        w := WindowQuitEvent(e);
        assert(w == cast(*void) a);
    }
    {
        e := WindowResizeEvent(cast(*void) b, 111, 222);
        w, width, height := WindowResizeEvent(e);
        assert(w == cast(*void) b && width == 111 && height == 222);
    }

    print("multi-window smoke OK (a_quit=% b_quit=%)\n", a_quit, b_quit);
}

#import "Basic";
#import "String";
#import "CrossWindow";
