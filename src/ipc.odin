package main

// i3-compatible IPC server. This file is the socket half of the i3 subset
// skarwm serves; the wire format, the JSON
// payloads and the request parsers live in the core package
// (src/core/ipc.odin) so they can be unit-tested without sockets. A
// Quickshell bar (or any client) connects to $XDG_RUNTIME_DIR/skarwm.sock
// (or $SKARWM_SOCKET), subscribes to workspace/window events, snapshots state,
// and controls the WM with RUN_COMMAND.
//
// The server is nonblocking and lives in the same poll loop as the X
// connection (event_loop, main.odin): each client keeps a core Ipc_Reader
// for frame reassembly and an output buffer that is drained as the socket
// allows. IPC is best-effort — when the listener cannot be created the WM
// logs a warning and keeps running without it (keyboard/EWMH switching is
// unaffected); g_ipc.listen == -1 means new connections are disabled.

import "core:os"
import "core:strings"
import "core:sys/posix"

import c "core"
import cc "core:c" // c.char / c.size_t (c is taken by the skarwm core package)

Ipc_Client :: struct {
    fd:      posix.FD,
    ws_sub:  bool, // subscribed to "workspace" events
    out_sub: bool, // subscribed to RandR topology/geometry/focus events
    win_sub: bool, // subscribed to window lifecycle/focus/title events
    reader:  c.Ipc_Reader, // partial-frame reassembly (owns its buffer)
    out:     [dynamic]u8, // bytes queued for the socket
    off:     int,         // out[off:] is still unsent
}

Ipc_State :: struct {
    path:    string, // socket file to remove at shutdown (owned; "" when disabled)
    listen:  posix.FD, // listening socket; -1 when IPC is disabled
    clients: [dynamic]^Ipc_Client,
}

g_ipc := Ipc_State{listen = -1}

// ---------------------------------------------------------------------------
// listener lifecycle
// ---------------------------------------------------------------------------

// ipc_start brings up the listener at $XDG_RUNTIME_DIR/skarwm.sock (fallback:
// /tmp/skarwm-<euid>.sock). Best effort: any failure logs a warning and IPC
// stays disabled. Also ensures workspace 1 exists and is current — an i3
// snapshot must never show zero workspaces (EWMH already advertises desktop 0
// from boot).
ipc_start :: proc() {
    if g_ipc.listen >= 0 { return }

    path, ok := ipc_sock_path()
    if !ok { return }

    // The directory may be missing (XDG_RUNTIME_DIR set but not created);
    // mkdir tolerates an existing directory, so no existence check needed.
    if i := strings.last_index(path, "/"); i > 0 {
        buf: [256]u8
        if posix.mkdir(nul_path(buf[:], path[:i]), {.IRUSR, .IWUSR, .IXUSR}) == .FAIL &&
            posix.errno() != .EEXIST {
            log_warn("ipc: cannot create", path[:i], ":", posix.errno(), "— IPC disabled")
            delete(path)
            return
        }
    }

    // Remove a socket left behind by a dead instance (the path check below
    // would otherwise fail with EADDRINUSE).
    buf: [256]u8
    posix.unlink(nul_path(buf[:], path))

    fd := posix.socket(.UNIX, .STREAM)
    if fd < 0 {
        log_warn("ipc: socket:", posix.errno(), "— IPC disabled")
        delete(path)
        return
    }

    addr: posix.sockaddr_un
    addr.sun_family = .UNIX
    for i in 0 ..< len(path) { addr.sun_path[i] = cc.char(path[i]) }
    if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .FAIL {
        log_warn("ipc: bind", path, ":", posix.errno(), "— IPC disabled")
        posix.close(fd)
        delete(path)
        return
    }
    if posix.chmod(nul_path(buf[:], path), {.IRUSR, .IWUSR}) == .FAIL {
        log_warn("ipc: chmod:", posix.errno(), "(continuing)")
    }
    if posix.listen(fd, 16) == .FAIL {
        log_warn("ipc: listen:", posix.errno(), "— IPC disabled")
        posix.close(fd)
        delete(path)
        return
    }
    ipc_set_nonblock(fd)

    m := g_wm.m
    if c.Current_WS(m) == nil {
        if ws := c.Ensure_WS(m, 1); ws != nil { c.Activate_WS(m, ws) }
    }

    g_ipc.listen = fd
    g_ipc.path = path // the socket file now belongs to us (unlinked at stop)
    log_info("ipc: listening on", path)
}

