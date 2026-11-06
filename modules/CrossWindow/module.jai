// CrossWindow — from-scratch multi-backend windowing (not a Window_Creation wrap).
// Context-style API: CrossWindow(wd, ht, name_id, $type = .X11 | .WAYLAND | …)
// Event payload: packed BaseEvent (32 bytes). Decode helpers assert category.

#import "Basic";
#import "String";

WINDOW_TYPE :: enum u8 {
    X11;
    WAYLAND;
    ANDROID;
    JS_CANVAS;
    // WIN32 / COCOA / UIKIT later
}

EVENT_CATEGORY :: enum u8 {
    UNKNOWN :: 0;
    DEAD;
    // Window
    WINDOW_QUIT;
    WINDOW_RESIZE;
    WINDOW_MOVE;
    WINDOW_FOCUS;
    WINDOW_FOCUS_LOST;
    // Input
    INPUT_KEYBOARD;
    INPUT_MOUSE;
    INPUT_TOUCH;
    INPUT_GAMEPAD;
    INPUT_JOYSTICK;
    // User-defined: dataU8[0] >= USER
    USER;
}

KEY_ACTION :: enum u8 {
    RELEASE :: 0;
    PRESS   :: 1;
    REPEAT  :: 2;
}

MOUSE_BUTTON :: enum u8 {
    LEFT       :: 1;
    MIDDLE     :: 2;
    RIGHT      :: 3;
    X1         :: 4;
    X2         :: 5;
    WHEEL_UP   :: 6;
    WHEEL_DOWN :: 7;
}

// 32-byte packed event. Layout (little-endian):
//   byte 0        = EVENT_CATEGORY
//   bytes 8..15   = window pointer (dataU64[1])
//   bytes 16..19  = dataU32[4]  (width / x / key / button)
//   bytes 20..23  = dataU32[5]  (height / y / action)
BaseEvent :: struct {
    union {
        dataU8:  [32] u8;
        dataU16: [16] u16;
        dataU32: [8] u32;
        dataU64: [4] u64;
    }
}

operator == :: inline (e: BaseEvent, category: EVENT_CATEGORY) -> bool {
    cat := e.dataU8[0];
    if category == .USER {
        return cat >= cast(u8) EVENT_CATEGORY.USER;
    }
    return cat == cast(u8) category;
}

event_window_ptr :: inline (e: BaseEvent) -> *void {
    return cast(*void) e.dataU64[1];
}

event_set_window :: inline (e: *BaseEvent, w: *void) {
    e.dataU64[1] = cast(u64) w;
}

event_assert_category :: (e: BaseEvent, category: EVENT_CATEGORY, loc := #caller_location) {
    assert(e == category, "BaseEvent category mismatch: got % expected % (at %:%)",
        cast(u8) e.dataU8[0], cast(u8) category, loc.fully_pathed_filename, loc.line_number);
}

// --- WINDOW EVENTS ---

WindowQuitEvent :: (w: *void) -> BaseEvent {
    e: BaseEvent;
    e.dataU8[0] = cast(u8) EVENT_CATEGORY.WINDOW_QUIT;
    event_set_window(*e, w);
    return e;
}
WindowQuitEvent :: (e: BaseEvent) -> *void {
    event_assert_category(e, .WINDOW_QUIT);
    return event_window_ptr(e);
}

WindowResizeEvent :: (w: *void, width: u32, height: u32) -> BaseEvent {
    e: BaseEvent;
    e.dataU8[0] = cast(u8) EVENT_CATEGORY.WINDOW_RESIZE;
    event_set_window(*e, w);
    e.dataU32[4] = width;
    e.dataU32[5] = height;
    return e;
}
WindowResizeEvent :: (e: BaseEvent) -> *void, u32, u32 {
    event_assert_category(e, .WINDOW_RESIZE);
    return event_window_ptr(e), e.dataU32[4], e.dataU32[5];
}

WindowMoveEvent :: (w: *void, x: s32, y: s32) -> BaseEvent {
    e: BaseEvent;
    e.dataU8[0] = cast(u8) EVENT_CATEGORY.WINDOW_MOVE;
    event_set_window(*e, w);
    e.dataU32[4] = cast(u32) x;
    e.dataU32[5] = cast(u32) y;
    return e;
}
WindowMoveEvent :: (e: BaseEvent) -> *void, s32, s32 {
    event_assert_category(e, .WINDOW_MOVE);
    return event_window_ptr(e), cast(s32) e.dataU32[4], cast(s32) e.dataU32[5];
}

