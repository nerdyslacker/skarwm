package ui

import logger "../log"
import input "../input"
import c "../core"
import x11 "../x11"

// A small WM-owned overlay listing the bindings from the active configuration.
// It is override-redirect so it never enters the managed client model.

import "core:fmt"

HELP_MARGIN   :: i32(20)
HELP_TOP      :: i32(42)
HELP_BOTTOM   :: i32(28)
HELP_LINE_H   :: i32(18)
HELP_COL_MIN  :: i32(260)
HELP_COL_WANT :: i32(330)

binding_description :: proc(b: ^input.Binding) -> string {
    switch b.action {
    case .Spawn:               return fmt.aprintf("launch %s", b.cmd)
    case .Focus_Left:          return fmt.aprintf("focus left")
    case .Focus_Right:         return fmt.aprintf("focus right")
    case .Focus_Up:            return fmt.aprintf("focus up")
    case .Focus_Down:          return fmt.aprintf("focus down")
    case .Move_Left:           return fmt.aprintf("move window left")
    case .Move_Right:          return fmt.aprintf("move window right")
    case .Move_Up:             return fmt.aprintf("move window up")
    case .Move_Down:           return fmt.aprintf("move window down")
    case .Resize_Left:         return fmt.aprintf("shrink tile width")
    case .Resize_Right:        return fmt.aprintf("grow tile width")
    case .Resize_Up:           return fmt.aprintf("shrink tile height")
    case .Resize_Down:         return fmt.aprintf("grow tile height")
    case .Toggle_Floating:     return fmt.aprintf("toggle floating")
    case .Toggle_Fullscreen:   return fmt.aprintf("toggle fullscreen")
    case .Layout_Floating:     return fmt.aprintf("use floating layout")
    case .Layout_Tabbed:       return fmt.aprintf("use tabbed layout")
    case .Layout_Stacked:      return fmt.aprintf("use stacked layout")
    case .Layout_Toggle:       return fmt.aprintf("toggle tabbed layout")
    case .Overview_Next:       return fmt.aprintf("window overview (next)")
    case .Overview_Prev:       return fmt.aprintf("window overview (previous)")
    case .Scratchpad_Toggle:   return fmt.aprintf("toggle scratchpad %d", b.arg)
    case .Scratchpad_Toggle_Float: return fmt.aprintf("toggle floating scratchpad %d", b.arg)
    case .Scratchpad_Remove:   return fmt.aprintf("remove scratchpad %d", b.arg)
    case .Show_Bindings:       return fmt.aprintf("show or hide keybindings")
    case .Show_Date_Time:      return fmt.aprintf("show date and time notice")
    case .Show_Battery:        return fmt.aprintf("show battery notice")
    case .Close:               return fmt.aprintf("close focused window")
    case .Reload:              return fmt.aprintf("reload configuration")
    case .Quit:                return fmt.aprintf("quit skarwm")
    case .WS_Next:             return fmt.aprintf("next workspace")
    case .WS_Prev:             return fmt.aprintf("previous workspace")
    case .WS_Goto:             return fmt.aprintf("show workspace %d", b.arg)
    case .Move_To_WS:          return fmt.aprintf("move window to workspace %d", b.arg)
    case .Move_To_WS_Next:     return fmt.aprintf("move window to next workspace")
    case .Move_To_WS_Prev:     return fmt.aprintf("move window to previous workspace")
    case .Focus_Output_Next:   return fmt.aprintf("focus next monitor")
    case .Focus_Output_Prev:   return fmt.aprintf("focus previous monitor")
    case .Move_To_Output_Next: return fmt.aprintf("move window to next monitor")
    case .Move_To_Output_Prev: return fmt.aprintf("move window to previous monitor")
    case .None:                return fmt.aprintf("no action")
    }
    return fmt.aprintf("unknown action")
}

binding_lines :: proc(bindings: []input.Binding) -> [dynamic]string {
    lines := make([dynamic]string, 0, len(bindings) + 4)
    for &b in bindings {
        description := binding_description(&b)
        append(&lines, fmt.aprintf("%s  -  %s", b.combo, description))
        delete(description)
    }

    // Shift variants of launcher bindings are real passive grabs too, unless
    // an explicit binding already owns that combination.
    for &b in bindings {
        if b.action != .Spawn || b.effective_mods & x11.MOD_MASK_SHIFT != 0 { continue }
        derived := b.effective_mods | x11.MOD_MASK_SHIFT
        claimed := false
        for &other in bindings {
            if other.keycode == b.keycode && other.effective_mods == derived {
                claimed = true
                break
            }
        }
        if !claimed {
            append(&lines, fmt.aprintf("Shift + %s  -  launch as tab: %s", b.combo, b.cmd))
        }
    }
    return lines
}

free_binding_lines :: proc(lines: ^[dynamic]string) {
    for line in lines^ { delete(line) }
    delete(lines^)
    lines^ = nil
}