// ipc_sock_path resolves where the listener socket lives. ok = false when the
// location cannot be used at all (IPC stays disabled). The path is capped at
// the Unix-socket 108-byte limit.
ipc_sock_path :: proc() -> (path: string, ok: bool) {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    env_buf: [512]u8
    override := os.get_env_buf(env_buf[:], "SKARWM_SOCKET")
    if override != "" {
        strings.write_string(&sb, override)
        if len(strings.to_string(sb)) >= len(posix.sockaddr_un{}.sun_path) {
            log_warn("ipc: socket path too long — IPC disabled")
            return "", false
        }
        return strings.clone(strings.to_string(sb)), true
    }
    dir := os.get_env_buf(env_buf[:], "XDG_RUNTIME_DIR") // view into env_buf
    if dir != "" {
        strings.write_string(&sb, dir)
        strings.write_string(&sb, "/skarwm.sock")
    } else {
        strings.write_string(&sb, "/tmp/skarwm-")
        strings.write_int(&sb, int(posix.geteuid()))
        strings.write_string(&sb, ".sock")
    }
    if len(strings.to_string(sb)) >= len(posix.sockaddr_un{}.sun_path) {
        log_warn("ipc: socket path too long — IPC disabled")
        return "", false
    }
    return strings.clone(strings.to_string(sb)), true
}

// ipc_stop tears the server down: every client socket, the listener and the
// socket file. Runs at exit (registered after cleanup_all, so it runs first
// while the model is still alive).
ipc_stop :: proc() {
    for len(g_ipc.clients) > 0 { ipc_drop_client(g_ipc.clients[0]) }
    delete(g_ipc.clients)
    if g_ipc.listen >= 0 { posix.close(g_ipc.listen) }
    if g_ipc.path != "" {
        buf: [256]u8
        posix.unlink(nul_path(buf[:], g_ipc.path))
        delete(g_ipc.path)
    }
    g_ipc = {}
}

// ipc_listener_down disables the listener after a fatal accept error. Existing
// connections keep working; new ones get ECONNREFUSED. The socket file is
// removed so nothing stale blocks a restart.
ipc_listener_down :: proc() {
    if g_ipc.listen >= 0 {
        posix.close(g_ipc.listen)
        g_ipc.listen = -1
    }
    if g_ipc.path != "" {
        buf: [256]u8
        posix.unlink(nul_path(buf[:], g_ipc.path))
        delete(g_ipc.path)
        g_ipc.path = ""
    }
}

// nul_path copies s (plus a NUL terminator) into buf and returns it as a
// cstring. Socket paths are at most 107 bytes, so 256 is plenty.
nul_path :: proc(buf: []u8, s: string) -> cstring {
    n := min(len(s), len(buf) - 1)
    copy(buf[:n], s)
    buf[n] = 0
    return cstring(raw_data(buf))
}

// ipc_set_nonblock puts a socket in nonblocking mode (poll gates every read
// and write; a blocking recv/send/accept would stall the whole WM).
ipc_set_nonblock :: proc(fd: posix.FD) {
    // Spawned applications must not inherit the listener/client sockets.
    posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
    fl := posix.fcntl(fd, .GETFL)
    if fl < 0 { return }
    posix.fcntl(fd, .SETFL, int(fl) | int(posix.O_NONBLOCK))
}

// ---------------------------------------------------------------------------
// accept / per-client service
// ---------------------------------------------------------------------------

// ipc_accept drains the listener's pending-connection queue (the listener is
// nonblocking; poll gates the call). Client sockets are nonblocking too.
ipc_accept :: proc() {
    for {
        fd := posix.accept(g_ipc.listen, nil, nil)
        if fd >= 0 {
            ipc_set_nonblock(fd)
            cl := new(Ipc_Client)
            cl.fd = fd
            append(&g_ipc.clients, cl)
            continue
        }
        err := posix.errno()
        if err == .EINTR || err == .ECONNABORTED { continue } // transient
        if err == .EAGAIN { return }                          // drained
        log_warn("ipc: accept:", err, "— disabling the listener")
        ipc_listener_down()
        return
    }
}

