package main

import x11 "../../src/x11"

init_randr :: proc(state: ^State) {
    name := "RANDR"
    e: ^x11.Error
    extension := x11.xcb_query_extension_reply(
        state.Conn,
        x11.xcb_query_extension(state.Conn, u16(len(name)), cstring(raw_data(name))),
        &e,
    )
    if e != nil { x11.free_libc(e) }
    if extension == nil || extension.present == 0 {
        if extension != nil { x11.free_libc(extension) }
        return
    }
    state.RandrEventBase = extension.first_event
    x11.free_libc(extension)

    e = nil
    version := x11.xcb_randr_query_version_reply(
        state.Conn, x11.xcb_randr_query_version(state.Conn, 1, 5), &e,
    )
    if e != nil { x11.free_libc(e) }
    if version == nil || version.major_version < 1 ||
       (version.major_version == 1 && version.minor_version < 5) {
        if version != nil { x11.free_libc(version) }
        return
    }
    x11.free_libc(version)

    mask := x11.RANDR_NOTIFY_MASK_SCREEN_CHANGE | x11.RANDR_NOTIFY_MASK_CRTC_CHANGE |
        x11.RANDR_NOTIFY_MASK_OUTPUT_CHANGE | x11.RANDR_NOTIFY_MASK_RESOURCE_CHANGE
    x11.xcb_randr_select_input(state.Conn, state.Root, mask)
    state.RandrAvailable = true
}

query_monitors :: proc(state: ^State) -> [dynamic]Monitor {
    monitors := make([dynamic]Monitor, 0, 4)
    if state.RandrAvailable {
        e: ^x11.Error
        reply := x11.xcb_randr_get_monitors_reply(
            state.Conn, x11.xcb_randr_get_monitors(state.Conn, state.Root, 1), &e,
        )
        if e != nil { x11.free_libc(e) }
        if reply != nil {
            iter := x11.xcb_randr_get_monitors_monitors_iterator(reply)
            for iter.rem > 0 && iter.data != nil {
                info := iter.data
                if info.width > 0 && info.height > 0 {
                    append(&monitors, Monitor{
                        X = i32(info.x), Y = i32(info.y),
                        W = i32(info.width), H = i32(info.height),
                        Name = monitor_atom_name(state, info.name),
                    })
                }
                x11.xcb_randr_monitor_info_next(&iter)
            }
            x11.free_libc(reply)
        }
    }
    if len(monitors) == 0 {
        append(&monitors, Monitor{W = state.RootW, H = state.RootH, Name = x11.strings_clone_here("screen")})
    }
    return monitors
}

monitor_atom_name :: proc(state: ^State, id: u32) -> string {
    e: ^x11.Error
    reply := x11.xcb_get_atom_name_reply(state.Conn, x11.xcb_get_atom_name(state.Conn, id), &e)
    if e != nil { x11.free_libc(e) }
    if reply == nil || reply.name_len == 0 {
        if reply != nil { x11.free_libc(reply) }
        return x11.strings_clone_here("screen")
    }
    n := int(reply.name_len)
    source := ([^]u8)(rawptr(uintptr(rawptr(reply)) + uintptr(size_of(x11.Get_Atom_Name_Reply))))[:n]
    name := make([]byte, n)
    copy(name, source)
    x11.free_libc(reply)
    return string(name)
}

destroy_windows :: proc(state: ^State) {
    if state.Conn != nil {
        for window in state.Windows {
            if window.Xid != 0 { x11.xcb_destroy_window(state.Conn, window.Xid) }
            if window.Output != "" { delete(window.Output) }
            delete(window.Hits)
        }
        x11.xcb_flush(state.Conn)
    }
    delete(state.Windows)
    state.Windows = make([dynamic]Bar_Window, 0, 4)
}

