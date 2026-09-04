package main

// Minimal WM-owned tab decorations. Each tab is an override-redirect root
// child, so applications never enter the managed client model. Rebuilding the
// small strip on reflow keeps geometry and titles synchronized without a
// second layout state machine.

import c "core"

TAB_TEXT_PAD :: i32(7)

tabs_init :: proc() {
    if g_wm.tab_gc != 0 { return }
    g_wm.tab_font = xcb_generate_id(g_wm.conn)
    font_name := "fixed"
    xcb_open_font(g_wm.conn, g_wm.tab_font, u16(len(font_name)), cstring(raw_data(font_name)))
    g_wm.tab_gc = xcb_generate_id(g_wm.conn)
    vals := [3]u32{g_wm.white_pixel, 0, g_wm.tab_font}
    xcb_create_gc(g_wm.conn, g_wm.tab_gc, g_wm.root, GC_FOREGROUND | GC_BACKGROUND | GC_FONT, &vals[0])
}

destroy_tab_windows :: proc() {
    for tab in g_wm.tabs { xcb_destroy_window(g_wm.conn, tab.Xid) }
    clear(&g_wm.tabs)
}

tabs_shutdown :: proc() {
    if g_wm.conn == nil { return }
    destroy_tab_windows()
    if g_wm.tab_gc != 0 { xcb_free_gc(g_wm.conn, g_wm.tab_gc) }
    if g_wm.tab_font != 0 { xcb_close_font(g_wm.conn, g_wm.tab_font) }
    if g_wm.tabs != nil { delete(g_wm.tabs) }
    g_wm.tabs = nil
    g_wm.tab_gc, g_wm.tab_font = 0, 0
}

tab_label :: proc(cl: ^c.Client) -> string {
    if cl.Title != "" { return cl.Title }
    if cl.Class != "" { return cl.Class }
    return "untitled"
}

draw_tab :: proc(xid: u32) {
    if g_wm.tab_gc == 0 { return }
    for tab in g_wm.tabs {
        if tab.Xid != xid { continue }
        label := tab_label(tab.Client)
        max_chars := max(i32(0), (tab.Width - 2 * TAB_TEXT_PAD) / 6)
        n := min(len(label), min(255, int(max_chars)))
        vals := [2]u32{g_wm.white_pixel, tab.Bg}
        xcb_change_gc(g_wm.conn, g_wm.tab_gc, GC_FOREGROUND | GC_BACKGROUND, &vals[0])
        if n > 0 {
            xcb_image_text_8(g_wm.conn, u8(n), xid, g_wm.tab_gc, i16(TAB_TEXT_PAD), 16, cstring(raw_data(label)))
        }
        xcb_flush(g_wm.conn)
        return
    }
}

render_tabs :: proc() {
    destroy_tab_windows()
    tabs_init()
    cfg := g_wm.m.Cfg
    for o in g_wm.m.Outputs {
        ws := o.Current
        if ws == nil { continue }
        for col, ci in ws.Cols {
            if col.Layout != .Tabbed || len(col.Wins) == 0 { continue }
            bar, ok := c.Tab_Bar_Rect(g_wm.m, o, ws, ci)
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
                xid := xcb_generate_id(g_wm.conn)
                vals := [4]u32{bg, cfg.UnfocusedBorder, 1, EVENT_MASK_EXPOSURE | EVENT_MASK_BUTTON_PRESS}
                xcb_create_window(
                    g_wm.conn, 0, xid, g_wm.root,
                    i16(x), i16(bar.Y), u16(max(i32(1), width - 2)), u16(max(i32(1), bar.H - 2)),
                    1, WINDOW_CLASS_INPUT_OUTPUT, 0,
                    CW_BACK_PIXEL | CW_BORDER_PIXEL | CW_OVERRIDE_REDIRECT | CW_EVENT_MASK, &vals[0],
                )
                append(&g_wm.tabs, Tab_Decoration{Xid = xid, Client = cl, Bg = bg, Width = width})
                xcb_map_window(g_wm.conn, xid)
                draw_tab(xid)
                x += width
            }
        }
    }
}

tab_client :: proc(xid: u32) -> ^c.Client {
    for tab in g_wm.tabs { if tab.Xid == xid { return tab.Client } }
    return nil
}
