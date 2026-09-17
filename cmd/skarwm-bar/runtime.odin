package main

import x11 "../../src/x11"

import "core:sys/posix"

window_by_xid :: proc(state: ^State, xid: u32) -> ^Bar_Window {
    for &window in state.Windows { if window.Xid == xid { return &window } }
    return nil
}

hit_at :: proc(window: ^Bar_Window, x, y: i32) -> (Hitbox, bool) {
    if window == nil { return {}, false }
    for hit in window.Hits {
        if x >= hit.X && x < hit.X + hit.W && y >= hit.Y && y < hit.Y + hit.H {
            return hit, true
        }
    }
    return {}, false
}

handle_x_event :: proc(state: ^State, event: ^x11.Event) -> bool {
    header := (^x11.Event_Header)(event)
    response_type := header.response_type & 0x7F
    if state.RandrAvailable &&
       (response_type == state.RandrEventBase || response_type == state.RandrEventBase + 1) {
        rebuild_windows(state)
        ipc_request_workspaces(state)
        return true
    }
    switch response_type {
    case u8(x11.EVENT_CLIENT_MESSAGE):
        tray_handle_client_message(state, (^x11.Client_Message_Event)(event))
    case u8(x11.EVENT_DESTROY_NOTIFY):
        destroyed := (^x11.Destroy_Notify_Event)(event)
        if destroyed.event == state.Tray.HostBar { tray_remove(state, destroyed.window, true) }
    case u8(x11.EVENT_UNMAP_NOTIFY):
        unmapped := (^x11.Unmap_Notify_Event)(event)
        if unmapped.event == state.Tray.HostBar { tray_remove(state, unmapped.window) }
    case u8(x11.EVENT_SELECTION_CLEAR):
        cleared := (^x11.Selection_Clear_Event)(event)
        if cleared.selection == state.Tray.Selection && cleared.owner == state.Tray.Owner {
            for icon in state.Tray.Icons {
                x11.xcb_unmap_window(state.Conn, icon)
                x11.xcb_reparent_window(state.Conn, icon, state.Root, 0, 0)
                x11.xcb_change_save_set(state.Conn, 1, icon)
            }
            clear(&state.Tray.Icons)
            state.Tray.Owner = 0
            state.Tray.HostBar = 0
            draw_all_bars(state)
        }
    case u8(x11.EVENT_PROPERTY_NOTIFY):
        if !state.Config.Managed { return true }
        property := (^x11.Property_Notify_Event)(event)
        if property.window != state.Root { return true }
        if property.atom == atom(state, BAR_BLOCKS_ATOM) {
            blocks_reload(state)
            return true
        }
        if property.atom != atom(state, BAR_CONFIG_ATOM) { return true }
        old := state.Config
        enabled, found := read_managed_config(state)
        if !found || !enabled { return false }
        if old.Position != state.Config.Position || old.Height != state.Config.Height ||
           old.Foreground != state.Config.Foreground || old.Background != state.Config.Background {
            rebuild_windows(state)
        }
    case u8(x11.EVENT_EXPOSE):
        expose := (^x11.Expose_Event)(event)
        if window := window_by_xid(state, expose.window); window != nil { draw_bar(state, window) }
    case u8(x11.EVENT_BUTTON_PRESS):
        button := (^x11.Button_Press_Event)(event)
        window := window_by_xid(state, button.event)
        if hit, ok := hit_at(window, i32(button.event_x), i32(button.event_y)); ok &&
           hit.BlockIndex >= 0 && hit.BlockIndex < len(state.Blocks) {
            block := &state.Blocks[hit.BlockIndex]
            if block.Ops.Click != nil { block.Ops.Click(block, state, window, hit.Payload, button.detail) }
        }
    case u8(x11.EVENT_MOTION_NOTIFY):
        motion := (^x11.Motion_Notify_Event)(event)
        window := window_by_xid(state, motion.event)
        if window == nil { return true }
        hovered := 0
        if hit, ok := hit_at(window, i32(motion.event_x), i32(motion.event_y)); ok {
            hovered = hit.Payload
        }
        if hovered != window.HoverWorkspace {
            window.HoverWorkspace = hovered
            draw_bar(state, window)
        }
    case u8(x11.EVENT_LEAVE_NOTIFY):
        leave := (^x11.Enter_Notify_Event)(event)
        if window := window_by_xid(state, leave.event); window != nil && window.HoverWorkspace != 0 {
            window.HoverWorkspace = 0
            draw_bar(state, window)
        }
    case:
    }
    return true
}

run_event_loop :: proc(state: ^State) {
    xfd := posix.FD(x11.xcb_get_file_descriptor(state.Conn))
    running := true
    for running && x11.xcb_connection_has_error(state.Conn) == 0 {
        if state.IpcFd < 0 { ipc_start(state) }
        scripts_service(state)
        count := 1
        if state.IpcFd >= 0 { count = 2 }
        descriptors: [2]posix.pollfd
        descriptors[0] = posix.pollfd{fd = xfd, events = {.IN}}
        if count == 2 { descriptors[1] = posix.pollfd{fd = state.IpcFd, events = {.IN}} }
        timeout := scripts_poll_timeout(state)
        if state.IpcFd < 0 && (timeout < 0 || timeout > 1000) { timeout = 1000 }
        result := posix.poll(&descriptors[0], posix.nfds_t(count), timeout)
        if result < 0 { continue }

        if descriptors[0].revents != {} {
            for {
                event := x11.xcb_poll_for_event(state.Conn)
                if event == nil { break }
                running = handle_x_event(state, event)
                x11.free_libc(event)
                if !running { break }
            }
        }
        if count == 2 {
            revents := descriptors[1].revents
            alive := true
            if .IN in revents { alive = ipc_service(state) }
            if .HUP in revents || .ERR in revents || .NVAL in revents { alive = false }
            if !alive { ipc_disconnect(state) }
        }
        scripts_service(state)
    }
}
