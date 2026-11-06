// X11 backend — own Display connection, multi-window registry, event pump.
// Does not use Window_Creation / x_global_display.

// Missing from Jai X11 module bindings (X.h valuemask bits).
CWBackPixel   :: (1 << 1);
CWBorderPixel :: (1 << 3);

X11_EVENT_MASK :: ExposureMask | KeyPressMask | KeyReleaseMask
    | ButtonPressMask | ButtonReleaseMask
    | PointerMotionMask | StructureNotifyMask | FocusChangeMask
    | EnterWindowMask | LeaveWindowMask;

X11Window :: struct {
    xid: Window;
    width: u32;
    height: u32;
    x: s32;
    y: s32;
    name_id: string;
    // `pending` accumulates across pumps for any window; PollEvents drains into `events`.
    pending: [..] BaseEvent;
    events: [..] BaseEvent;
    alive: bool;
}

#scope_file

x11_display: *Display;
x11_wm_delete: Atom;
x11_wm_protocols: Atom;
x11_refcount: s32;
x11_windows: [..]*X11Window;

x11_ensure_display :: () {
    if x11_display return;

    XInitThreads();
    x11_display = XOpenDisplay(null);
    assert(x11_display != null, "CrossWindow(X11): XOpenDisplay failed (is DISPLAY set?)");

    x11_wm_delete = XInternAtom(x11_display, "WM_DELETE_WINDOW", False);
    x11_wm_protocols = XInternAtom(x11_display, "WM_PROTOCOLS", False);
}

#scope_export

GetNativeX11 :: (w: *X11Window) -> display: *Display, window: Window {
    assert(w != null && w.alive, "GetNativeX11: invalid window");
    assert(x11_display != null, "GetNativeX11: display not open");
    return x11_display, w.xid;
}

CrossWindow :: (wd: u32, ht: u32, name_id := "app", $type: WINDOW_TYPE) -> *X11Window
    #modify { return type == .X11; }
{
    assert(wd >= 1 && ht >= 1, "CrossWindow(X11): size must be >= 1");
    x11_ensure_display();

    d := x11_display;
    XLockDisplay(d);
    defer XUnlockDisplay(d);

    screen := DefaultScreen(d);
    root := DefaultRootWindow(d);
    visual := XDefaultVisual(d, screen);
    depth := XDefaultDepth(d, screen);
    cmap := XCreateColormap(d, root, visual, AllocNone);

    swa: XSetWindowAttributes;
    swa.colormap = cmap;
    swa.event_mask = X11_EVENT_MASK;
    swa.background_pixel = XBlackPixel(d, screen);
    swa.border_pixel = XBlackPixel(d, screen);

    value_mask := cast(u64) (CWColormap | CWEventMask | CWBackPixel | CWBorderPixel);
    xid := XCreateWindow(
        d, root,
        0, 0, wd, ht,
        0, depth, InputOutput, visual,
        value_mask, *swa,
    );
    assert(xid != None, "CrossWindow(X11): XCreateWindow failed");

    title := temp_c_string(name_id);
    XStoreName(d, xid, title);

    class_hints := XAllocClassHint();
    if class_hints {
        class_hints.res_name = title;
        class_hints.res_class = title;
        XSetClassHint(d, xid, class_hints);
        XFree(class_hints);
    }

    protocols := x11_wm_delete;
    XSetWMProtocols(d, xid, *protocols, 1);
    XMapWindow(d, xid);
    XFlush(d);

    w := New(X11Window);
    w.xid = xid;
    w.width = wd;
    w.height = ht;
    w.x = 0;
    w.y = 0;
    w.name_id = copy_string(name_id);
    w.alive = true;
    array_add(*x11_windows, w);
    x11_refcount += 1;

    // Sync geometry after map (WM may place/resize).
    {
        xwa: XWindowAttributes;
        if XGetWindowAttributes(d, xid, *xwa) != 0 {
            w.x = xwa.x;
            w.y = xwa.y;
            if xwa.width > 0  w.width  = cast(u32) xwa.width;
            if xwa.height > 0 w.height = cast(u32) xwa.height;
        }
    }

    return w;
}

