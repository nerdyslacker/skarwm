package main

// Tiled drag-and-drop hints. Each zone is drawn as four thin, opaque
// override-redirect strips, leaving the application beneath visible without
// requiring a compositor or ARGB visual.

import c "core"

drop_target_equal :: proc(a, b: c.Drop_Target) -> bool {
    return a.Kind == b.Kind && a.Out == b.Out && a.Ws == b.Ws &&
           a.Col == b.Col && a.Insert_Index == b.Insert_Index &&
           a.Row_Index == b.Row_Index
}

drop_overlay_piece :: proc(r: c.Rect, color: u32) {
    if r.W <= 0 || r.H <= 0 { return }
    xid := xcb_generate_id(g_wm.conn)
    vals := [2]u32{color, 1}
    xcb_create_window(
        g_wm.conn, 0, xid, g_wm.root,
        i16(r.X), i16(r.Y), u16(r.W), u16(r.H),
        0, WINDOW_CLASS_INPUT_OUTPUT, 0,
        CW_BACK_PIXEL | CW_OVERRIDE_REDIRECT, &vals[0],
    )
    append(&g_wm.drop_windows, xid)
    xcb_map_window(g_wm.conn, xid)
    stack := STACK_MODE_ABOVE
    xcb_configure_window(g_wm.conn, xid, CW_STACK_MODE, &stack)
}

drop_overlay_outline :: proc(r: c.Rect, color: u32, thickness: i32) {
    if r.W <= 0 || r.H <= 0 { return }
    t := min(thickness, max(i32(1), min(r.W, r.H) / 2))
    drop_overlay_piece(c.Rect{X = r.X, Y = r.Y, W = r.W, H = t}, color)
    drop_overlay_piece(c.Rect{X = r.X, Y = r.Y + r.H - t, W = r.W, H = t}, color)
    drop_overlay_piece(c.Rect{X = r.X, Y = r.Y + t, W = t, H = max(i32(0), r.H - 2 * t)}, color)
    drop_overlay_piece(c.Rect{X = r.X + r.W - t, Y = r.Y + t, W = t, H = max(i32(0), r.H - 2 * t)}, color)
}

drop_overlay_clear_windows :: proc() {
    for xid in g_wm.drop_windows { xcb_destroy_window(g_wm.conn, xid) }
    clear(&g_wm.drop_windows)
}

drop_overlay_redraw :: proc(active: c.Drop_Target) {
    drop_overlay_clear_windows()
    targets := c.Drop_Targets(g_wm.m, g_wm.mouse_client)
    defer delete(targets)
    inactive := g_wm.m.Cfg.UnfocusedBorder
    selected := g_wm.m.Cfg.FocusedBorder
    for target in targets {
        if !drop_target_equal(target, active) {
            drop_overlay_outline(target.Geom, inactive, 2)
        }
    }
    if active.Kind != .None { drop_overlay_outline(active.Geom, selected, 4) }
    xcb_flush(g_wm.conn)
}

drop_overlay_update :: proc(x, y: i32) {
    target := c.Drop_Target_At_Point(g_wm.m, x, y, g_wm.mouse_client)
    if drop_target_equal(target, g_wm.drop_target) && len(g_wm.drop_windows) > 0 { return }
    g_wm.drop_target = target
    drop_overlay_redraw(target)
}

drop_overlay_hide :: proc() {
    if g_wm.conn == nil { return }
    drop_overlay_clear_windows()
    g_wm.drop_target = {}
    xcb_flush(g_wm.conn)
}
