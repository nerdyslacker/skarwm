package main

// A small WM-owned overlay listing the bindings from the active configuration.
// It is override-redirect so it never enters the managed client model.

import "core:fmt"
import c "core"

HELP_MARGIN   :: i32(20)
HELP_TOP      :: i32(42)
HELP_BOTTOM   :: i32(28)
HELP_LINE_H   :: i32(18)
HELP_COL_MIN  :: i32(260)
HELP_COL_WANT :: i32(330)

binding_description :: proc(b: ^Binding) -> string {
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
    case .Toggle_Floating:     return fmt.aprintf("toggle floating")
    case .Toggle_Fullscreen:   return fmt.aprintf("toggle fullscreen")
    case .Layout_Tabbed:       return fmt.aprintf("use tabbed layout")
    case .Layout_Stacked:      return fmt.aprintf("use stacked layout")
    case .Layout_Toggle:       return fmt.aprintf("toggle tabbed layout")
    case .Show_Bindings:       return fmt.aprintf("show or hide keybindings")
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

binding_lines :: proc() -> [dynamic]string {
    lines := make([dynamic]string, 0, len(g_wm.bindings) + 4)
    for &b in g_wm.bindings {
        description := binding_description(&b)
        append(&lines, fmt.aprintf("%s  -  %s", b.combo, description))
        delete(description)
    }

    // Shift variants of launcher bindings are real passive grabs too, unless
    // an explicit binding already owns that combination.
    for &b in g_wm.bindings {
        if b.action != .Spawn || b.effective_mods & MOD_MASK_SHIFT != 0 { continue }
        derived := b.effective_mods | MOD_MASK_SHIFT
        claimed := false
        for &other in g_wm.bindings {
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

help_geometry :: proc(line_count: int) -> (rect: c.Rect, columns, rows, capacity: int) {
    output := c.Active_Output(g_wm.m)
    area := c.Rect{X = 0, Y = 0, W = g_wm.scr_w, H = g_wm.scr_h}
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

help_text :: proc(text: string, x, y: i16) {
    n := min(len(text), 255)
    if n > 0 {
        xcb_image_text_8(g_wm.conn, u8(n), g_wm.help_window, g_wm.tab_gc,
                        x, y, cstring(raw_data(text)))
    }
}

help_draw :: proc() {
    if g_wm.help_window == 0 { return }
    lines := binding_lines()
    defer free_binding_lines(&lines)
    rect, columns, rows, capacity := help_geometry(len(lines))
    bg := g_wm.m.Cfg.UnfocusedBorder
    vals := [2]u32{g_wm.white_pixel, bg}
    xcb_change_gc(g_wm.conn, g_wm.tab_gc, GC_FOREGROUND | GC_BACKGROUND, &vals[0])

    help_text("skarwm keybindings", 14, 24)
    col_width := rect.W / i32(columns)
    shown := min(len(lines), capacity)
    for i in 0 ..< shown {
        col := i / rows
        row := i % rows
        x := i16(14 + i32(col) * col_width)
        y := i16(HELP_TOP + i32(row) * HELP_LINE_H)
        max_chars := max(1, int((col_width - 20) / 6))
        line := lines[i]
        help_text(line[:min(len(line), max_chars)], x, y)
    }

    footer := "Click the overlay or press the help shortcut again to close"
    if shown < len(lines) {
        footer = fmt.tprintf("Showing %d of %d bindings; enlarge the display to see all", shown, len(lines))
    }
    help_text(footer, 14, i16(rect.H - 10))
    xcb_flush(g_wm.conn)
}

help_show :: proc() {
    if g_wm.help_window != 0 { return }
    tabs_init()
    lines := binding_lines()
    rect, _, _, _ := help_geometry(len(lines))
    free_binding_lines(&lines)

    bg := g_wm.m.Cfg.UnfocusedBorder
    border := g_wm.m.Cfg.FocusedBorder
    xid := xcb_generate_id(g_wm.conn)
    vals := [4]u32{bg, border, 1, EVENT_MASK_EXPOSURE | EVENT_MASK_BUTTON_PRESS}
    cookie := xcb_create_window_checked(
        g_wm.conn, 0, xid, g_wm.root,
        i16(rect.X), i16(rect.Y), u16(rect.W), u16(rect.H),
        2, WINDOW_CLASS_INPUT_OUTPUT, 0,
        CW_BACK_PIXEL | CW_BORDER_PIXEL | CW_OVERRIDE_REDIRECT | CW_EVENT_MASK, &vals[0],
    )
    if err := xcb_request_check(g_wm.conn, cookie); err != nil {
        xe := (^X_Error)(err)
        log_error("cannot create keybinding overlay; X error", xe.error_code,
                  "request", xe.major_code, "resource", xe.resource_id)
        free_libc(err)
        return
    }
    g_wm.help_window = xid
    set_prop_text(g_wm.conn, xid, atom("_NET_WM_NAME"), atom("UTF8_STRING"), "skarwm keybindings")
    set_prop_text(g_wm.conn, xid, atom("WM_NAME"), atom("STRING"), "skarwm keybindings")
    xcb_map_window(g_wm.conn, xid)
    stack := STACK_MODE_ABOVE
    xcb_configure_window(g_wm.conn, xid, CW_STACK_MODE, &stack)
    help_draw()
}

help_hide :: proc() {
    if g_wm.help_window == 0 || g_wm.conn == nil { return }
    xcb_destroy_window(g_wm.conn, g_wm.help_window)
    g_wm.help_window = 0
    xcb_flush(g_wm.conn)
}

help_toggle :: proc() {
    if g_wm.help_window == 0 { help_show() } else { help_hide() }
}