CrossWindow :: (wd: u32, ht: u32, name_id := "app", $type: WINDOW_TYPE) -> *void
    #modify { return type != .X11; }
{
    _ := wd; _ := ht; _ := name_id;
    assert(false, "CrossWindow: backend % not implemented yet (X11 only for now)", type);
    return null;
}

CrossWindow :: (wd: u32, ht: u32, name_id := "app") -> *X11Window {
    return CrossWindow(wd, ht, name_id, .X11);
}

Destroy :: (w: *X11Window) {
    if !w return;
    if w.alive && x11_display && w.xid != None {
        XLockDisplay(x11_display);
        XDestroyWindow(x11_display, w.xid);
        XFlush(x11_display);
        XUnlockDisplay(x11_display);
        w.xid = None;
        w.alive = false;
    }

    for i: 0..x11_windows.count-1 {
        if x11_windows[i] == w {
            array_ordered_remove_by_index(*x11_windows, i);
            break;
        }
    }

    array_free(w.pending);
    array_free(w.events);
    if w.name_id.count then free(w.name_id.data);
    free(w);

    x11_refcount -= 1;
    if x11_refcount <= 0 && x11_display {
        XCloseDisplay(x11_display);
        x11_display = null;
        x11_refcount = 0;
        array_free(x11_windows);
    }
}

GetDimensions :: (w: *X11Window) -> x: s32, y: s32, width: u32, height: u32, success: bool {
    if !w || !w.alive || !x11_display || w.xid == None {
        return 0, 0, 0, 0, false;
    }

    xwa: XWindowAttributes;
    if XGetWindowAttributes(x11_display, w.xid, *xwa) == 0 {
        return 0, 0, 0, 0, false;
    }
    w.x = xwa.x;
    w.y = xwa.y;
    if xwa.width > 0  w.width  = cast(u32) xwa.width;
    if xwa.height > 0 w.height = cast(u32) xwa.height;
    return w.x, w.y, w.width, w.height, true;
}

PollEvents :: (w: *X11Window) -> [] BaseEvent {
    assert(w != null, "PollEvents: null window");
    array_reset(*w.events);

    if x11_display {
        x11_pump_display();
    }

    for w.pending {
        array_add(*w.events, it);
    }
    array_reset(*w.pending);
    return w.events;
}

#scope_file

x11_find_by_xid :: (xid: Window) -> *X11Window {
    for x11_windows {
        if it && it.alive && it.xid == xid return it;
    }
    return null;
}

x11_push :: (target: *X11Window, e: BaseEvent) {
    if !target return;
    array_add(*target.pending, e);
}

x11_key_from_keysym :: (ks: KeySym) -> u8 {
    // Printable ASCII / common controls. Specials left as low KeySym bytes when useful.
    if ks == XK_BackSpace return 8;
    if ks == XK_Tab return 9;
    if ks == XK_Return return 13;
    if ks == XK_Escape return 27;
    if ks == XK_Delete return 127;
    if ks == 32 || ks == XK_KP_Space return 32;

    if ks >= XK_F1 && ks <= XK_F12 {
        return cast(u8) (0x80 + (ks - XK_F1)); // 0x80..0x8B
    }
    if ks == XK_Left  return 0x90;
    if ks == XK_Up    return 0x91;
    if ks == XK_Right return 0x92;
    if ks == XK_Down  return 0x93;

    masked := ks & 0xFF;
    if masked >= #char "a" && masked <= #char "z" {
        return cast(u8) (masked - 0x20); // uppercase
    }
    if masked > 32 && masked < 127 {
        return cast(u8) masked;
    }
    return 0;
}

x11_button_from_x :: (button: u32) -> MOUSE_BUTTON {
    if button == 1 return .LEFT;
    if button == 2 return .MIDDLE;
    if button == 3 return .RIGHT;
    if button == 4 return .WHEEL_UP;
    if button == 5 return .WHEEL_DOWN;
    if button == 8 return .X1;
    if button == 9 return .X2;
    return .LEFT;
}

