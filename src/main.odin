package main

// Entry point and X event loop.
//
//   1. connect, claim the screen (checked SubstructureRedirect; a BadAccess here
//      means another WM already owns it → exit)
//   2. parse argv (-c FILE), load keyboard/modifier maps
//   3. load configuration (rc file, or built-in defaults) and grab keys
//   4. adopt any windows already present at start-up
//   5. poll() on the X connection fd and dispatch events forever

import "core:os"
import "core:sys/posix"

import c "core"

main :: proc() {
    log_init()
    if !wm_startup() {
        log_error("startup failed — cannot connect to X or another window manager is running")
        os.exit(1)
    }
    defer cleanup_all()

    parse_cli_args()

    // Load configuration first so its rules also apply when adopting windows
    // that already exist at startup.
    cfg_initial_load()
    ewmh_init() // publish EWMH root state before any window is managed
    adopt_existing()
    xcb_flush(g_wm.conn)
    reflow()

    g_wm.running = true
    ipc_start() // i3-IPC listener (best effort; ws 1 ensured for the snapshot)
    defer ipc_stop() // before cleanup_all: teardown the sockets first
    event_loop()
}

// parse_cli_args reads command-line options. Today: skarwm -c FILE (config path).
parse_cli_args :: proc() {
    args := os.args
    i := 1
    for i < len(args) {
        switch args[i] {
        case "-c", "--config":
            if i + 1 < len(args) {
                g_cfg_flag = strings_clone_here(args[i + 1])
                i += 1
            }
        }
        i += 1
    }
}

// ---------------------------------------------------------------------------
// startup / teardown
// ---------------------------------------------------------------------------

wm_startup :: proc() -> bool {
    conn := xcb_connect(nil, nil)
    if conn == nil { return false }
    g_wm.conn = conn
    if xcb_connection_has_error(conn) != 0 { return false }

    iter := xcb_setup_roots_iterator(xcb_get_setup(conn))
    if iter.rem <= 0 || iter.data == nil { return false }
    scr := iter.data
    g_wm.root = scr.root
    g_wm.scr_w = i32(scr.width_in_pixels)
    g_wm.scr_h = i32(scr.height_in_pixels)
    g_wm.white_pixel = scr.white_pixel

    m := c.New_Manager()
    g_wm.m = m
    c.Setup_Output(m, "screen", c.Rect{X = 0, Y = 0, W = g_wm.scr_w, H = g_wm.scr_h})

    g_wm.atoms = make(map[string]u32)
    g_wm.bindings = make([dynamic]Binding, 0, 32)
    g_wm.rules = make([dynamic]Raw_Rule, 0, 4)
    g_wm.ran_startups = make([dynamic]string, 0, 4)
    g_wm.tabs = make([dynamic]Tab_Decoration, 0, 8)
    g_wm.lock = MOD_MASK_LOCK

    // Claim the screen. If a WM already has a SubstructureRedirect grab on the
    // root, our checked request comes back BadAccess and we must step aside.
    mask := u32(
        EVENT_MASK_SUBSTRUCTURE_REDIRECT |
        EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        EVENT_MASK_STRUCTURE_NOTIFY,
    )
    cookie := xcb_change_window_attributes_checked(g_wm.conn, g_wm.root, CW_EVENT_MASK, &mask)
    if err := xcb_request_check(g_wm.conn, cookie); err != nil {
        free_libc(err)
        return false
    }

    // Keyboard/modifier snapshots (rebuilt on MappingNotify).
    kb, ok1 := kbd_load(g_wm.conn)
    mm, ok2 := mod_load(g_wm.conn)
    if !ok1 || !ok2 {
        if ok1 do kbd_free(&kb)
        if ok2 do mod_free(&mm)
        log_error("could not read keyboard mapping")
        return false
    }
    g_wm.kb = kb
    g_wm.mm = mm
    g_wm.numlock = modifier_mask_for_keysym(&g_wm.kb, &g_wm.mm, keysym_from_name("Num_Lock"))

    g_wm.terminal = detect_terminal()
    if g_wm.terminal == "" {
        log_warn("no terminal emulator found; Super+Return will do nothing")
    }
    randr_init()
    return true
}

