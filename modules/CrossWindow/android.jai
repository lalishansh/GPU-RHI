// Android backend — wraps Window_Creation + Input into CrossWindow BaseEvent API.
// Lifecycle: TERM_WINDOW → host null / FOCUS_LOST; INIT_WINDOW → new ANativeWindow / FOCUS.

HostWindow :: #import "Window_Creation";
HostInput  :: #import "Input";

#scope_file
Android :: #import "Android";
#scope_export

AndroidWindow :: struct {
    host: *Android.ANativeWindow;
    width: u32;
    height: u32;
    name_id: string;
    pending: [..] BaseEvent;
    events: [..] BaseEvent;
    alive: bool;
}

#scope_file

android_windows: [..]*AndroidWindow;

android_sync_dims :: (w: *AndroidWindow) {
    if w.host == null || w.host == HostWindow.WT.INVALID_WINDOW return;
    _, _, rw, rh := HostWindow.get_dimensions(w.host, false);
    if rw > 0 w.width = cast(u32) rw;
    if rh > 0 w.height = cast(u32) rh;
}

#scope_export

GetNativeAndroid :: (w: *AndroidWindow) -> *Android.ANativeWindow {
    assert(w != null && w.alive, "GetNativeAndroid: invalid window");
    return w.host;
}

CrossWindow :: (wd: u32, ht: u32, name_id := "app", $type: WINDOW_TYPE) -> *AndroidWindow
    #modify { return type == .ANDROID; }
{
    assert(wd >= 1 && ht >= 1, "CrossWindow(Android): size must be >= 1");
    // Android module delays main until INIT_WINDOW when WAIT_TILL… is true.
    host := HostWindow.create_window(wd, ht, name_id);
    assert(host != null && host != HostWindow.WT.INVALID_WINDOW,
        "CrossWindow(Android): no ANativeWindow (wait for foreground)");

    w := New(AndroidWindow);
    w.host = host;
    w.width = wd;
    w.height = ht;
    w.name_id = copy_string(name_id);
    w.alive = true;
    android_sync_dims(w);
    array_add(*android_windows, w);
    return w;
}

CrossWindow :: (wd: u32, ht: u32, name_id := "app", $type: WINDOW_TYPE) -> *void
    #modify { return type != .ANDROID; }
{
    _ := wd; _ := ht; _ := name_id;
    assert(false, "CrossWindow: backend % not implemented on Android", type);
    return null;
}

CrossWindow :: (wd: u32, ht: u32, name_id := "app") -> *AndroidWindow {
    return CrossWindow(wd, ht, name_id, .ANDROID);
}

Destroy :: (w: *AndroidWindow) {
    if !w return;
    array_free(w.pending);
    array_free(w.events);
    if w.name_id.count free(w.name_id.data);
    for i: 0..android_windows.count-1 {
        if android_windows[i] == w {
            array_ordered_remove_by_index(*android_windows, i);
            break;
        }
    }
    w.* = .{};
    free(w);
}

GetDimensions :: (w: *AndroidWindow) -> x: s32, y: s32, width: u32, height: u32, success: bool {
    if !w || !w.alive return 0, 0, 0, 0, false;
    if w.host == null || w.host == HostWindow.WT.INVALID_WINDOW return 0, 0, 0, 0, false;
    hx, hy, hw, hh := HostWindow.get_dimensions(w.host, false);
    if hw <= 0 || hh <= 0 return hx, hy, 0, 0, false;
    return hx, hy, cast(u32) hw, cast(u32) hh, true;
}

PollEvents :: (w: *AndroidWindow) -> [] BaseEvent {
    assert(w != null && w.alive, "PollEvents(Android): invalid window");
    array_reset(*w.events);

    HostInput.update_window_events();

    for HostInput.get_window_resizes() {
        if it.window == w.host {
            w.width = cast(u32) it.width;
            w.height = cast(u32) it.height;
            array_add(*w.pending, WindowResizeEvent(w, w.width, w.height));
        }
    }

    for HostInput.events_this_frame {
        if it.type == .QUIT {
            array_add(*w.pending, WindowQuitEvent(w));
            continue;
        }

        if it.type == .WINDOW {
            if it.window_event_type == .MOVED_TO_BACKGROUND {
                // :AndroidLifeCycle — TERM_WINDOW; Present must not touch the old surface.
                w.host = HostWindow.WT.INVALID_WINDOW;
                array_add(*w.pending, WindowFocusLostEvent(w));
            } else if it.window_event_type == .MOVED_TO_FOREGROUND {
                w.host = it.window;
                android_sync_dims(w);
                array_add(*w.pending, WindowFocusEvent(w));
                if w.width > 0 && w.height > 0 {
                    array_add(*w.pending, WindowResizeEvent(w, w.width, w.height));
                }
            }
            continue;
        }

        if it.type == .KEYBOARD {
            action := ifx it.key_pressed then KEY_ACTION.PRESS else KEY_ACTION.RELEASE;
            if it.repeat action = .REPEAT;
            array_add(*w.pending, KeyboardEvent(w, cast(u8) it.key_code, action));
            continue;
        }

        if it.type == .TOUCH {
            // Synthetic mouse: press/release + move (LEFT+REPEAT) so ImGui can drag.
            x := cast(s32) it.touch_x;
            y := cast(s32) it.touch_y;
            if it.touch_type == .PRESSED {
                array_add(*w.pending, MouseEvent(w, .LEFT, .PRESS, x, y));
            } else if it.touch_type == .RELEASED {
                array_add(*w.pending, MouseEvent(w, .LEFT, .RELEASE, x, y));
            } else if it.touch_type == .MOVED {
                array_add(*w.pending, MouseEvent(w, .LEFT, .REPEAT, x, y));
            }
            continue;
        }
    }

    _, _, dw, dh, dim_ok := GetDimensions(w);
    if dim_ok && (dw != w.width || dh != w.height) {
        w.width = dw;
        w.height = dh;
        array_add(*w.pending, WindowResizeEvent(w, dw, dh));
    }

    for w.pending array_add(*w.events, it);
    array_reset(*w.pending);
    return w.events;
}
