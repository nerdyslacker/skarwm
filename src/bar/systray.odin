package main

import x11 "../x11"

import "core:fmt"

Tray_State :: struct {
    Enabled: bool,
    OwnerConflictReported: bool,
    Owner, HostBar: u32,
    Selection: u32,
    Icons: [dynamic]u32,
}

TRAY_REQUEST_DOCK :: u32(0)
XEMBED_EMBEDDED_NOTIFY :: u32(0)
XEMBED_WINDOW_ACTIVATE :: u32(1)
XEMBED_FOCUS_IN :: u32(4)
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
    event.data.data32[0] = x11.CURRENT_TIME
    event.data.data32[1] = state.Tray.Selection
    event.data.data32[2] = state.Tray.Owner
    x11.xcb_send_event(
        state.Conn, 0, state.Root, x11.EVENT_MASK_STRUCTURE_NOTIFY, rawptr(&event),
    )
}

tray_send_xembed_message :: proc(
    state: ^State, icon, message, detail, data1, data2: u32,
) {
    event := x11.Client_Message_Event{
        response_type = u8(x11.EVENT_CLIENT_MESSAGE),
        format = 32,
        window = icon,
        type_ = atom(state, "_XEMBED"),
    }
    event.data.data32[0] = x11.CURRENT_TIME
    event.data.data32[1] = message
    event.data.data32[2] = detail
    event.data.data32[3] = data1
    event.data.data32[4] = data2
    x11.xcb_send_event(state.Conn, 0, icon, 0, rawptr(&event))
}

tray_notify_embedded :: proc(state: ^State, icon: u32) {
    tray_send_xembed_message(state, icon, XEMBED_EMBEDDED_NOTIFY, 0, state.Tray.Owner, 0)
    tray_send_xembed_message(state, icon, XEMBED_WINDOW_ACTIVATE, 0, 0, 0)
    tray_send_xembed_message(state, icon, XEMBED_FOCUS_IN, 0, 0, 0)
}

tray_send_configure :: proc(state: ^State, icon: u32, x, y, width, height: i32) {
    event := x11.Configure_Notify_Event{
        response_type = u8(x11.EVENT_CONFIGURE_NOTIFY),
        event = icon, window = icon,
        x = i16(x), y = i16(y), width = u16(width), height = u16(height),
    }
    x11.xcb_send_event(
        state.Conn, 0, icon, x11.EVENT_MASK_STRUCTURE_NOTIFY, rawptr(&event),
    )
}

tray_reparent_icons :: proc(state: ^State) {
    if state.Tray.Owner == 0 { return }
    for icon in state.Tray.Icons {
        x11.xcb_change_save_set(state.Conn, 0, icon)
        x11.xcb_reparent_window(state.Conn, icon, state.Tray.Owner, 0, 0)
        x11.xcb_map_window(state.Conn, icon)
        tray_notify_embedded(state, icon)
    }
}

tray_update_owner :: proc(state: ^State) {
    if !state.Tray.Enabled || len(state.Windows) == 0 { return }
    host := state.Windows[0].Xid
    if state.Tray.Owner != 0 && state.Tray.HostBar == host &&
       tray_selection_owner(state) == state.Tray.Owner { return }
    existing := tray_selection_owner(state)
    if existing != 0 && existing != state.Tray.Owner {
        if !state.Tray.OwnerConflictReported {
            fmt.eprintfln(
                "skarwm-bar: system tray selection is already owned by window 0x%x", existing,
            )
            state.Tray.OwnerConflictReported = true
        }
        return
    }
    state.Tray.OwnerConflictReported = false

    owner := x11.xcb_generate_id(state.Conn)
    event_mask := x11.EVENT_MASK_STRUCTURE_NOTIFY | x11.EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        x11.EVENT_MASK_SUBSTRUCTURE_REDIRECT | x11.EVENT_MASK_EXPOSURE
    values := [3]u32{state.Config.BlockBackground, 1, event_mask}
    cookie := x11.xcb_create_window_checked(
        state.Conn, 0, owner, host, 0, 0, 1, u16(tray_icon_size(state)), 0,
        x11.WINDOW_CLASS_INPUT_OUTPUT, 0,
        x11.CW_BACK_PIXEL | x11.CW_OVERRIDE_REDIRECT | x11.CW_EVENT_MASK, &values[0],
    )
    if error := x11.xcb_request_check(state.Conn, cookie); error != nil {
        x11.free_libc(error)
        return
    }
    state.Tray.HostBar = host
    state.Tray.Owner = owner
    x11.xcb_set_selection_owner(state.Conn, owner, state.Tray.Selection, x11.CURRENT_TIME)
    x11.xcb_flush(state.Conn)
    if tray_selection_owner(state) != owner {
        x11.xcb_destroy_window(state.Conn, owner)
        state.Tray.Owner = 0
        state.Tray.HostBar = 0
        return
    }
    orientation := []u32{0} // _NET_SYSTEM_TRAY_ORIENTATION_HORZ
    x11.set_prop32(
        state.Conn, owner, atom(state, "_NET_SYSTEM_TRAY_ORIENTATION"),
        atom(state, "CARDINAL"), orientation,
    )
    visual := []u32{state.RootVisual}
    x11.set_prop32(
        state.Conn, owner, atom(state, "_NET_SYSTEM_TRAY_VISUAL"),
        atom(state, "VISUALID"), visual,
    )
    x11.xcb_map_window(state.Conn, owner)
    tray_send_manager(state)
    tray_reparent_icons(state)
}

