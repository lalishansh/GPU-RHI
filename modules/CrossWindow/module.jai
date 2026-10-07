#import "Basic";
#import "String";

#if OS != .WASM {
    HostWindow :: #import "Window_Creation";
    HostInput :: #import "Input";
}

CrossEventKind :: enum u8 {
    WINDOW;
    MOUSE;
    KEYBOARD;
    TOUCH;
}

CrossEventWindowType :: enum u8 {
    QUIT;
    RESIZE;
    MOVED_TO_BACKGROUND;
    MOVED_TO_FOREGROUND;
}

CrossEventWindow :: struct {
    type: CrossEventWindowType;
    width: u32;
    height: u32;
}

CrossEventMouseType :: enum u8 {
    KEY_DOWN;
    KEY_UP;
    MOVE;
    SCROLL;
}

CrossEventMouse :: struct {
    type: CrossEventMouseType;
    union {
        key: s32;
        posn: [2]s32;
        scroll: [2]s32;
    }
}

CrossEventKeyboardType :: enum u8 {
    KEY_DOWN;
    KEY_UP;
    TEXT_INPUT;
    KEY_REPEAT;
}

CrossEventKeyboard :: struct {
    type: CrossEventKeyboardType;
    key: s32;
}

CrossEventTouchType :: enum u8 {
    TOUCH_START;
    TOUCH_END;
    TOUCH_MOVE;
    TOUCH_CANCEL;
}

CrossEventTouch :: struct {
    type: CrossEventTouchType;
    pointer_id: s32;
    posn: [2]s32;
    pressure: float32;
}

CrossEvent :: struct {
    kind: CrossEventKind;
    union {
        window: CrossEventWindow;
        mouse: CrossEventMouse;
        keyboard: CrossEventKeyboard;
        touch: CrossEventTouch;
    }
}

CrossWindowType :: struct {
    width: u32;
    height: u32;
    name_id: string;
    events: [..]CrossEvent;
    mouse_x: s32 = -1;
    mouse_y: s32 = -1;
    mouse_valid := false;
    // Bit 0..2: left, middle, right were down on the previous poll.
    mouse_buttons_down: u32;
    #if OS != .WASM {
        host: HostWindow.Window_Type;
    }
}

CrossWindow :: (wd: u32, ht: u32, name_id := "app") -> CrossWindowType {
    w: CrossWindowType;
    w.width = wd;
    w.height = ht;
    w.name_id = copy_string(name_id);

    #if OS == .WASM {
        jsEnsureCanvas(w.name_id.data, xx w.name_id.count, wd, ht);
    } else {
        w.host = HostWindow.create_window(wd, ht, name_id);
        _, _, real_w, real_h := HostWindow.get_dimensions(w.host, false);
        if real_w > 0 w.width = cast(u32) real_w;
        if real_h > 0 w.height = cast(u32) real_h;
    }

    return w;
}

