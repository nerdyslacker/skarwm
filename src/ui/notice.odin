package ui

import logger "../log"
import c "../core"
import x11 "../x11"

import "core:time"
import "core:strings"

NOTICE_HEIGHT   :: i32(46)
NOTICE_PAD_X    :: i32(18)
NOTICE_MARGIN_Y :: i32(28)
NOTICE_DURATION :: 2500 * time.Millisecond

notice_geometry :: proc(m: ^c.Manager, text: string) -> c.Rect {
    area := c.Rect{X = 0, Y = 0, W = 800, H = 600}
    if o := c.Active_Output(m); o != nil { area = o.Geom }
    wanted := i32(len(text)) * 6 + 2 * NOTICE_PAD_X
    width := min(max(i32(180), wanted), max(i32(1), area.W - 24))
    return c.Rect{
        X = area.X + (area.W - width) / 2,
        Y = area.Y + NOTICE_MARGIN_Y,
        W = width,
        H = min(NOTICE_HEIGHT, max(i32(1), area.H - NOTICE_MARGIN_Y)),
    }
}

Draw_Notice :: proc(state: ^State, m: ^c.Manager) {
    if state == nil || state.NoticeWindow == 0 || state.NoticeText == "" { return }
    bg := m.Cfg.UnfocusedBorder
    vals := [2]u32{state.WhitePixel, bg}
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &vals[0])
    n := min(len(state.NoticeText), 255)
    if n > 0 {
        x11.xcb_image_text_8(
            state.Conn, u8(n), state.NoticeWindow, state.TabGC,
            i16(NOTICE_PAD_X), 28, cstring(raw_data(state.NoticeText)),
        )
    }
    x11.xcb_flush(state.Conn)
}

show_notice_internal :: proc(state: ^State, m: ^c.Manager, text: string, persistent: bool) {
    if state == nil || state.Conn == nil || m == nil || text == "" { return }
    Hide_Notice(state)
    Init_Tabs(state)
    rect := notice_geometry(m, text)
    bg := m.Cfg.UnfocusedBorder
    border := m.Cfg.FocusedBorder
    xid := x11.xcb_generate_id(state.Conn)
    vals := [4]u32{bg, border, 1, x11.EVENT_MASK_EXPOSURE | x11.EVENT_MASK_BUTTON_PRESS}
    cookie := x11.xcb_create_window_checked(
        state.Conn, 0, xid, state.Root,
        i16(rect.X), i16(rect.Y), u16(rect.W), u16(rect.H),
        2, x11.WINDOW_CLASS_INPUT_OUTPUT, 0,
        x11.CW_BACK_PIXEL | x11.CW_BORDER_PIXEL | x11.CW_OVERRIDE_REDIRECT | x11.CW_EVENT_MASK,
        &vals[0],
    )
    if err := x11.xcb_request_check(state.Conn, cookie); err != nil {
        xe := (^x11.X_Error)(err)
        logger.Error("cannot create notice overlay; X error", xe.error_code,
                     "request", xe.major_code, "resource", xe.resource_id)
        x11.free_libc(err)
        return
    }
    state.NoticeWindow = xid
    state.NoticeText = strings.clone(text)
    state.NoticePersistent = persistent
    if !persistent {
        state.NoticeUntil = time.tick_add(time.tick_now(), NOTICE_DURATION)
    }
    x11.set_prop_text(state.Conn, xid, atom(state, "_NET_WM_NAME"), atom(state, "UTF8_STRING"), "skarwm notice")
    x11.set_prop_text(state.Conn, xid, atom(state, "WM_NAME"), atom(state, "STRING"), "skarwm notice")
    x11.xcb_map_window(state.Conn, xid)
    stack := x11.STACK_MODE_ABOVE
    x11.xcb_configure_window(state.Conn, xid, x11.CW_STACK_MODE, &stack)
    Draw_Notice(state, m)
}

Show_Notice :: proc(state: ^State, m: ^c.Manager, text: string) {
    // Status feedback must not silently dismiss an unread reminder.
    if state != nil && state.NoticeWindow != 0 && state.NoticePersistent { return }
    show_notice_internal(state, m, text, false)
}

Show_Persistent_Notice :: proc(state: ^State, m: ^c.Manager, text: string) {
    if state == nil || text == "" { return }
    if state.NoticeWindow != 0 && state.NoticePersistent && state.NoticeText != "" {
        combined := strings.concatenate({state.NoticeText, "; ", text})
        defer delete(combined)
        show_notice_internal(state, m, combined, true)
        return
    }
    show_notice_internal(state, m, text, true)
}

Hide_Notice :: proc(state: ^State) {
    if state == nil { return }
    if state.Conn != nil && state.NoticeWindow != 0 {
        x11.xcb_destroy_window(state.Conn, state.NoticeWindow)
    }
    state.NoticeWindow = 0
    if state.NoticeText != "" { delete(state.NoticeText) }
    state.NoticeText = ""
    state.NoticeUntil = {}
    state.NoticePersistent = false
    if state.Conn != nil { x11.xcb_flush(state.Conn) }
}

Notice_Poll_Timeout_Ms :: proc(state: ^State) -> i32 {
    if state == nil || state.NoticeWindow == 0 || state.NoticePersistent { return -1 }
    remaining := time.tick_diff(time.tick_now(), state.NoticeUntil)
    if remaining <= 0 { return 0 }
    ns := i64(remaining)
    return i32((ns + i64(time.Millisecond) - 1) / i64(time.Millisecond))
}

Hide_Due_Notice :: proc(state: ^State) {
    if state == nil || state.NoticeWindow == 0 || state.NoticePersistent { return }
    if time.tick_diff(state.NoticeUntil, time.tick_now()) >= 0 {
        Hide_Notice(state)
    }
}