cleanup_all :: proc() {
    help_hide()
    tabs_shutdown()
    release_bindings(&g_wm.bindings)
    release_rules(&g_wm.rules)
    if g_wm.ran_startups != nil {
        for s in g_wm.ran_startups { if s != "" { delete(s) } }
        delete(g_wm.ran_startups)
    }
    if g_cfg_flag != "" { delete(g_cfg_flag) }
    if g_wm.m != nil do c.Destroy_Manager(g_wm.m)
    ewmh_free() // destroy the check window, drop EWMH caches
    if g_wm.atoms != nil do delete(g_wm.atoms)
    kbd_free(&g_wm.kb)
    mod_free(&g_wm.mm)
    // g_wm.terminal is a process-lifetime value (possibly a static literal);
    // intentionally not freed.
    if g_wm.conn != nil do xcb_disconnect(g_wm.conn)
    g_wm = {}
}

// ---------------------------------------------------------------------------
// adopt existing windows
// ---------------------------------------------------------------------------

// window_info fetches the attribute subset the manager cares about.
window_info :: proc(wid: u32) -> (ok: bool, override_redirect: bool, map_state: u8, class: u16) {
    cookie := xcb_get_window_attributes(g_wm.conn, wid)
    e: ^Error
    reply := xcb_get_window_attributes_reply(g_wm.conn, cookie, &e)
    if e != nil {
        free_libc(e)
        return false, false, 0, 0
    }
    if reply == nil { return false, false, 0, 0 }
    defer free_libc(reply)
    return true, reply.override_redirect != 0, reply.map_state, reply.class
}

// adopt_existing manages every viewable, non-override-redirect, InputOutput
// child of the root found at start-up (e.g. when this WM replaces another).
adopt_existing :: proc() {
    cookie := xcb_query_tree(g_wm.conn, g_wm.root)
    e: ^Error
    reply := xcb_query_tree_reply(g_wm.conn, cookie, &e)
    if e != nil {
        free_libc(e)
        return
    }
    if reply == nil { return }
    defer free_libc(reply)

    n := int(reply.children_len)
    if n == 0 { return }
    src := rawptr(uintptr(rawptr(reply)) + uintptr(size_of(Query_Tree_Reply)))
    ids := ([^]u32)(src)[:n]
    for i in 0 ..< n {
        wid := ids[i]
        ok, override_redir, map_state, class := window_info(wid)
        if !ok || override_redir { continue }
        if class == WINDOW_CLASS_INPUT_ONLY { continue }
        if map_state == MAP_STATE_VIEWABLE {
            manage(wid, false)
        }
    }
}

// ---------------------------------------------------------------------------
// event loop
// ---------------------------------------------------------------------------

event_loop :: proc() {
    xfd := posix.FD(xcb_get_file_descriptor(g_wm.conn))
    for g_wm.running {
        xcb_flush(g_wm.conn)
        if xcb_connection_has_error(g_wm.conn) != 0 { break }

        // Rebuild the poll set every iteration: the X connection, the IPC
        // listener (when enabled), then one entry per IPC client (with .OUT
        // while that client has queued writes).
        n := 1
        if g_ipc.listen >= 0 { n += 1 }
        n += len(g_ipc.clients)
        pfds := make([]posix.pollfd, n)
        pfds[0] = posix.pollfd{fd = xfd, events = {.IN}}
        i := 1
        if g_ipc.listen >= 0 {
            pfds[i] = posix.pollfd{fd = g_ipc.listen, events = {.IN}}
            i += 1
        }
        for cl in g_ipc.clients {
            events := posix.Poll_Event {.IN}
            if cl.off < len(cl.out) { events += {.OUT} }
            pfds[i] = posix.pollfd{fd = cl.fd, events = events}
            i += 1
        }

        if posix.poll(raw_data(pfds), posix.nfds_t(len(pfds)), -1) < 0 {
            delete(pfds) // EINTR or a signal: repoll
            continue
        }

        // X events
        if pfds[0].revents != {} {
            for {
                ev := xcb_poll_for_event(g_wm.conn)
                if ev == nil { break }
                handle_event(ev)
                free_libc(ev)
            }
        }

        // IPC: accept new clients, then serve every client with revents.
        i = 1
        if g_ipc.listen >= 0 {
            if pfds[i].revents != {} { ipc_accept() }
            i += 1
        }
        // pfds[i:] mirrors g_ipc.clients[:] as built above; ipc_accept may
        // have appended clients beyond the set, so walk only what we built.
        base := i
        to_drop: [dynamic]^Ipc_Client
        for i < len(pfds) {
            pd := pfds[i]
            if pd.revents != {} {
                cl := g_ipc.clients[i - base]
                alive := true
                if .IN in pd.revents { alive = ipc_service_client(cl) }
                if alive && (.HUP in pd.revents || .ERR in pd.revents || .NVAL in pd.revents) {
                    alive = false
                }
                if alive && .OUT in pd.revents { alive = ipc_flush_client(cl) }
                if !alive { append(&to_drop, cl) }
            }
            i += 1
        }
        for cl in to_drop { ipc_drop_client(cl) } // removed after the walk
        delete(to_drop)
        delete(pfds)
    }
}