WindowFocusEvent :: (w: *void) -> BaseEvent {
    e: BaseEvent;
    e.dataU8[0] = cast(u8) EVENT_CATEGORY.WINDOW_FOCUS;
    event_set_window(*e, w);
    return e;
}
WindowFocusEvent :: (e: BaseEvent) -> *void {
    event_assert_category(e, .WINDOW_FOCUS);
    return event_window_ptr(e);
}

WindowFocusLostEvent :: (w: *void) -> BaseEvent {
    e: BaseEvent;
    e.dataU8[0] = cast(u8) EVENT_CATEGORY.WINDOW_FOCUS_LOST;
    event_set_window(*e, w);
    return e;
}
WindowFocusLostEvent :: (e: BaseEvent) -> *void {
    event_assert_category(e, .WINDOW_FOCUS_LOST);
    return event_window_ptr(e);
}

// --- INPUT EVENTS ---

KeyboardEvent :: (w: *void, key: u8, action: KEY_ACTION) -> BaseEvent {
    e: BaseEvent;
    e.dataU8[0] = cast(u8) EVENT_CATEGORY.INPUT_KEYBOARD;
    event_set_window(*e, w);
    e.dataU8[16] = key;
    e.dataU8[17] = cast(u8) action;
    return e;
}
KeyboardEvent :: (e: BaseEvent) -> *void, u8, KEY_ACTION {
    event_assert_category(e, .INPUT_KEYBOARD);
    return event_window_ptr(e), e.dataU8[16], cast(KEY_ACTION) e.dataU8[17];
}

MouseEvent :: (w: *void, button: MOUSE_BUTTON, action: KEY_ACTION, x: s32, y: s32) -> BaseEvent {
    e: BaseEvent;
    e.dataU8[0] = cast(u8) EVENT_CATEGORY.INPUT_MOUSE;
    event_set_window(*e, w);
    e.dataU8[16] = cast(u8) button;
    e.dataU8[17] = cast(u8) action;
    e.dataU32[5] = cast(u32) ((x & 0xFFFF) | ((y & 0xFFFF) << 16));
    return e;
}
MouseEvent :: (e: BaseEvent) -> *void, MOUSE_BUTTON, KEY_ACTION, s32, s32 {
    event_assert_category(e, .INPUT_MOUSE);
    packed := e.dataU32[5];
    return event_window_ptr(e),
        cast(MOUSE_BUTTON) e.dataU8[16],
        cast(KEY_ACTION) e.dataU8[17],
        cast(s32) cast(s16) (packed & 0xFFFF),
        cast(s32) cast(s16) ((packed >> 16) & 0xFFFF);
}

UserEvent :: (w: *void, code: u8) -> BaseEvent {
    assert(code >= cast(u8) EVENT_CATEGORY.USER, "UserEvent: code must be >= USER");
    e: BaseEvent;
    e.dataU8[0] = code;
    event_set_window(*e, w);
    return e;
}
UserEvent :: (e: BaseEvent) -> *void, u8 {
    assert(e == .USER, "UserEvent: not a user category");
    return event_window_ptr(e), e.dataU8[0];
}

#if OS == .LINUX {
    #import "X11";
    #load "x11.jai";
} else #if OS == .WASM {
    #load "js_canvas.jai";
} else {
    // Other platforms later.
    CrossWindow :: (wd: u32, ht: u32, name_id := "app", $type: WINDOW_TYPE) -> *void {
        _ := wd; _ := ht; _ := name_id; _ := type;
        assert(false, "CrossWindow: no backend for this OS yet");
        return null;
    }
    Destroy :: (w: *void) { _ := w; }
    GetDimensions :: (w: *void) -> x: s32, y: s32, width: u32, height: u32, success: bool {
        _ := w;
        return 0, 0, 0, 0, false;
    }
    PollEvents :: (w: *void) -> [] BaseEvent {
        _ := w;
        return .{};
    }
}
