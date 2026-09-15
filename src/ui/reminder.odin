package ui

import logger "../log"
import c "../core"
import x11 "../x11"

import "core:fmt"
import "core:strings"

REMINDER_PANEL_WIDTH  :: i32(540)
REMINDER_INPUT_HEIGHT :: i32(38)
REMINDER_MARGIN       :: i32(24)

reminder_clear_string :: proc(value: ^string) {
    if value^ != "" { delete(value^) }
    value^ = ""
}

reminder_clear_list :: proc(state: ^State) {
    for line in state.ReminderListLines { delete(line) }
    clear(&state.ReminderListLines)
}

reminder_panel_geometry :: proc(m: ^c.Manager, height: i32) -> c.Rect {
    area := c.Rect{X = 0, Y = 0, W = 800, H = 600}
    if o := c.Active_Output(m); o != nil { area = o.Geom }
    width := min(REMINDER_PANEL_WIDTH, max(i32(1), area.W - 32))
    panel_height := min(height, max(i32(1), area.H - 32))
    return c.Rect{
        X = area.X + (area.W - width) / 2,
        Y = area.Y + (area.H - panel_height) / 2,
        W = width,
        H = panel_height,
    }
}

reminder_create_panel :: proc(state: ^State, m: ^c.Manager, height: i32) -> bool {
    rect := reminder_panel_geometry(m, height)
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
        logger.Error("cannot create reminder panel; X error", xe.error_code,
                     "request", xe.major_code, "resource", xe.resource_id)
        x11.free_libc(err)
        return false
    }
    state.ReminderWindow = xid
    x11.set_prop_text(state.Conn, xid, atom(state, "_NET_WM_NAME"), atom(state, "UTF8_STRING"), "skarwm reminders")
    x11.xcb_map_window(state.Conn, xid)
    stack := x11.STACK_MODE_ABOVE
    x11.xcb_configure_window(state.Conn, xid, x11.CW_STACK_MODE, &stack)
    return true
}

reminder_create_input :: proc(state: ^State, x, y, width: i32, active: bool) -> u32 {
    xid := x11.xcb_generate_id(state.Conn)
    border := u32(0)
    if active { border = state.WhitePixel }
    vals := [3]u32{0x202020, border, x11.EVENT_MASK_EXPOSURE | x11.EVENT_MASK_BUTTON_PRESS}
    x11.xcb_create_window(
        state.Conn, 0, xid, state.ReminderWindow,
        i16(x), i16(y), u16(width), u16(REMINDER_INPUT_HEIGHT),
        2, x11.WINDOW_CLASS_INPUT_OUTPUT, 0,
        x11.CW_BACK_PIXEL | x11.CW_BORDER_PIXEL | x11.CW_EVENT_MASK, &vals[0],
    )
    x11.xcb_map_window(state.Conn, xid)
    return xid
}

Show_Reminder_Dialog :: proc(state: ^State, m: ^c.Manager) {
    if state == nil || state.Conn == nil || m == nil { return }
    Hide_Reminder_Panel(state)
    Init_Tabs(state)
    if !reminder_create_panel(state, m, 205) { return }
    state.ReminderListMode = false
    state.ReminderField = 0
    state.ReminderMinutesWindow = reminder_create_input(state, 24, 66, 100, true)
    state.ReminderMessageWindow = reminder_create_input(state, 144, 66, 370, false)
    Draw_Reminder_Panel(state, m)
}

Show_Reminder_List :: proc(state: ^State, m: ^c.Manager, lines: []string) {
    if state == nil || state.Conn == nil || m == nil { return }
    Hide_Reminder_Panel(state)
    Init_Tabs(state)
    shown := min(len(lines), 15)
    height := 72 + i32(shown) * 22
    if !reminder_create_panel(state, m, height) { return }
    state.ReminderListMode = true
    for i in 0 ..< shown { append(&state.ReminderListLines, strings.clone(lines[i])) }
    Draw_Reminder_Panel(state, m)
}

reminder_draw_text :: proc(state: ^State, window: u32, text: string, x, y: i16, max_chars: int = 255) {
    n := min(len(text), min(255, max_chars))
    if n > 0 {
        x11.xcb_image_text_8(state.Conn, u8(n), window, state.TabGC, x, y, cstring(raw_data(text)))
    }
}