rebuild_windows :: proc(state: ^State) {
    tray_detach_for_rebuild(state)
    destroy_windows(state)
    refresh_root_geometry(state)
    monitors := query_monitors(state)
    defer delete(monitors)
    for monitor in monitors {
        create_bar_window(state, monitor)
        if monitor.Name != "" { delete(monitor.Name) }
    }
    tray_update_owner(state)
    draw_all_bars(state)
    x11.xcb_flush(state.Conn)
}

refresh_root_geometry :: proc(state: ^State) {
    e: ^x11.Error
    reply := x11.xcb_get_geometry_reply(
        state.Conn, x11.xcb_get_geometry(state.Conn, state.Root), &e,
    )
    if e != nil { x11.free_libc(e) }
    if reply == nil { return }
    state.RootW = i32(reply.width)
    state.RootH = i32(reply.height)
    x11.free_libc(reply)
}

cardinal :: proc(value: i32) -> u32 {
    return u32(max(i32(0), value))
}

create_bar_window :: proc(state: ^State, monitor: Monitor) {
    height := min(state.Config.Height, monitor.H)
    if height <= 0 || monitor.W <= 0 { return }
    y := monitor.Y
    if state.Config.Position == .Bottom { y = monitor.Y + monitor.H - height }

    xid := x11.xcb_generate_id(state.Conn)
    event_mask := x11.EVENT_MASK_EXPOSURE | x11.EVENT_MASK_BUTTON_PRESS |
        x11.EVENT_MASK_STRUCTURE_NOTIFY | x11.EVENT_MASK_POINTER_MOTION |
        x11.EVENT_MASK_LEAVE_WINDOW | x11.EVENT_MASK_SUBSTRUCTURE_NOTIFY
    values := [2]u32{state.Config.Background, event_mask}
    cookie := x11.xcb_create_window_checked(
        state.Conn, 0, xid, state.Root,
        i16(monitor.X), i16(y), u16(monitor.W), u16(height),
        0, x11.WINDOW_CLASS_INPUT_OUTPUT, 0,
        x11.CW_BACK_PIXEL | x11.CW_EVENT_MASK, &values[0],
    )
    if err := x11.xcb_request_check(state.Conn, cookie); err != nil {
        x11.free_libc(err)
        return
    }

    x11.set_prop_atom(
        state.Conn, xid, atom(state, "_NET_WM_WINDOW_TYPE"), atom(state, "ATOM"),
        atom(state, "_NET_WM_WINDOW_TYPE_DOCK"),
    )
    x11.set_prop_text(state.Conn, xid, atom(state, "_NET_WM_NAME"), atom(state, "UTF8_STRING"), "skarwm-bar")
    x11.set_prop_text(state.Conn, xid, atom(state, "WM_NAME"), atom(state, "STRING"), "skarwm-bar")

    strut: [12]u32
    start_x := cardinal(monitor.X)
    end_x := cardinal(monitor.X + monitor.W - 1)
    if state.Config.Position == .Top {
        strut[2] = cardinal(y + height)
        strut[8], strut[9] = start_x, end_x
    } else {
        strut[3] = cardinal(state.RootH - y)
        strut[10], strut[11] = start_x, end_x
    }
    x11.set_prop32(state.Conn, xid, atom(state, "_NET_WM_STRUT"), atom(state, "CARDINAL"), strut[:4])
    x11.set_prop32(state.Conn, xid, atom(state, "_NET_WM_STRUT_PARTIAL"), atom(state, "CARDINAL"), strut[:])

    x11.xcb_map_window(state.Conn, xid)
    hits := make([dynamic]Hitbox, 0, 16)
    append(&state.Windows, Bar_Window{
        Xid = xid,
        Output = x11.strings_clone_here(monitor.Name),
        // Geom describes the bar window for rendering/hit-testing, not the
        // containing monitor. Using monitor.H here placed the text baseline
        // far below the short bar window and clipped every glyph.
        Geom = Monitor{X = monitor.X, Y = y, W = monitor.W, H = height},
        Hits = hits,
    })
    draw_bar(state, &state.Windows[len(state.Windows) - 1])
}
