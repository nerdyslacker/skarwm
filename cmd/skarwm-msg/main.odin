package main

// Small client for skarwm's i3-framed IPC subset. Queries print one JSON
// payload; `subscribe` keeps printing event payloads, one per line.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import cc "core:c"
import ipc "../../src/core"

usage :: proc() {
    fmt.eprintln("usage: skarwm-msg [--socket PATH] COMMAND [ARGS...]")
    fmt.eprintln("queries: get-workspaces | get-windows | get-outputs | get-version")
    fmt.eprintln("events:  subscribe [workspace] [window] [output]")
    fmt.eprintln("actions: focus DIR | move DIR | workspace N|next|prev | move workspace N")
    fmt.eprintln("         layout tabbed|stacked|toggle | toggle-tabbed | show-bindings")
    fmt.eprintln("         focus output next|prev | move output next|prev")
    fmt.eprintln("         close | reload | quit | toggle-floating | toggle-fullscreen")
}

main :: proc() {
    args := os.args
    path := ""
    first := 1
    if len(args) >= 3 && args[1] == "--socket" {
        path = args[2]
        first = 3
    }
    if first >= len(args) { usage(); os.exit(2) }
    if path == "" { path = socket_path() }

    typ := ipc.Ipc_Type.Command
    payload := ""
    owned_payload := false
    continuous := false
    switch args[first] {
    case "get-workspaces": typ = .Get_Workspaces
    case "get-windows":    typ = .Get_Windows
    case "get-outputs":    typ = .Get_Outputs
    case "get-version":    typ = .Get_Version
    case "subscribe":
        typ = .Subscribe
        continuous = true
        sb := strings.builder_make()
        strings.write_string(&sb, "[")
        if first + 1 == len(args) {
            strings.write_string(&sb, `"workspace","window","output"`)
        } else {
            for arg, i in args[first + 1:] {
                if i > 0 { strings.write_string(&sb, ",") }
                ipc.ipc_json_string(&sb, arg)
            }
        }
        strings.write_string(&sb, "]")
        payload = strings.clone(strings.to_string(sb))
        owned_payload = true
        strings.builder_destroy(&sb)
    case:
        sb := strings.builder_make()
        for arg, i in args[first:] {
            if i > 0 { strings.write_string(&sb, " ") }
            strings.write_string(&sb, arg)
        }
        payload = strings.clone(strings.to_string(sb))
        owned_payload = true
        strings.builder_destroy(&sb)
    }

    fd := connect_socket(path)
    if fd < 0 { os.exit(1) }
    defer posix.close(fd)

    frame := ipc.ipc_encode(typ, transmute([]u8)payload)
    defer delete(frame)
    if owned_payload { delete(payload) } // ipc_encode copied it into frame
    if !send_all(fd, frame) {
        fmt.eprintln("skarwm-msg: send failed:", posix.errno())
        os.exit(1)
    }

    for {
        reply, ok := recv_frame(fd)
        if !ok { os.exit(1) }
        fmt.println(string(reply.payload))
        failed := typ == .Command && strings.contains(string(reply.payload), `"success":false`)
        delete(reply.payload)
        if failed { os.exit(1) }
        if !continuous { return }
    }
}

socket_path :: proc() -> string {
    buf: [512]u8
    if p := os.get_env_buf(buf[:], "SKARWM_SOCKET"); p != "" { return strings.clone(p) }
    if dir := os.get_env_buf(buf[:], "XDG_RUNTIME_DIR"); dir != "" {
        sb := strings.builder_make()
        strings.write_string(&sb, dir)
        strings.write_string(&sb, "/skarwm.sock")
        result := strings.clone(strings.to_string(sb))
        strings.builder_destroy(&sb)
        return result
    }
    return fmt.tprintf("/tmp/skarwm-%d.sock", posix.geteuid())
}

connect_socket :: proc(path: string) -> posix.FD {
    if len(path) >= len(posix.sockaddr_un{}.sun_path) {
        fmt.eprintln("skarwm-msg: socket path is too long")
        return -1
    }
    fd := posix.socket(.UNIX, .STREAM)
    if fd < 0 { fmt.eprintln("skarwm-msg: socket:", posix.errno()); return -1 }
    addr: posix.sockaddr_un
    addr.sun_family = .UNIX
    for ch, i in path { addr.sun_path[i] = cc.char(ch) }
    if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .FAIL {
        fmt.eprintln("skarwm-msg: cannot connect to", path, ":", posix.errno())
        posix.close(fd)
        return -1
    }
    return fd
}

send_all :: proc(fd: posix.FD, data: []byte) -> bool {
    off := 0
    for off < len(data) {
        n := posix.send(fd, raw_data(data[off:]), cc.size_t(len(data[off:])), {.NOSIGNAL})
        if n > 0 { off += int(n); continue }
        if n < 0 && posix.errno() == .EINTR { continue }
        return false
    }
    return true
}

recv_exact :: proc(fd: posix.FD, data: []byte) -> bool {
    off := 0
    for off < len(data) {
        n := posix.recv(fd, raw_data(data[off:]), cc.size_t(len(data[off:])), {})
        if n > 0 { off += int(n); continue }
        if n < 0 && posix.errno() == .EINTR { continue }
        return false
    }
    return true
}

recv_frame :: proc(fd: posix.FD) -> (ipc.Ipc_Frame, bool) {
    head: [ipc.IPC_HEADER_BYTES]u8
    if !recv_exact(fd, head[:]) { return {}, false }
    if string(head[:len(ipc.IPC_MAGIC)]) != ipc.IPC_MAGIC { return {}, false }
    n := int(ipc.le_u32(head[6:10]))
    if n > ipc.IPC_MAX_PAYLOAD { return {}, false }
    payload := make([]byte, n)
    if n > 0 && !recv_exact(fd, payload) { delete(payload); return {}, false }
    return ipc.Ipc_Frame{typ = ipc.le_u32(head[10:14]), payload = payload}, true
}
