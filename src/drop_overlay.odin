package main

// Tiled drag-and-drop hint. Five persistent override-redirect windows form one
// active overlay: a compositor-backed translucent fill and four opaque border
// pieces. They are reconfigured only when direction/output/geometry changes.
// Without a compositor the fill stays unmapped and the border remains useful.

import c "core"

drop_target_equal :: proc(a, b: c.Drop_Target) -> bool {
    return a.Kind == b.Kind && a.Zone == b.Zone && a.Out == b.Out && a.Ws == b.Ws &&
           a.Col == b.Col && a.Insert_Index == b.Insert_Index &&
           a.Row_Index == b.Row_Index && a.Geom == b.Geom
}

DROP_OVERLAY_FILL :: 0
DROP_OVERLAY_TOP :: 1
DROP_OVERLAY_BOTTOM :: 2
DROP_OVERLAY_LEFT :: 3
DROP_OVERLAY_RIGHT :: 4
DROP_OVERLAY_COUNT :: 5
DROP_OVERLAY_BORDER :: i32(4)
DROP_OVERLAY_FILL_OPACITY :: u32(0x2e147ae1) // 18% of 0xffffffff

drop_compositor_running :: proc() -> bool {
    selection := atom("_NET_WM_CM_S0")
    e: ^Error
    reply := xcb_get_selection_owner_reply(g_wm.conn, xcb_get_selection_owner(g_wm.conn, selection), &e)
    if e != nil { free_libc(e) }
    if reply == nil { return false }
    defer free_libc(reply)
    return reply.owner != 0
}

drop_overlay_create_window :: proc(color: u32) -> u32 {
    xid := xcb_generate_id(g_wm.conn)
    vals := [2]u32{color, 1}
    xcb_create_window(
        g_wm.conn, 0, xid, g_wm.root,
        0, 0, 1, 1,
        0, WINDOW_CLASS_INPUT_OUTPUT, 0,
        CW_BACK_PIXEL | CW_OVERRIDE_REDIRECT, &vals[0],
    )
    return xid
}

drop_overlay_ensure :: proc() {
    if g_wm.drop_windows[0] != 0 { return }
    color := g_wm.m.Cfg.FocusedBorder
    for i in 0 ..< DROP_OVERLAY_COUNT {
        g_wm.drop_windows[i] = drop_overlay_create_window(color)
    }
    set_prop_atom(
        g_wm.conn,
        g_wm.drop_windows[DROP_OVERLAY_FILL],
        atom("_NET_WM_WINDOW_OPACITY"),
        atom("CARDINAL"),
        DROP_OVERLAY_FILL_OPACITY,
    )
}

drop_overlay_configure_piece :: proc(xid: u32, r: c.Rect) {
    if xid == 0 || r.W <= 0 || r.H <= 0 { return }
    vals := [5]u32{u32(i16(r.X)), u32(i16(r.Y)), u32(r.W), u32(r.H), STACK_MODE_ABOVE}
    xcb_configure_window(g_wm.conn, xid, CW_X | CW_Y | CW_WIDTH | CW_HEIGHT | CW_STACK_MODE, &vals[0])
}

drop_overlay_show :: proc(target: c.Drop_Target) {
    if target.Kind == .None || target.Geom.W <= 0 || target.Geom.H <= 0 {
        drop_overlay_hide()
        return
    }
    drop_overlay_ensure()
    color := g_wm.m.Cfg.FocusedBorder
    for xid in g_wm.drop_windows {
        xcb_change_window_attributes(g_wm.conn, xid, CW_BACK_PIXEL, &color)
    }
    g_wm.drop_overlay_has_compositor = drop_compositor_running()
    r := target.Geom
    t := min(DROP_OVERLAY_BORDER, max(i32(1), min(r.W, r.H) / 2))
    drop_overlay_configure_piece(g_wm.drop_windows[DROP_OVERLAY_FILL], r)
    drop_overlay_configure_piece(g_wm.drop_windows[DROP_OVERLAY_TOP], c.Rect{X = r.X, Y = r.Y, W = r.W, H = t})
    drop_overlay_configure_piece(g_wm.drop_windows[DROP_OVERLAY_BOTTOM], c.Rect{X = r.X, Y = r.Y + r.H - t, W = r.W, H = t})
    drop_overlay_configure_piece(g_wm.drop_windows[DROP_OVERLAY_LEFT], c.Rect{X = r.X, Y = r.Y + t, W = t, H = max(i32(1), r.H - 2 * t)})
    drop_overlay_configure_piece(g_wm.drop_windows[DROP_OVERLAY_RIGHT], c.Rect{X = r.X + r.W - t, Y = r.Y + t, W = t, H = max(i32(1), r.H - 2 * t)})

    if g_wm.drop_overlay_has_compositor {
        xcb_map_window(g_wm.conn, g_wm.drop_windows[DROP_OVERLAY_FILL])
    } else {
        xcb_unmap_window(g_wm.conn, g_wm.drop_windows[DROP_OVERLAY_FILL])
    }
    for i in DROP_OVERLAY_TOP ..< DROP_OVERLAY_COUNT {
        xcb_map_window(g_wm.conn, g_wm.drop_windows[i])
    }
    g_wm.drop_overlay_visible = true
    g_wm.drop_target = target
    xcb_flush(g_wm.conn)
}

drop_overlay_update :: proc(x, y: i32) {
    target := c.Drop_Target_At_Point(g_wm.m, x, y, g_wm.mouse_client, g_wm.drop_target)
    if target.Kind == .None {
        drop_overlay_hide()
        return
    }
    if g_wm.drop_overlay_visible && drop_target_equal(target, g_wm.drop_target) { return }
    drop_overlay_show(target)
}

drop_overlay_hide :: proc() {
    if g_wm.conn == nil { return }
    if g_wm.drop_overlay_visible {
        for xid in g_wm.drop_windows { if xid != 0 { xcb_unmap_window(g_wm.conn, xid) } }
    }
    g_wm.drop_overlay_visible = false
    g_wm.drop_target = {}
    xcb_flush(g_wm.conn)
}

drop_overlay_destroy :: proc() {
    if g_wm.conn == nil { return }
    for &xid in g_wm.drop_windows {
        if xid != 0 { xcb_destroy_window(g_wm.conn, xid); xid = 0 }
    }
    g_wm.drop_overlay_visible = false
    g_wm.drop_target = {}
}