Draw_Reminder_Panel :: proc(state: ^State, m: ^c.Manager) {
    if state == nil || state.ReminderWindow == 0 || m == nil { return }
    bg := m.Cfg.UnfocusedBorder
    vals := [2]u32{state.WhitePixel, bg}
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &vals[0])
    x11.xcb_clear_area(state.Conn, 0, state.ReminderWindow, 0, 0, 0, 0)
    if state.ReminderListMode {
        reminder_draw_text(state, state.ReminderWindow, "Pending reminders", 24, 30)
        for line, i in state.ReminderListLines {
            reminder_draw_text(state, state.ReminderWindow, line, 24, i16(60 + i32(i) * 22), 80)
        }
        reminder_draw_text(state, state.ReminderWindow, "Click to close", 24, i16(60 + i32(len(state.ReminderListLines)) * 22), 80)
        x11.xcb_flush(state.Conn)
        return
    }

    reminder_draw_text(state, state.ReminderWindow, "Set reminder", 24, 28)
    reminder_draw_text(state, state.ReminderWindow, "Minutes", 24, 56)
    reminder_draw_text(state, state.ReminderWindow, "Message", 144, 56)
    fields := [2]u32{state.ReminderMinutesWindow, state.ReminderMessageWindow}
    for xid, i in fields {
        if xid == 0 { continue }
        border := m.Cfg.UnfocusedBorder
        if i == state.ReminderField { border = m.Cfg.FocusedBorder }
        x11.xcb_change_window_attributes(state.Conn, xid, x11.CW_BORDER_PIXEL, &border)
        x11.xcb_clear_area(state.Conn, 0, xid, 0, 0, 0, 0)
    }
    input_vals := [2]u32{state.WhitePixel, 0x202020}
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &input_vals[0])
    reminder_draw_text(state, state.ReminderMinutesWindow, state.ReminderMinutes, 10, 24, 12)
    reminder_draw_text(state, state.ReminderMessageWindow, state.ReminderMessage, 10, 24, 58)
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &vals[0])
    if state.ReminderError != "" {
        reminder_draw_text(state, state.ReminderWindow, state.ReminderError, 24, 137, 80)
    }
    reminder_draw_text(state, state.ReminderWindow, "Tab: next  Enter: save  Esc: cancel", 24, 177, 80)
    x11.xcb_flush(state.Conn)
}

Set_Reminder_Field :: proc(state: ^State, m: ^c.Manager, field: int) {
    if state == nil || state.ReminderWindow == 0 || state.ReminderListMode { return }
    state.ReminderField = 0 if field <= 0 else 1
    Draw_Reminder_Panel(state, m)
}

Set_Reminder_Error :: proc(state: ^State, m: ^c.Manager, message: string) {
    if state == nil { return }
    reminder_clear_string(&state.ReminderError)
    if message != "" { state.ReminderError = strings.clone(message) }
    Draw_Reminder_Panel(state, m)
}

Append_Reminder_Character :: proc(state: ^State, m: ^c.Manager, ch: u8) {
    if state == nil || state.ReminderListMode { return }
    dst := &state.ReminderMinutes
    limit := 8
    if state.ReminderField == 1 { dst = &state.ReminderMessage; limit = 72 }
    if len(dst^) >= limit { return }
    next := fmt.aprintf("%s%c", dst^, ch)
    reminder_clear_string(dst)
    dst^ = next
    Set_Reminder_Error(state, m, "")
}

Backspace_Reminder_Field :: proc(state: ^State, m: ^c.Manager) {
    if state == nil || state.ReminderListMode { return }
    dst := &state.ReminderMinutes
    if state.ReminderField == 1 { dst = &state.ReminderMessage }
    if len(dst^) > 0 {
        next := strings.clone(dst^[:len(dst^) - 1])
        reminder_clear_string(dst)
        dst^ = next
    }
    Set_Reminder_Error(state, m, "")
}

Reminder_Input_At_Window :: proc(state: ^State, xid: u32) -> (field: int, ok: bool) {
    if state == nil { return 0, false }
    if xid == state.ReminderMinutesWindow { return 0, true }
    if xid == state.ReminderMessageWindow { return 1, true }
    return 0, false
}

Is_Reminder_Panel_Window :: proc(state: ^State, xid: u32) -> bool {
    return state != nil && xid != 0 &&
        (xid == state.ReminderWindow || xid == state.ReminderMinutesWindow || xid == state.ReminderMessageWindow)
}

Hide_Reminder_Panel :: proc(state: ^State) {
    if state == nil { return }
    if state.Conn != nil && state.ReminderWindow != 0 {
        x11.xcb_destroy_window(state.Conn, state.ReminderWindow)
    }
    state.ReminderWindow = 0
    state.ReminderMinutesWindow = 0
    state.ReminderMessageWindow = 0
    state.ReminderField = 0
    state.ReminderListMode = false
    reminder_clear_string(&state.ReminderMinutes)
    reminder_clear_string(&state.ReminderMessage)
    reminder_clear_string(&state.ReminderError)
    reminder_clear_list(state)
    if state.Conn != nil { x11.xcb_flush(state.Conn) }
}

Shutdown_Reminder_Panel :: proc(state: ^State) {
    if state == nil { return }
    Hide_Reminder_Panel(state)
    if state.ReminderListLines != nil { delete(state.ReminderListLines) }
    state.ReminderListLines = nil
}
