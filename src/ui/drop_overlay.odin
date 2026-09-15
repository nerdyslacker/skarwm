package ui

import x11 "../x11"
import c "../core"

// Tiled drag-and-drop hint. Five persistent override-redirect windows form one
// active overlay: a compositor-backed translucent fill and four opaque border
// pieces. They are reconfigured only when direction/output/geometry changes.
// Without a compositor the fill stays unmapped and the border remains useful.


drop_target_equal :: proc(a, b: c.Drop_Target) -> bool {
    return a.Kind == b.Kind && a.Zone == b.Zone && a.Out == b.Out && a.Ws == b.Ws &&
           a.Col == b.Col && a.Target == b.Target && a.Insert_Index == b.Insert_Index &&
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

drop_compositor_running :: proc(state: ^State) -> bool {
    selection := atom(state, "_NET_WM_CM_S0")
    e: ^x11.Error
    reply := x11.xcb_get_selection_owner_reply(state.Conn, x11.xcb_get_selection_owner(state.Conn, selection), &e)
    if e != nil { x11.free_libc(e) }
    if reply == nil { return false }
    defer x11.free_libc(reply)
    return reply.owner != 0
}

drop_overlay_create_window :: proc(state: ^State, color: u32) -> u32 {
    xid := x11.xcb_generate_id(state.Conn)
    vals := [2]u32{color, 1}
    x11.xcb_create_window(
        state.Conn, 0, xid, state.Root,
        0, 0, 1, 1,
        0, x11.WINDOW_CLASS_INPUT_OUTPUT, 0,
        x11.CW_BACK_PIXEL | x11.CW_OVERRIDE_REDIRECT, &vals[0],
    )
    return xid
}

drop_overlay_ensure :: proc(state: ^State, m: ^c.Manager) {
    if state.DropWindows[0] != 0 { return }
    color := m.Cfg.FocusedBorder
    for i in 0 ..< DROP_OVERLAY_COUNT {
        state.DropWindows[i] = drop_overlay_create_window(state, color)
    }
    x11.set_prop_atom(
        state.Conn,
        state.DropWindows[DROP_OVERLAY_FILL],
        atom(state, "_NET_WM_WINDOW_OPACITY"),
        atom(state, "CARDINAL"),
        DROP_OVERLAY_FILL_OPACITY,
    )
}

drop_overlay_configure_piece :: proc(state: ^State, xid: u32, r: c.Rect) {
    if xid == 0 || r.W <= 0 || r.H <= 0 { return }
    vals := [5]u32{u32(i16(r.X)), u32(i16(r.Y)), u32(r.W), u32(r.H), x11.STACK_MODE_ABOVE}
    x11.xcb_configure_window(state.Conn, xid, x11.CW_X | x11.CW_Y | x11.CW_WIDTH | x11.CW_HEIGHT | x11.CW_STACK_MODE, &vals[0])
}

// Keep the translucent fill above the pointer-following drag preview and the
// opaque outline above the fill. Reasserting the stack on unchanged targets is
// intentional: the preview window is reconfigured on every motion event.
drop_overlay_raise :: proc(state: ^State) {
    stack := x11.STACK_MODE_ABOVE
    if state.DropHasCompositor {
        x11.xcb_map_window(state.Conn, state.DropWindows[DROP_OVERLAY_FILL])
        x11.xcb_configure_window(state.Conn, state.DropWindows[DROP_OVERLAY_FILL], x11.CW_STACK_MODE, &stack)
    } else {
        x11.xcb_unmap_window(state.Conn, state.DropWindows[DROP_OVERLAY_FILL])
    }
    for i in DROP_OVERLAY_TOP ..< DROP_OVERLAY_COUNT {
        x11.xcb_map_window(state.Conn, state.DropWindows[i])
        x11.xcb_configure_window(state.Conn, state.DropWindows[i], x11.CW_STACK_MODE, &stack)
    }
}

Show_Drop :: proc(state: ^State, m: ^c.Manager, target: c.Drop_Target) {
    if target.Kind == .None || target.Geom.W <= 0 || target.Geom.H <= 0 {
        Hide_Drop(state)
        return
    }
    drop_overlay_ensure(state, m)
    color := m.Cfg.FocusedBorder
    for xid in state.DropWindows {
        x11.xcb_change_window_attributes(state.Conn, xid, x11.CW_BACK_PIXEL, &color)
    }
    state.DropHasCompositor = drop_compositor_running(state)
    r := target.Geom
    t := min(DROP_OVERLAY_BORDER, max(i32(1), min(r.W, r.H) / 2))
    drop_overlay_configure_piece(state, state.DropWindows[DROP_OVERLAY_FILL], r)
    drop_overlay_configure_piece(state, state.DropWindows[DROP_OVERLAY_TOP], c.Rect{X = r.X, Y = r.Y, W = r.W, H = t})
    drop_overlay_configure_piece(state, state.DropWindows[DROP_OVERLAY_BOTTOM], c.Rect{X = r.X, Y = r.Y + r.H - t, W = r.W, H = t})
    drop_overlay_configure_piece(state, state.DropWindows[DROP_OVERLAY_LEFT], c.Rect{X = r.X, Y = r.Y + t, W = t, H = max(i32(1), r.H - 2 * t)})
    drop_overlay_configure_piece(state, state.DropWindows[DROP_OVERLAY_RIGHT], c.Rect{X = r.X + r.W - t, Y = r.Y + t, W = t, H = max(i32(1), r.H - 2 * t)})

    drop_overlay_raise(state)
    state.DropVisible = true
    state.DropTarget = target
    x11.xcb_flush(state.Conn)
}

Update_Drop :: proc(state: ^State, m: ^c.Manager, mouse_client: ^c.Client, x, y: i32) {
    target := c.Drop_Target_At_Point(m, x, y, mouse_client, state.DropTarget)
    Update_Drop_Target(state, m, target)
}

Update_Tabbed_Drop :: proc(state: ^State, m: ^c.Manager, mouse_client: ^c.Client, x, y: i32) {
    target := c.Tabbed_Drop_Target_At_Point(m, x, y, mouse_client)
    Update_Drop_Target(state, m, target)
}

Update_Column_Drop :: proc(state: ^State, m: ^c.Manager, mouse_client: ^c.Client, x, y: i32) {
    target := c.Column_Drop_Target_At_Point(m, x, y, mouse_client)
    Update_Drop_Target(state, m, target)
}

Update_Drop_Target :: proc(state: ^State, m: ^c.Manager, target: c.Drop_Target) {
    if target.Kind == .None {
        Hide_Drop(state)
        return
    }
    if state.DropVisible && drop_target_equal(target, state.DropTarget) {
        drop_overlay_raise(state)
        x11.xcb_flush(state.Conn)
        return
    }
    Show_Drop(state, m, target)
}

Hide_Drop :: proc(state: ^State) {
    if state.Conn == nil { return }
    if state.DropVisible {
        for xid in state.DropWindows { if xid != 0 { x11.xcb_unmap_window(state.Conn, xid) } }
    }
    state.DropVisible = false
    state.DropTarget = {}
    x11.xcb_flush(state.Conn)
}

Destroy_Drop :: proc(state: ^State) {
    if state.Conn == nil { return }
    for &xid in state.DropWindows {
        if xid != 0 { x11.xcb_destroy_window(state.Conn, xid); xid = 0 }
    }
    state.DropVisible = false
    state.DropTarget = {}
}