tray_detach_for_rebuild :: proc(state: ^State) {
    if state.Tray.Owner == 0 { return }
    for icon in state.Tray.Icons {
        x11.xcb_reparent_window(state.Conn, icon, state.Root, 0, 0)
    }
    if tray_selection_owner(state) == state.Tray.Owner {
        x11.xcb_set_selection_owner(state.Conn, 0, state.Tray.Selection, x11.CURRENT_TIME)
    }
    x11.xcb_destroy_window(state.Conn, state.Tray.Owner)
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
    width := max(i32(1), systray_measure(nil, state, window))
    owner_values := [4]u32{u32(start_x), u32(y), u32(width), u32(size)}
    x11.xcb_configure_window(
        state.Conn, state.Tray.Owner,
        x11.CW_X | x11.CW_Y | x11.CW_WIDTH | x11.CW_HEIGHT, &owner_values[0],
    )
    x := i32(0)
    for icon in state.Tray.Icons {
        values := [5]u32{u32(x), 0, u32(size), u32(size), 0}
        x11.xcb_configure_window(
            state.Conn, icon, x11.CW_X | x11.CW_Y | x11.CW_WIDTH |
                x11.CW_HEIGHT | x11.CW_BORDER_WIDTH, &values[0],
        )
        x11.xcb_map_window(state.Conn, icon)
        tray_send_configure(state, icon, x, 0, size, size)
        x += size + TRAY_ICON_GAP
    }
}

systray_draw :: proc(block: ^Block, state: ^State, window: ^Bar_Window, x: i32, block_index: int) {
    _ = block
    _ = block_index
    width := systray_measure(block, state, window)
    if width <= 0 { return }
    fill_rect(
        state, X_Drawable(window.Canvas), x, 0, width, window.Geom.H,
        state.Config.Background,
    )
    tray_arrange(state, window, x)
}

tray_has_icon :: proc(state: ^State, icon: u32) -> bool {
    for existing in state.Tray.Icons { if existing == icon { return true } }
    return false
}

tray_dock :: proc(state: ^State, icon: u32) {
    if state.Tray.Owner == 0 || icon == 0 || tray_has_icon(state, icon) { return }
    e: ^x11.Error
    attributes := x11.xcb_get_window_attributes_reply(
        state.Conn, x11.xcb_get_window_attributes(state.Conn, icon), &e,
    )
    if e != nil { x11.free_libc(e) }
    if attributes == nil { return }
    x11.free_libc(attributes)
    icon_events := x11.EVENT_MASK_STRUCTURE_NOTIFY | x11.EVENT_MASK_PROPERTY_CHANGE
    x11.xcb_change_window_attributes(state.Conn, icon, x11.CW_EVENT_MASK, &icon_events)
    x11.xcb_change_save_set(state.Conn, 0, icon) // SetModeInsert
    x11.xcb_reparent_window(state.Conn, icon, state.Tray.Owner, 0, 0)
    append(&state.Tray.Icons, icon)
    tray_notify_embedded(state, icon)
    size := tray_icon_size(state)
    values := [3]u32{u32(size), u32(size), 0}
    x11.xcb_configure_window(
        state.Conn, icon, x11.CW_WIDTH | x11.CW_HEIGHT | x11.CW_BORDER_WIDTH, &values[0],
    )
    x11.xcb_map_window(state.Conn, icon)
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
       event.window != state.Tray.Owner ||
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
        x11.xcb_set_selection_owner(state.Conn, 0, state.Tray.Selection, x11.CURRENT_TIME)
    }
    for icon in state.Tray.Icons {
        x11.xcb_unmap_window(state.Conn, icon)
        x11.xcb_reparent_window(state.Conn, icon, state.Root, 0, 0)
        x11.xcb_change_save_set(state.Conn, 1, icon)
    }
    clear(&state.Tray.Icons)
    if state.Tray.Owner != 0 { x11.xcb_destroy_window(state.Conn, state.Tray.Owner) }
    state.Tray.Enabled = false
    state.Tray.OwnerConflictReported = false
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