x11_dispatch_event :: (ev: *XEvent) {
    xid: Window = None;
    if ev.type == {
        case KeyPress;       xid = ev.xkey.window;
        case KeyRelease;     xid = ev.xkey.window;
        case ButtonPress;    xid = ev.xbutton.window;
        case ButtonRelease;  xid = ev.xbutton.window;
        case MotionNotify;   xid = ev.xmotion.window;
        case ConfigureNotify; xid = ev.xconfigure.window;
        case FocusIn;        xid = ev.xfocus.window;
        case FocusOut;       xid = ev.xfocus.window;
        case ClientMessage;  xid = ev.xclient.window;
        case DestroyNotify;  xid = ev.xdestroywindow.window;
        case;                return;
    }

    target := x11_find_by_xid(xid);
    if !target return;

    if ev.type == ClientMessage {
        if ev.xclient.message_type == x11_wm_protocols {
            atom := cast(Atom) ev.xclient.data.l[0];
            if atom == x11_wm_delete {
                x11_push(target, WindowQuitEvent(cast(*void) target));
            }
        }
        return;
    }

    if ev.type == DestroyNotify {
        target.alive = false;
        x11_push(target, WindowQuitEvent(cast(*void) target));
        return;
    }

    if ev.type == ConfigureNotify {
        cfg := ev.xconfigure;
        moved := cfg.x != target.x || cfg.y != target.y;
        resized := cast(u32) cfg.width != target.width || cast(u32) cfg.height != target.height;
        target.x = cfg.x;
        target.y = cfg.y;
        if cfg.width > 0  target.width  = cast(u32) cfg.width;
        if cfg.height > 0 target.height = cast(u32) cfg.height;
        if moved {
            x11_push(target, WindowMoveEvent(cast(*void) target, target.x, target.y));
        }
        if resized {
            x11_push(target, WindowResizeEvent(cast(*void) target, target.width, target.height));
        }
        return;
    }

    if ev.type == FocusIn {
        x11_push(target, WindowFocusEvent(cast(*void) target));
        return;
    }
    if ev.type == FocusOut {
        x11_push(target, WindowFocusLostEvent(cast(*void) target));
        return;
    }

    if ev.type == KeyPress || ev.type == KeyRelease {
        keysym := XLookupKeysym(*ev.xkey, 0);
        key := x11_key_from_keysym(keysym);
        action := ifx ev.type == KeyPress then KEY_ACTION.PRESS else KEY_ACTION.RELEASE;
        x11_push(target, KeyboardEvent(cast(*void) target, key, action));
        return;
    }

    if ev.type == ButtonPress || ev.type == ButtonRelease {
        btn := x11_button_from_x(cast(u32) ev.xbutton.button);
        action := ifx ev.type == ButtonPress then KEY_ACTION.PRESS else KEY_ACTION.RELEASE;
        x := cast(s32) ev.xbutton.x;
        y := cast(s32) ev.xbutton.y;
        x11_push(target, MouseEvent(cast(*void) target, btn, action, x, y));
        return;
    }

    if ev.type == MotionNotify {
        // Encode move as mouse event with button 0 / action PRESS unused — use MOVE via action REPEAT? 
        // Keep a dedicated move: button LEFT + action REPEAT as "move" marker is ugly.
        // Store as MouseEvent with button=LEFT action=REPEAT for move (documented).
        x := cast(s32) ev.xmotion.x;
        y := cast(s32) ev.xmotion.y;
        x11_push(target, MouseEvent(cast(*void) target, .LEFT, .REPEAT, x, y));
        return;
    }
}

x11_pump_display :: () {
    if !x11_display return;
    XLockDisplay(x11_display);
    defer XUnlockDisplay(x11_display);

    while XPending(x11_display) > 0 {
        ev: XEvent;
        XNextEvent(x11_display, *ev);
        x11_dispatch_event(*ev);
    }
}