PollWindowEvents :: (window: *CrossWindowType) -> []CrossEvent {
    array_reset(*window.events);

    #if OS == .WASM {
        while true {
            kind: s32;
            subtype: s32;
            i0, i1, i2: s32;
            pressure: float32;
            if !jsPollInputEvent(*kind, *subtype, *i0, *i1, *i2, *pressure) break;
            push_packed_event(window, kind, subtype, i0, i1, i2, pressure);
        }
    } else {
        HostInput.update_window_events();

        for HostInput.get_window_resizes() {
            if it.window == window.host {
                window.width = cast(u32) it.width;
                window.height = cast(u32) it.height;
                push_window(window, .RESIZE, window.width, window.height);
            }
        }

        for HostInput.events_this_frame {
            if it.type == .QUIT {
                push_window(window, .QUIT, 0, 0);
                continue;
            }

            if it.type == .WINDOW {
                if it.window_event_type == .MOVED_TO_BACKGROUND {
                    window.host = HostWindow.WT.INVALID_WINDOW;
                    window.mouse_valid = false;
                    push_window(window, .MOVED_TO_BACKGROUND, 0, 0);
                } else if it.window_event_type == .MOVED_TO_FOREGROUND {
                    window.host = it.window;
                    _, _, real_w, real_h := HostWindow.get_dimensions(window.host, false);
                    if real_w > 0 window.width = cast(u32) real_w;
                    if real_h > 0 window.height = cast(u32) real_h;
                    push_window(window, .MOVED_TO_FOREGROUND, window.width, window.height);
                }
                continue;
            }

            if it.type == .KEYBOARD {
                // Linux clicks are edge-detected from XQueryPointer below.
                // The Input module's ButtonPress path does not deliver them here.
                #if OS != .LINUX {
                    if host_is_mouse_button(it.key_code) {
                        ev: CrossEvent;
                        ev.kind = .MOUSE;
                        ev.mouse.type = ifx it.key_pressed then .KEY_DOWN else .KEY_UP;
                        ev.mouse.key = cast(s32) it.key_code;
                        array_add(*window.events, ev);
                        continue;
                    }
                }
                if !host_is_mouse_button(it.key_code) {
                    ev: CrossEvent;
                    ev.kind = .KEYBOARD;
                    if it.repeat {
                        ev.keyboard.type = .KEY_REPEAT;
                    } else if it.key_pressed {
                        ev.keyboard.type = .KEY_DOWN;
                    } else {
                        ev.keyboard.type = .KEY_UP;
                    }
                    ev.keyboard.key = cast(s32) it.key_code;
                    array_add(*window.events, ev);
                }
                continue;
            }

            if it.type == .TEXT_INPUT {
                ev: CrossEvent;
                ev.kind = .KEYBOARD;
                ev.keyboard.type = .TEXT_INPUT;
                ev.keyboard.key = cast(s32) it.utf32;
                array_add(*window.events, ev);
                continue;
            }

            if it.type == .MOUSE_WHEEL {
                ev: CrossEvent;
                ev.kind = .MOUSE;
                ev.mouse.type = .SCROLL;
                ev.mouse.scroll = .[cast(s32) it.wheel_delta, 0];
                array_add(*window.events, ev);
                continue;
            }

            if it.type == .TOUCH {
                ev: CrossEvent;
                ev.kind = .TOUCH;
                if it.touch_type == {
                    case .PRESSED;  ev.touch.type = .TOUCH_START;
                    case .RELEASED; ev.touch.type = .TOUCH_END;
                    case .MOVED;    ev.touch.type = .TOUCH_MOVE;
                    case;           ev.touch.type = .TOUCH_CANCEL;
                }
                ev.touch.pointer_id = cast(s32) it.touch_index;
                ev.touch.posn = .[cast(s32) it.touch_x, cast(s32) it.touch_y];
                ev.touch.pressure = ifx it.touch_type == .RELEASED then 0.0 else 1.0;
                array_add(*window.events, ev);
            }
        }

        if window.host != HostWindow.WT.INVALID_WINDOW {
            #if OS == .LINUX {
                poll_linux_pointer(window);
            } else {
                mx, my, ok := HostWindow.get_mouse_pointer_position(window.host, false);
                if ok {
                    note_mouse_move(window, cast(s32) mx, cast(s32) my);
                }
            }
        }
    }

    return window.events;
}

Destroy_CrossWindow :: (window: *CrossWindowType) {
    array_free(window.events);
    if window.name_id.count free(window.name_id.data);
    window.* = CrossWindowType.{};
}

push_window :: (window: *CrossWindowType, type: CrossEventWindowType, width: u32, height: u32) {
    ev: CrossEvent;
    ev.kind = .WINDOW;
    ev.window.type = type;
    ev.window.width = width;
    ev.window.height = height;
    array_add(*window.events, ev);
}

