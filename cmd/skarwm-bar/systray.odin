package main

import x11 "../../src/x11"

import "core:fmt"

Tray_State :: struct {
    Enabled: bool,
    Owner, HostBar: u32,
    Selection: u32,
    Icons: [dynamic]u32,
}

TRAY_REQUEST_DOCK :: u32(0)
XEMBED_EMBEDDED_NOTIFY :: u32(0)
TRAY_ICON_GAP :: i32(2)

append_systray_block :: proc(state: ^State, alignment: Block_Alignment) {
    if state.Tray.Enabled { return }
    state.Tray.Enabled = true
    if state.Tray.Icons == nil { state.Tray.Icons = make([dynamic]u32, 0, 8) }
    append(&state.Blocks, Block{
        Name = "systray",
        Kind = .Systray,
        Alignment = alignment,
        Ops = Block_Ops{
            Measure = systray_measure,
            Draw = systray_draw,
            Destroy = systray_destroy,
        },
    })
}

tray_selection_owner :: proc(state: ^State) -> u32 {
    if state.Tray.Selection == 0 {
        name := fmt.aprintf("_NET_SYSTEM_TRAY_S%d", state.ScreenNumber)
        state.Tray.Selection = atom(state, name)
        delete(name)
    }
    e: ^x11.Error
    reply := x11.xcb_get_selection_owner_reply(
        state.Conn, x11.xcb_get_selection_owner(state.Conn, state.Tray.Selection), &e,
    )
    if e != nil { x11.free_libc(e) }
    if reply == nil { return 0 }
    owner := reply.owner
    x11.free_libc(reply)
    return owner
}

tray_send_manager :: proc(state: ^State) {
    event := x11.Client_Message_Event{
        response_type = u8(x11.EVENT_CLIENT_MESSAGE),
        format = 32,
        window = state.Root,
        type_ = atom(state, "MANAGER"),
    }
    event.data.data32[0] = 0
    event.data.data32[1] = state.Tray.Selection
    event.data.data32[2] = state.Tray.Owner
    x11.xcb_send_event(
        state.Conn, 0, state.Root, x11.EVENT_MASK_STRUCTURE_NOTIFY, rawptr(&event),
    )
}

tray_send_xembed :: proc(state: ^State, icon: u32) {
    event := x11.Client_Message_Event{
        response_type = u8(x11.EVENT_CLIENT_MESSAGE),
        format = 32,
        window = icon,
        type_ = atom(state, "_XEMBED"),
    }
    event.data.data32[0] = 0
    event.data.data32[1] = XEMBED_EMBEDDED_NOTIFY
    event.data.data32[2] = state.Tray.Owner
    event.data.data32[3] = 0
    event.data.data32[4] = 0
    x11.xcb_send_event(state.Conn, 0, icon, 0, rawptr(&event))
}

tray_reparent_icons :: proc(state: ^State) {
    if state.Tray.Owner == 0 { return }
    for icon in state.Tray.Icons {
        x11.xcb_change_save_set(state.Conn, 0, icon)
        x11.xcb_reparent_window(state.Conn, icon, state.Tray.Owner, 0, 0)
        x11.xcb_map_window(state.Conn, icon)
        tray_send_xembed(state, icon)
    }
}

tray_update_owner :: proc(state: ^State) {
    if !state.Tray.Enabled || len(state.Windows) == 0 { return }
    host := state.Windows[0].Xid
    if state.Tray.Owner == host && tray_selection_owner(state) == host { return }
    existing := tray_selection_owner(state)
    if existing != 0 && existing != state.Tray.Owner { return }

    state.Tray.HostBar = host
    state.Tray.Owner = host
    x11.xcb_set_selection_owner(state.Conn, host, state.Tray.Selection, 0)
    x11.xcb_flush(state.Conn)
    if tray_selection_owner(state) != host {
        state.Tray.Owner = 0
        state.Tray.HostBar = 0
        return
    }
    orientation := []u32{0} // _NET_SYSTEM_TRAY_ORIENTATION_HORZ
    x11.set_prop32(
        state.Conn, host, atom(state, "_NET_SYSTEM_TRAY_ORIENTATION"),
        atom(state, "CARDINAL"), orientation,
    )
    tray_send_manager(state)
    tray_reparent_icons(state)
}

