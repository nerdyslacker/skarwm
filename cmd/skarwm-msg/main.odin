package main

// Small client for skarwm's i3-framed IPC subset. Queries print one JSON
// payload; `subscribe` keeps printing event payloads, one per line.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import ipc "../../src/core"

usage :: proc() {
    fmt.eprintln("usage: skarwm-msg [--socket PATH] COMMAND [ARGS...]")
    fmt.eprintln("queries: get-workspaces | get-windows | get-outputs | get-version")
    fmt.eprintln("events:  subscribe [workspace] [window] [output]")
    fmt.eprintln("actions: focus DIR | move DIR | workspace N|next|prev | move workspace N")
    fmt.eprintln("         layout tabbed|stacked|toggle | toggle-tabbed | show-bindings")
    fmt.eprintln("         reminder add MINUTES MESSAGE")
    fmt.eprintln("         scratchpad toggle|toggle-float|remove N")
    fmt.eprintln("         scratchpad target|target-float FIELD VALUE [--spawn COMMAND]")
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
    owned_path := false
    if path == "" { path = ipc.Ipc_Default_Socket_Path(); owned_path = true }
    defer if owned_path { delete(path) }

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

    fd := ipc.Ipc_Connect(path)
    if fd < 0 { fmt.eprintln("skarwm-msg: cannot connect to", path, ":", posix.errno()); os.exit(1) }
    defer posix.close(fd)

    frame := ipc.ipc_encode(typ, transmute([]u8)payload)
    defer delete(frame)
    if owned_payload { delete(payload) } // ipc_encode copied it into frame
    if !ipc.Ipc_Send_All(fd, frame) {
        fmt.eprintln("skarwm-msg: send failed:", posix.errno())
        os.exit(1)
    }

    for {
        reply, ok := ipc.Ipc_Recv_Frame(fd)
        if !ok { os.exit(1) }
        fmt.println(string(reply.payload))
        failed := typ == .Command && strings.contains(string(reply.payload), `"success":false`)
        delete(reply.payload)
        if failed { os.exit(1) }
        if !continuous { return }
    }
}