push_packed_event :: (window: *CrossWindowType, kind: s32, subtype: s32, i0: s32, i1: s32, i2: s32, pressure: float32) {
    if kind == cast(s32) CrossEventKind.WINDOW {
        wtype := cast(CrossEventWindowType) subtype;
        if wtype == .RESIZE {
            window.width = cast(u32) i0;
            window.height = cast(u32) i1;
        }
        push_window(window, wtype, cast(u32) i0, cast(u32) i1);
        return;
    }

    ev: CrossEvent;
    if kind == cast(s32) CrossEventKind.MOUSE {
        ev.kind = .MOUSE;
        ev.mouse.type = cast(CrossEventMouseType) subtype;
        if ev.mouse.type == .MOVE {
            ev.mouse.posn = .[i0, i1];
        } else if ev.mouse.type == .SCROLL {
            ev.mouse.scroll = .[i0, i1];
        } else {
            ev.mouse.key = i0;
        }
    } else if kind == cast(s32) CrossEventKind.KEYBOARD {
        ev.kind = .KEYBOARD;
        ev.keyboard.type = cast(CrossEventKeyboardType) subtype;
        ev.keyboard.key = i0;
    } else if kind == cast(s32) CrossEventKind.TOUCH {
        ev.kind = .TOUCH;
        ev.touch.type = cast(CrossEventTouchType) subtype;
        ev.touch.pointer_id = i0;
        ev.touch.posn = .[i1, i2];
        ev.touch.pressure = pressure;
    } else {
        return;
    }
    array_add(*window.events, ev);
}

note_mouse_move :: (window: *CrossWindowType, x: s32, y: s32) {
    if window.mouse_valid && (x != window.mouse_x || y != window.mouse_y) {
        ev: CrossEvent;
        ev.kind = .MOUSE;
        ev.mouse.type = .MOVE;
        ev.mouse.posn = .[x, y];
        array_add(*window.events, ev);
    }
    window.mouse_x = x;
    window.mouse_y = y;
    window.mouse_valid = true;
}

#if OS == .LINUX {
    poll_linux_pointer :: (window: *CrossWindowType) {
        X11 :: #import "X11";
        root_x, root_y, win_x, win_y: s32;
        root, child: X11.Window;
        mask: u32;
        ok := X11.XQueryPointer(
            X11.x_global_display, window.host,
            *root, *child,
            *root_x, *root_y, *win_x, *win_y,
            *mask,
        );
        if ok == 0 return;

        x := win_x;
        y := win_y;
        note_mouse_move(window, x, y);

        inside := x >= 0 && y >= 0 && x < cast(s32) window.width && y < cast(s32) window.height;
        masks := u32.[X11.Button1Mask, X11.Button2Mask, X11.Button3Mask];
        keys := HostInput.Key_Code.[.MOUSE_BUTTON_LEFT, .MOUSE_BUTTON_MIDDLE, .MOUSE_BUTTON_RIGHT];
        for i: 0..2 {
            bit := cast(u32) (1 << cast(u32) i);
            down := (mask & masks[i]) != 0;
            was := (window.mouse_buttons_down & bit) != 0;
            if down == was continue;
            // Press only counts inside the window. Release still fires if the cursor left.
            if down && !inside continue;

            ev: CrossEvent;
            ev.kind = .MOUSE;
            ev.mouse.type = ifx down then .KEY_DOWN else .KEY_UP;
            ev.mouse.key = cast(s32) keys[i];
            array_add(*window.events, ev);

            if down window.mouse_buttons_down |= bit;
            else window.mouse_buttons_down &= ~bit;
        }
    }
}

#if OS != .WASM {
host_is_mouse_button :: (code: HostInput.Key_Code) -> bool {
    if code == {
        case .MOUSE_BUTTON_LEFT;
        case .MOUSE_BUTTON_MIDDLE;
        case .MOUSE_BUTTON_RIGHT;
        case .MOUSE_BUTTON_EXTRA_1;
        case .MOUSE_BUTTON_EXTRA_2;
            return true;
    }
    return false;
}
}

#if OS == .WASM {
    jsEnsureCanvas :: (id_data: *u8, id_count: s64, w: u32, h: u32) #foreign;
    // kind, subtype, i0, i1, i2, pressure. Returns 1 when an event was written.
    jsPollInputEvent :: (out_kind: *s32, out_type: *s32, out_i0: *s32, out_i1: *s32, out_i2: *s32, out_pressure: *float32) -> s32 #foreign;
}
