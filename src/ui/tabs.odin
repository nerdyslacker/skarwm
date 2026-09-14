package ui

import x11 "../x11"
import c "../core"

// Minimal WM-owned tab decorations. Each tab is an override-redirect root
// child, so applications never enter the managed client model. Rebuilding the
// small strip on reflow keeps geometry and titles synchronized without a
// second layout state machine.


TAB_TEXT_PAD :: i32(7)

Init_Tabs :: proc(state: ^State) {
    if state.TabGC != 0 { return }
    state.TabFont = x11.xcb_generate_id(state.Conn)
    font_name := "fixed"
    x11.xcb_open_font(state.Conn, state.TabFont, u16(len(font_name)), cstring(raw_data(font_name)))
    state.TabGC = x11.xcb_generate_id(state.Conn)
    vals := [3]u32{state.WhitePixel, 0, state.TabFont}
    x11.xcb_create_gc(state.Conn, state.TabGC, state.Root, x11.GC_FOREGROUND | x11.GC_BACKGROUND | x11.GC_FONT, &vals[0])
}

Destroy_Tab_Windows :: proc(state: ^State) {
    for tab in state.Tabs { x11.xcb_destroy_window(state.Conn, tab.Xid) }
    clear(&state.Tabs)
}

Shutdown_Tabs :: proc(state: ^State) {
    if state.Conn == nil { return }
    Destroy_Tab_Windows(state)
    if state.TabGC != 0 { x11.xcb_free_gc(state.Conn, state.TabGC) }
    if state.TabFont != 0 { x11.xcb_close_font(state.Conn, state.TabFont) }
    if state.Tabs != nil { delete(state.Tabs) }
    state.Tabs = nil
    state.TabGC, state.TabFont = 0, 0
}

tab_label :: proc(cl: ^c.Client) -> string {
    if cl.Title != "" { return cl.Title }
    if cl.Class != "" { return cl.Class }
    return "untitled"
}

Draw_Tab :: proc(state: ^State, xid: u32) {
    if state.TabGC == 0 { return }
    for tab in state.Tabs {
        if tab.Xid != xid { continue }
        label := tab_label(tab.Client)
        max_chars := max(i32(0), (tab.Width - 2 * TAB_TEXT_PAD) / 6)
        n := min(len(label), min(255, int(max_chars)))
        vals := [2]u32{state.WhitePixel, tab.Bg}
        x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &vals[0])
        if n > 0 {
            x11.xcb_image_text_8(state.Conn, u8(n), xid, state.TabGC, i16(TAB_TEXT_PAD), 16, cstring(raw_data(label)))
        }
        x11.xcb_flush(state.Conn)
        return
    }
}

Render_Tabs :: proc(state: ^State, m: ^c.Manager) {
    Destroy_Tab_Windows(state)
    Init_Tabs(state)
    cfg := m.Cfg
    for o in m.Outputs {
        ws := o.Current
        if ws == nil { continue }
        for col, ci in ws.Cols {
            if col.Layout != .Tabbed || len(col.Wins) == 0 { continue }
            bar, ok := c.Tab_Bar_Rect(m, o, ws, ci)
            if !ok { continue }
            count := len(col.Wins)
            base_w := bar.W / i32(count)
            rem := bar.W % i32(count)
            x := bar.X
            for cl, i in col.Wins {
                width := base_w
                if i32(i) < rem { width += 1 }
                bg := cfg.UnfocusedBorder
                if col.Focus == cl { bg = cfg.FocusedBorder }
                xid := x11.xcb_generate_id(state.Conn)
                vals := [4]u32{bg, cfg.UnfocusedBorder, 1, x11.EVENT_MASK_EXPOSURE | x11.EVENT_MASK_BUTTON_PRESS}
                x11.xcb_create_window(
                    state.Conn, 0, xid, state.Root,
                    i16(x), i16(bar.Y), u16(max(i32(1), width - 2)), u16(max(i32(1), bar.H - 2)),
                    1, x11.WINDOW_CLASS_INPUT_OUTPUT, 0,
                    x11.CW_BACK_PIXEL | x11.CW_BORDER_PIXEL | x11.CW_OVERRIDE_REDIRECT | x11.CW_EVENT_MASK, &vals[0],
                )
                append(&state.Tabs, Tab_Decoration{Xid = xid, Client = cl, Bg = bg, Width = width})
                x11.xcb_map_window(state.Conn, xid)
                Draw_Tab(state, xid)
                x += width
            }
        }
    }
}

Tab_Client :: proc(state: ^State, xid: u32) -> ^c.Client {
    for tab in state.Tabs { if tab.Xid == xid { return tab.Client } }
    return nil
}