handle_event :: proc(ev: ^Event) {
    hdr := (^Event_Header)(ev)
    rt := hdr.response_type
    // Synthetic events — EWMH/ICCCM client messages sent with XSendEvent —
    // arrive with the send-event bit (0x80) set in the response type; xcb
    // reports it raw, so strip it before dispatching. After stripping, a zero
    // response type is a genuine error packet from an unchecked request racing
    // with window destruction — ignore those.
    rt &= 0x7F
    if rt == 0 { return }
    if randr_handle_event(rt) { return }

    switch rt {
    case u8(EVENT_KEY_PRESS):
        on_keypress((^Key_Press_Event)(ev))

    case u8(EVENT_MAP_REQUEST):
        // a client (or the server adopting) wants to map an unmanaged window
        e := (^Map_Request_Event)(ev)
        ok, override_redir, _, class := window_info(e.window)
        if !ok || override_redir { return }
        if class == WINDOW_CLASS_INPUT_ONLY { return }
        manage(e.window, false)

    case u8(EVENT_UNMAP_NOTIFY):
        // client withdrew/iconified itself; drop it (re-managed on next MapRequest)
        e := (^Unmap_Notify_Event)(ev)
        if cl := g_wm.m.ByXid[e.window]; cl != nil {
            unmanage(cl)
        }

    case u8(EVENT_DESTROY_NOTIFY):
        e := (^Destroy_Notify_Event)(ev)
        if cl := g_wm.m.ByXid[e.window]; cl != nil {
            unmanage(cl)
        }

    case u8(EVENT_CONFIGURE_REQUEST):
        on_configure_request((^Configure_Request_Event)(ev))

    case u8(EVENT_CONFIGURE_NOTIFY):
        on_configure_notify((^Configure_Notify_Event)(ev))

    case u8(EVENT_ENTER_NOTIFY):
        on_enter((^Enter_Notify_Event)(ev))

    case u8(EVENT_BUTTON_PRESS):
        on_button_press((^Button_Press_Event)(ev))

    case u8(EVENT_BUTTON_RELEASE):
        on_button_release((^Button_Press_Event)(ev))

    case u8(EVENT_MOTION_NOTIFY):
        on_motion((^Motion_Notify_Event)(ev))

    case u8(EVENT_EXPOSE):
        xid := (^Expose_Event)(ev).window
        if xid == g_wm.help_window {
            help_draw()
        } else {
            draw_tab(xid)
        }

    case u8(EVENT_MAPPING_NOTIFY):
        on_mapping_notify()

    case u8(EVENT_PROPERTY_NOTIFY):
        on_property_notify((^Property_Notify_Event)(ev))

    case u8(EVENT_CLIENT_MESSAGE):
        on_client_message((^Client_Message_Event)(ev))

    case:
        // ignore MapNotify, Button*, Focus*, …
    }
}

// The keyboard layout or modifier map changed (setxkbmap, NumLock toggles the
// modifier assignment, a key grabbed by another client, …). Reload and regrab.
on_mapping_notify :: proc() {
    if kb, ok := kbd_load(g_wm.conn); ok {
        kbd_free(&g_wm.kb)
        g_wm.kb = kb
    }
    if mm, ok := mod_load(g_wm.conn); ok {
        mod_free(&g_wm.mm)
        g_wm.mm = mm
    }
    g_wm.numlock = modifier_mask_for_keysym(&g_wm.kb, &g_wm.mm, keysym_from_name("Num_Lock"))
    grab_all_keys()
    xcb_flush(g_wm.conn)
}

// on_client_message handles EWMH/ICCCM activation, fullscreen state changes,
// workspace and move requests, and close requests.
on_client_message :: proc(ev: ^Client_Message_Event) {
    ewmh_on_client_message(ev)
}