// ipc_service_client drains everything currently readable from one client,
// answering each complete request frame. Returns false when the connection
// should be closed (peer gone, or a protocol violation: bad magic or an
// oversized declared length drop the connection, i3-style).
ipc_service_client :: proc(cl: ^Ipc_Client) -> bool {
    buf: [4096]u8
    for {
        n := posix.recv(cl.fd, &buf, cc.size_t(len(buf)), {})
        if n > 0 {
            frames, good := c.ipc_reader_feed(&cl.reader, buf[:n])
            for i := 0; i < len(frames); i += 1 {
                alive := ipc_handle_frame(cl, frames[i])
                delete(frames[i].payload)
                if !alive {
                    for j := i + 1; j < len(frames); j += 1 { delete(frames[j].payload) }
                    delete(frames)
                    return false
                }
            }
            delete(frames)
            if !good { return false }
            continue // the kernel may have more buffered
        }
        if n == 0 { return false } // peer closed
        err := posix.errno()
        if err == .EINTR { continue }
        if err == .EAGAIN { return true }
        return false
    }
}

// ipc_handle_frame answers one request frame. Replies are queued before the
// command's side effects run, so a subscriber sees its reply followed by any
// workspace events the command triggered — i3's ordering. Returns false when
// the connection must be dropped (malformed SUBSCRIBE: i3 answers with an
// error and closes).
ipc_handle_frame :: proc(cl: ^Ipc_Client, f: c.Ipc_Frame) -> bool {
    m := g_wm.m
    msg := c.Ipc_Type(f.typ)
    switch msg {
    case .Subscribe:
        ws, out, win, good := c.ipc_parse_subscribe(f.payload)
        if !good {
            pl := c.ipc_command_reply_payload(false, "expected a JSON array of quoted event names")
            ipc_send(cl, msg, pl)
            delete(pl)
            return false
        }
        cl.ws_sub = cl.ws_sub || ws // subscriptions accumulate
        cl.out_sub = cl.out_sub || out
        cl.win_sub = cl.win_sub || win
        pl := c.ipc_command_reply_payload(true, "")
        ipc_send(cl, msg, pl)
        delete(pl)

    case .Command:
        cmd, err, good := c.ipc_parse_command(f.payload)
        if !good {
            pl := c.ipc_command_reply_payload(false, err)
            ipc_send(cl, msg, pl)
            delete(pl)
            if err != "" do delete(err)
            return true
        }
        pl := c.ipc_command_reply_payload(true, "")
        ipc_send(cl, msg, pl) // reply first
        delete(pl)
        ipc_run_command(cmd) // its events trail the reply

    case .Get_Workspaces:
        pl := c.ipc_workspaces_payload(m)
        ipc_send(cl, msg, pl)
        delete(pl)

    case .Get_Outputs:
        pl := c.ipc_outputs_payload(m)
        ipc_send(cl, msg, pl)
        delete(pl)

    case .Get_Windows:
        pl := c.ipc_windows_payload(m)
        ipc_send(cl, msg, pl)
        delete(pl)

    case .Get_Version:
        pl := c.ipc_version_payload()
        ipc_send(cl, msg, pl)
        delete(pl)

    case .Event_Workspace, .Event_Output, .Event_Window:
        // Event frames are server→client traffic; a client that sends one
        // gets the same empty-body reply as any other unknown type.
        ipc_send(cl, msg, nil)

    case:
        ipc_send(cl, msg, nil) // unknown types get an empty body
    }
    return true
}

ipc_run_command :: proc(cmd: c.Ipc_Command) {
    b: Binding
    b.arg = cmd.arg
    switch cmd.action {
    case .Focus_Left:        b.action = .Focus_Left
    case .Focus_Right:       b.action = .Focus_Right
    case .Focus_Up:          b.action = .Focus_Up
    case .Focus_Down:        b.action = .Focus_Down
    case .Move_Left:         b.action = .Move_Left
    case .Move_Right:        b.action = .Move_Right
    case .Move_Up:           b.action = .Move_Up
    case .Move_Down:         b.action = .Move_Down
    case .Workspace:         b.action = .WS_Goto
    case .Workspace_Next:    b.action = .WS_Next
    case .Workspace_Prev:    b.action = .WS_Prev
    case .Move_To_Workspace: b.action = .Move_To_WS
    case .Move_To_Workspace_Next: b.action = .Move_To_WS_Next
    case .Move_To_Workspace_Prev: b.action = .Move_To_WS_Prev
    case .Toggle_Floating:   b.action = .Toggle_Floating
    case .Toggle_Fullscreen: b.action = .Toggle_Fullscreen
    case .Layout_Tabbed:     b.action = .Layout_Tabbed
    case .Layout_Stacked:    b.action = .Layout_Stacked
    case .Layout_Toggle:     b.action = .Layout_Toggle
    case .Show_Bindings:     b.action = .Show_Bindings
    case .Focus_Output_Next: b.action = .Focus_Output_Next
    case .Focus_Output_Prev: b.action = .Focus_Output_Prev
    case .Move_To_Output_Next: b.action = .Move_To_Output_Next
    case .Move_To_Output_Prev: b.action = .Move_To_Output_Prev
    case .Close:             b.action = .Close
    case .Reload:            b.action = .Reload
    case .Quit:              b.action = .Quit
    case .Invalid:           return
    }
    dispatch_action(&b)
}