help_geometry :: proc(m: ^c.Manager, screen_w, screen_h: i32, line_count: int) -> (rect: c.Rect, columns, rows, capacity: int) {
    output := c.Active_Output(m)
    area := c.Rect{X = 0, Y = 0, W = screen_w, H = screen_h}
    if output != nil { area = output.Geom }

    avail_w := max(i32(240), area.W - HELP_MARGIN * 2)
    avail_h := max(i32(160), area.H - HELP_MARGIN * 2)
    rows_cap := max(1, int((avail_h - HELP_TOP - HELP_BOTTOM) / HELP_LINE_H))
    needed_cols := max(1, (line_count + rows_cap - 1) / rows_cap)
    max_cols := max(1, int(avail_w / HELP_COL_MIN))
    columns = min(needed_cols, max_cols)
    rows = min(max(1, (line_count + columns - 1) / columns), rows_cap)
    capacity = rows * columns

    width := min(avail_w, max(i32(360), i32(columns) * HELP_COL_WANT))
    height := min(avail_h, HELP_TOP + i32(rows) * HELP_LINE_H + HELP_BOTTOM)
    rect = c.Rect{
        X = area.X + (area.W - width) / 2,
        Y = area.Y + (area.H - height) / 2,
        W = width,
        H = height,
    }
    return
}

help_text :: proc(state: ^State, text: string, x, y: i16) {
    n := min(len(text), 255)
    if n > 0 {
        x11.xcb_image_text_8(state.Conn, u8(n), state.HelpWindow, state.TabGC,
                        x, y, cstring(raw_data(text)))
    }
}

Draw_Help :: proc(state: ^State, m: ^c.Manager, bindings: []input.Binding, screen_w, screen_h: i32) {
    if state.HelpWindow == 0 { return }
    lines := binding_lines(bindings)
    defer free_binding_lines(&lines)
    rect, columns, rows, capacity := help_geometry(m, screen_w, screen_h, len(lines))
    bg := m.Cfg.UnfocusedBorder
    vals := [2]u32{state.WhitePixel, bg}
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &vals[0])

    help_text(state, "skarwm keybindings", 14, 24)
    col_width := rect.W / i32(columns)
    shown := min(len(lines), capacity)
    for i in 0 ..< shown {
        col := i / rows
        row := i % rows
        x := i16(14 + i32(col) * col_width)
        y := i16(HELP_TOP + i32(row) * HELP_LINE_H)
        max_chars := max(1, int((col_width - 20) / 6))
        line := lines[i]
        help_text(state, line[:min(len(line), max_chars)], x, y)
    }

    footer := "Click the overlay or press the help shortcut again to close"
    if shown < len(lines) {
        footer = fmt.tprintf("Showing %d of %d bindings; enlarge the display to see all", shown, len(lines))
    }
    help_text(state, footer, 14, i16(rect.H - 10))
    x11.xcb_flush(state.Conn)
}

Show_Help :: proc(state: ^State, m: ^c.Manager, bindings: []input.Binding, screen_w, screen_h: i32) {
    if state.HelpWindow != 0 { return }
    Init_Tabs(state)
    lines := binding_lines(bindings)
    rect, _, _, _ := help_geometry(m, screen_w, screen_h, len(lines))
    free_binding_lines(&lines)

    bg := m.Cfg.UnfocusedBorder
    border := m.Cfg.FocusedBorder
    xid := x11.xcb_generate_id(state.Conn)
    vals := [4]u32{bg, border, 1, x11.EVENT_MASK_EXPOSURE | x11.EVENT_MASK_BUTTON_PRESS}
    cookie := x11.xcb_create_window_checked(
        state.Conn, 0, xid, state.Root,
        i16(rect.X), i16(rect.Y), u16(rect.W), u16(rect.H),
        2, x11.WINDOW_CLASS_INPUT_OUTPUT, 0,
        x11.CW_BACK_PIXEL | x11.CW_BORDER_PIXEL | x11.CW_OVERRIDE_REDIRECT | x11.CW_EVENT_MASK, &vals[0],
    )
    if err := x11.xcb_request_check(state.Conn, cookie); err != nil {
        xe := (^x11.X_Error)(err)
        logger.Error("cannot create keybinding overlay; X error", xe.error_code,
                  "request", xe.major_code, "resource", xe.resource_id)
        x11.free_libc(err)
        return
    }
    state.HelpWindow = xid
    x11.set_prop_text(state.Conn, xid, atom(state, "_NET_WM_NAME"), atom(state, "UTF8_STRING"), "skarwm keybindings")
    x11.set_prop_text(state.Conn, xid, atom(state, "WM_NAME"), atom(state, "STRING"), "skarwm keybindings")
    x11.xcb_map_window(state.Conn, xid)
    stack := x11.STACK_MODE_ABOVE
    x11.xcb_configure_window(state.Conn, xid, x11.CW_STACK_MODE, &stack)
    Draw_Help(state, m, bindings, screen_w, screen_h)
}

Hide_Help :: proc(state: ^State) {
    if state.HelpWindow == 0 || state.Conn == nil { return }
    x11.xcb_destroy_window(state.Conn, state.HelpWindow)
    state.HelpWindow = 0
    x11.xcb_flush(state.Conn)
}

Toggle_Help :: proc(state: ^State, m: ^c.Manager, bindings: []input.Binding, screen_w, screen_h: i32) {
    if state.HelpWindow == 0 {
        Show_Help(state, m, bindings, screen_w, screen_h)
    } else {
        Hide_Help(state)
    }
}
