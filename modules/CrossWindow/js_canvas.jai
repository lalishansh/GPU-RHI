// WASM / browser canvas backend — multi-canvas via DOM id (name_id).

JsCanvasWindow :: struct {
    width: u32;
    height: u32;
    x: s32;
    y: s32;
    name_id: string;
    pending: [..] BaseEvent;
    events: [..] BaseEvent;
    alive: bool;
}

jsEnsureCanvas :: (id_data: *u8, id_count: s64, w: u32, h: u32) #foreign;
jsGetCanvasRect :: (id_data: *u8, id_count: s64, x: *s32, y: *s32, width: *u32, height: *u32) -> s32 #foreign;
jsPollInputEvent :: (out_kind: *s32, out_type: *s32, out_i0: *s32, out_i1: *s32, out_i2: *s32, out_pressure: *float) -> s32 #foreign;

CrossWindow :: (wd: u32, ht: u32, name_id := "app", $type: WINDOW_TYPE) -> *JsCanvasWindow
    #modify { return type == .JS_CANVAS; }
{
    assert(wd >= 1 && ht >= 1, "CrossWindow(JS_CANVAS): size must be >= 1");
    assert(name_id.count > 0, "CrossWindow(JS_CANVAS): name_id required (canvas DOM id)");

    w := New(JsCanvasWindow);
    w.width = wd;
    w.height = ht;
    w.x = 0;
    w.y = 0;
    w.name_id = copy_string(name_id);
    w.alive = true;

    jsEnsureCanvas(w.name_id.data, xx w.name_id.count, wd, ht);
    _, _, cw, ch, ok := GetDimensions(w);
    if ok {
        if cw > 0 w.width = cw;
        if ch > 0 w.height = ch;
    }
    return w;
}

CrossWindow :: (wd: u32, ht: u32, name_id := "app", $type: WINDOW_TYPE) -> *void
    #modify { return type != .JS_CANVAS; }
{
    _ := wd; _ := ht; _ := name_id;
    assert(false, "CrossWindow: backend % not available on WASM (use .JS_CANVAS)", type);
    return null;
}

CrossWindow :: (wd: u32, ht: u32, name_id := "app") -> *JsCanvasWindow {
    return CrossWindow(wd, ht, name_id, .JS_CANVAS);
}

Destroy :: (w: *JsCanvasWindow) {
    if !w return;
    array_free(w.pending);
    array_free(w.events);
    if w.name_id.count then free(w.name_id.data);
    w.alive = false;
    free(w);
}

GetDimensions :: (w: *JsCanvasWindow) -> x: s32, y: s32, width: u32, height: u32, success: bool {
    if !w || !w.alive || w.name_id.count == 0 return 0, 0, 0, 0, false;
    cx, cy: s32;
    cw, ch: u32;
    ok := jsGetCanvasRect(w.name_id.data, xx w.name_id.count, *cx, *cy, *cw, *ch);
    if ok == 0 || cw == 0 || ch == 0 return cx, cy, 0, 0, false;
    w.x = cx;
    w.y = cy;
    w.width = cw;
    w.height = ch;
    return cx, cy, cw, ch, true;
}

PollEvents :: (w: *JsCanvasWindow) -> [] BaseEvent {
    assert(w != null, "PollEvents: null window");
    array_reset(*w.events);

    // Drain browser event queue; map into BaseEvent. Old bridge kinds:
    // 0=WINDOW (subtype: 0 quit, 1 resize), 1=MOUSE, 2=KEYBOARD, 3=TOUCH
    while true {
        kind, subtype, i0, i1, i2: s32;
        pressure: float;
        if jsPollInputEvent(*kind, *subtype, *i0, *i1, *i2, *pressure) == 0 break;

        if kind == 0 { // WINDOW
            if subtype == 0 {
                array_add(*w.pending, WindowQuitEvent(cast(*void) w));
            } else if subtype == 1 {
                if i0 > 0 w.width = cast(u32) i0;
                if i1 > 0 w.height = cast(u32) i1;
                array_add(*w.pending, WindowResizeEvent(cast(*void) w, w.width, w.height));
            }
        } else if kind == 2 { // KEYBOARD — subtype: 0 up, 1 down, 2 repeat
            action := KEY_ACTION.RELEASE;
            if subtype == 1 action = .PRESS;
            else if subtype == 2 action = .REPEAT;
            array_add(*w.pending, KeyboardEvent(cast(*void) w, cast(u8) i0, action));
        } else if kind == 1 { // MOUSE — subtype: 0 up, 1 down, 2 move, 3 scroll
            if subtype == 2 {
                array_add(*w.pending, MouseEvent(cast(*void) w, .LEFT, .REPEAT, i0, i1));
            } else if subtype == 3 {
                array_add(*w.pending, MouseEvent(cast(*void) w, .WHEEL_UP, .PRESS, i0, i1));
            } else {
                action := ifx subtype == 1 then KEY_ACTION.PRESS else KEY_ACTION.RELEASE;
                btn := MOUSE_BUTTON.LEFT;
                if i0 == 1 btn = .MIDDLE;
                else if i0 == 2 btn = .RIGHT;
                array_add(*w.pending, MouseEvent(cast(*void) w, btn, action, i1, i2));
            }
        }
    }

    // Synthesize WINDOW_RESIZE when the canvas bitmap changed (ResizeObserver /
    // CSS layout) even if no explicit push_resize was queued yet.
    prev_w := w.width;
    prev_h := w.height;
    _, _, cw, ch, ok := GetDimensions(w);
    if ok && cw > 0 && ch > 0 && (cw != prev_w || ch != prev_h) {
        array_add(*w.pending, WindowResizeEvent(cast(*void) w, cw, ch));
    }

    for w.pending array_add(*w.events, it);
    array_reset(*w.pending);
    return w.events;
}