tray_detach_for_rebuild :: proc(state: ^State) {
    if state.Tray.Owner == 0 { return }
    for icon in state.Tray.Icons {
        x11.xcb_reparent_window(state.Conn, icon, state.Root, 0, 0)
    }
    state.Tray.Owner = 0
    state.Tray.HostBar = 0
}

tray_icon_size :: proc(state: ^State) -> i32 {
    return max(i32(1), state.Config.Height - 4)
}

systray_measure :: proc(block: ^Block, state: ^State, window: ^Bar_Window) -> i32 {
    _ = block
    if state.Tray.Owner == 0 || window.Xid != state.Tray.HostBar || len(state.Tray.Icons) == 0 {
        return 0
    }
    size := tray_icon_size(state)
    return i32(len(state.Tray.Icons)) * size + i32(len(state.Tray.Icons) - 1) * TRAY_ICON_GAP
}

tray_arrange :: proc(state: ^State, window: ^Bar_Window, start_x: i32) {
    if state.Tray.Owner == 0 || window.Xid != state.Tray.HostBar { return }
    size := min(tray_icon_size(state), window.Geom.H)
    y := max(i32(0), (window.Geom.H - size) / 2)
    x := start_x
    for icon in state.Tray.Icons {
        values := [4]u32{u32(x), u32(y), u32(size), u32(size)}
        x11.xcb_configure_window(
            state.Conn, icon,
            x11.CW_X | x11.CW_Y | x11.CW_WIDTH | x11.CW_HEIGHT,
            &values[0],
        )
        x11.xcb_map_window(state.Conn, icon)
        x += size + TRAY_ICON_GAP
    }
}

systray_draw :: proc(block: ^Block, state: ^State, window: ^Bar_Window, x: i32, block_index: int) {
    _ = block
    _ = block_index
    width := systray_measure(block, state, window)
    if width <= 0 { return }
    fill_rect(state, window.Xid, x, 0, width, window.Geom.H, state.Config.Background)
    tray_arrange(state, window, x)
}

tray_has_icon :: proc(state: ^State, icon: u32) -> bool {
    for existing in state.Tray.Icons { if existing == icon { return true } }
    return false
}

tray_dock :: proc(state: ^State, icon: u32) {
    if state.Tray.Owner == 0 || icon == 0 || tray_has_icon(state, icon) { return }
    x11.xcb_change_save_set(state.Conn, 0, icon) // SetModeInsert
    x11.xcb_reparent_window(state.Conn, icon, state.Tray.Owner, 0, 0)
    append(&state.Tray.Icons, icon)
    tray_send_xembed(state, icon)
    draw_all_bars(state)
}

tray_remove :: proc(state: ^State, icon: u32, destroyed: bool = false) {
    for existing, index in state.Tray.Icons {
        if existing != icon { continue }
        unordered_remove(&state.Tray.Icons, index)
        if !destroyed {
            x11.xcb_unmap_window(state.Conn, icon)
            x11.xcb_reparent_window(state.Conn, icon, state.Root, 0, 0)
            x11.xcb_change_save_set(state.Conn, 1, icon) // SetModeDelete
        }
        draw_all_bars(state)
        return
    }
}

tray_handle_client_message :: proc(state: ^State, event: ^x11.Client_Message_Event) -> bool {
    if !state.Tray.Enabled || state.Tray.Owner == 0 ||
       event.type_ != atom(state, "_NET_SYSTEM_TRAY_OPCODE") || event.format != 32 {
        return false
    }
    if event.data.data32[1] == TRAY_REQUEST_DOCK {
        tray_dock(state, event.data.data32[2])
    }
    return true
}

tray_disable :: proc(state: ^State) {
    if state.Tray.Owner != 0 && tray_selection_owner(state) == state.Tray.Owner {
        x11.xcb_set_selection_owner(state.Conn, 0, state.Tray.Selection, 0)
    }
    for icon in state.Tray.Icons {
        x11.xcb_unmap_window(state.Conn, icon)
        x11.xcb_reparent_window(state.Conn, icon, state.Root, 0, 0)
        x11.xcb_change_save_set(state.Conn, 1, icon)
    }
    clear(&state.Tray.Icons)
    state.Tray.Enabled = false
    state.Tray.Owner = 0
    state.Tray.HostBar = 0
}

systray_destroy :: proc(block: ^Block, state: ^State) {
    _ = block
    tray_disable(state)
}

tray_shutdown :: proc(state: ^State) {
    tray_disable(state)
    delete(state.Tray.Icons)
    state.Tray = {}
}