// ipc_drop_client closes one client's socket and frees its state (partial
// frames and queued writes are discarded).
ipc_drop_client :: proc(cl: ^Ipc_Client) {
    posix.close(cl.fd)
    delete(cl.out)
    if cl.reader.buf != nil do delete(cl.reader.buf)
    for i in 0 ..< len(g_ipc.clients) {
        if g_ipc.clients[i] == cl {
            ordered_remove(&g_ipc.clients, i)
            break
        }
    }
    free(cl)
}

// ---------------------------------------------------------------------------
// writes
// ---------------------------------------------------------------------------

// ipc_send queues one frame on the client's write buffer and flushes what the
// socket takes right away. The frame is copied, so payload only needs to live
// for the call. A failed flush does not close the client here — the socket
// error surfaces through poll (.ERR) and the next service pass drops it.
ipc_send :: proc(cl: ^Ipc_Client, typ: c.Ipc_Type, payload: []byte) {
    frame := c.ipc_encode(typ, payload)
    defer delete(frame)
    append(&cl.out, ..frame)
    ipc_flush_client(cl)
}

// ipc_flush_client pushes queued bytes to the socket. Returns false when the
// connection cannot be written any more.
ipc_flush_client :: proc(cl: ^Ipc_Client) -> bool {
    for cl.off < len(cl.out) {
        n := posix.send(cl.fd, raw_data(cl.out[cl.off:]), cc.size_t(len(cl.out)) - cc.size_t(cl.off), {.NOSIGNAL})
        if n > 0 {
            cl.off += int(n)
            continue
        }
        if n < 0 && posix.errno() == .EAGAIN { return true } // poll(.OUT) retries
        return false // EPIPE/ECONNRESET/…
    }
    if cl.off == len(cl.out) { // drained: reuse the buffer (clear keeps capacity)
        clear(&cl.out)
        cl.off = 0
    }
    return true
}

// ipc_broadcast_ws_event announces a workspace change to every subscribed
// client. change is one of c.IPC_CHANGE_*; cur/old are the affected
// workspace objects (nil renders as null). A no-op while IPC is disabled.
// Emission points: ws_switch_to (init for a fresh workspace, focus on every
// switch), move_focused_to_ws and unmanage (empty), ewmh_activate.
ipc_broadcast_ws_event :: proc(change: string, cur, old: ^c.Workspace) {
    if len(g_ipc.clients) == 0 { return }
    payload := c.ipc_ws_event_payload(g_wm.m, change, cur, old)
    defer delete(payload)
    for cl in g_ipc.clients {
        if cl.ws_sub { ipc_send(cl, .Event_Workspace, payload) }
    }
}

ipc_broadcast_output_event :: proc(change, output: string) {
    if len(g_ipc.clients) == 0 { return }
    payload := c.ipc_output_event_payload(change, output)
    defer delete(payload)
    for cl in g_ipc.clients {
        if cl.out_sub { ipc_send(cl, .Event_Output, payload) }
    }
}


ipc_broadcast_window_event :: proc(change: string, cl: ^c.Client) {
    if len(g_ipc.clients) == 0 { return }
    payload := c.ipc_window_event_payload(g_wm.m, change, cl)
    defer delete(payload)
    for peer in g_ipc.clients {
        if peer.win_sub { ipc_send(peer, .Event_Window, payload) }
    }
}

ipc_broadcast_focus_change :: proc(old, current: ^c.Client) {
    if old == current { return }
    ipc_broadcast_window_event(c.IPC_WINDOW_FOCUS, current)
}
