package core

// i3-compatible IPC subset used by Quickshell's X11 bar (GET_WORKSPACES /
// GET_OUTPUTS / SUBSCRIBE /
// RUN_COMMAND plus skarwm window queries). Pure: builds JSON payloads and
// reassembles/validates request frames, with no X or socket dependency — the
// socket server (src/ipc.odin, package main) does the I/O.
//
// JSON is hand-rolled in fixed key order to avoid another runtime dependency.
// The consumer's JSON parser validates the result, so the format only needs to
// be valid JSON with the documented i3 fields.
//
// Wire frame (i3-ipc protocol):
//     magic "i3-ipc" (6 bytes) | payload length u32le | message type u32le | payload
// Standard client→WM types are 0..3, skarwm extensions are 100+, and
// WM→client events carry bit 0x80000000.

import "core:strings"

IPC_MAGIC :: "i3-ipc"
IPC_HEADER_BYTES :: 14 // magic 6 + length 4 + type 4
// Sanity cap for a payload length field. i3 does not limit payloads; we drop
// a connection whose declared length exceeds this instead of buffering it.
IPC_MAX_PAYLOAD :: 1 << 20
IPC_MAX_WORKSPACE_ID :: 4096 // matches the EWMH desktop-property safety cap

Ipc_Type :: enum u32 {
    // requests (client → WM)
    Command         = 0, // RUN_COMMAND
    Get_Workspaces  = 1, // GET_WORKSPACES
    Subscribe       = 2, // SUBSCRIBE
    Get_Outputs     = 3, // GET_OUTPUTS
    // skarwm extensions. Keeping them outside i3's assigned range lets i3
    // clients safely ignore them while skarwm-msg can expose richer state.
    Get_Windows     = 100,
    Get_Version     = 101,
    // events (WM → client): the event bit is set in the type field
    Event_Workspace = 0x80000000,
    Event_Output    = 0x80000001,
    Event_Window    = 0x80000003,
}

// The workspace-event "change" values skarwm emits (i3 semantics).
IPC_CHANGE_INIT  :: "init" // a workspace was created (switch to a new id)
IPC_CHANGE_FOCUS :: "focus" // the current workspace changed
IPC_CHANGE_EMPTY :: "empty" // the last window left a workspace

IPC_WINDOW_NEW   :: "new"
IPC_WINDOW_CLOSE :: "close"
IPC_WINDOW_FOCUS :: "focus"
IPC_WINDOW_TITLE :: "title"
IPC_WINDOW_URGENT :: "urgent"
IPC_WINDOW_LAYOUT :: "layout"

Ipc_Action :: enum {
    Invalid,
    Focus_Left, Focus_Right, Focus_Up, Focus_Down,
    Move_Left, Move_Right, Move_Up, Move_Down,
    Workspace, Workspace_Next, Workspace_Prev,
    Move_To_Workspace, Move_To_Workspace_Next, Move_To_Workspace_Prev,
    Toggle_Floating, Toggle_Fullscreen,
    Layout_Tabbed, Layout_Stacked, Layout_Toggle,
    Show_Bindings,
    Focus_Output_Next, Focus_Output_Prev,
    Move_To_Output_Next, Move_To_Output_Prev,
    Close, Reload, Quit,
}

Ipc_Command :: struct {
    action: Ipc_Action,
    arg:    int,
}

// A decoded request frame. payload is an owned copy (delete it after use, and
// delete the frame list itself).
Ipc_Frame :: struct {
    typ:     u32,
    payload: []byte, // may be empty; requests carry no payload at all rarely
}

// ---------------------------------------------------------------------------
// framing
// ---------------------------------------------------------------------------

le_u32 :: proc(b: []byte) -> u32 {
    return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

put_le_u32 :: proc(b: []byte, v: u32) {
    b[0] = u8(v)
    b[1] = u8(v >> 8)
    b[2] = u8(v >> 16)
    b[3] = u8(v >> 24)
}

// ipc_encode frames a payload as one i3-ipc message. Returns an owned buffer
// (delete it). A nil/empty payload gives a zero-length body, which is what i3
// replies to message types it does not implement.
ipc_encode :: proc(typ: Ipc_Type, payload: []byte) -> []byte {
    out := make([]byte, IPC_HEADER_BYTES + len(payload))
    copy(out, IPC_MAGIC)
    put_le_u32(out[6:10], u32(len(payload)))
    put_le_u32(out[10:14], u32(typ))
    if len(payload) > 0 { copy(out[IPC_HEADER_BYTES:], payload) }
    return out
}

// Ipc_Reader reassembles the byte stream of one socket into request frames.
// It owns its buffer, which always starts at a frame boundary: partial frames
// wait in the buffer for the next feed, complete frames come out as owned
// payload copies.
Ipc_Reader :: struct {
    buf: []byte, // owned allocation (never interior-sliced)
    off: int, // bytes of buf already parsed out (<= len(buf))
}

ipc_reader_feed :: proc(r: ^Ipc_Reader, data: []byte) -> (frames: [dynamic]Ipc_Frame, ok: bool) {
    frames = make([dynamic]Ipc_Frame, 0, 2)
    // Drop parsed bytes, then append the new data.
    if r.off > 0 {
        n := len(r.buf) - r.off
        if n <= 0 {
            delete(r.buf)
            r.buf = nil
        } else {
            keep := make([]byte, n)
            copy(keep, r.buf[r.off:])
            delete(r.buf)
            r.buf = keep
        }
        r.off = 0
    }
    if len(data) > 0 {
        joined := make([]byte, len(r.buf) + len(data))
        copy(joined, r.buf)
        copy(joined[len(r.buf):], data)
        delete(r.buf)
        r.buf = joined
    }

    ok = true
    for ok {
        avail := r.buf[r.off:]
        n := len(avail)
        if n < IPC_HEADER_BYTES { break } // wait for a full header
        if string(avail[0:len(IPC_MAGIC)]) != IPC_MAGIC { ok = false; break }
        plen := int(le_u32(avail[6:10]))
        if plen > IPC_MAX_PAYLOAD { ok = false; break }
        if n < IPC_HEADER_BYTES + plen { break } // partial payload: wait
        payload := make([]byte, plen)
        if plen > 0 { copy(payload, avail[IPC_HEADER_BYTES:IPC_HEADER_BYTES + plen]) }
        append(&frames, Ipc_Frame{typ = le_u32(avail[10:14]), payload = payload})
        r.off += IPC_HEADER_BYTES + plen
    }
    return frames, ok
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

is_json_ws :: proc(b: u8) -> bool {
    return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// ipc_json_string appends s as a JSON string literal (escapes " \ and control
// characters). Every string skarwm emits is safe ASCII today, but the helper
// keeps the escaping in one place (and is unit-tested).
ipc_json_string :: proc(sb: ^strings.Builder, s: string) {
    hex := "0123456789abcdef"
    strings.write_string(sb, "\"")
    for i in 0 ..< len(s) {
        b := s[i] // bytes; multibyte UTF-8 passes through as raw bytes (>= 0x20)
        switch b {
        case '"':
            strings.write_string(sb, "\\\"")
        case '\\':
            strings.write_string(sb, "\\\\")
        case '\n':
            strings.write_string(sb, "\\n")
        case '\r':
            strings.write_string(sb, "\\r")
        case '\t':
            strings.write_string(sb, "\\t")
        case:
            if b < 0x20 { // \u00XX (control bytes; multibyte UTF-8 is >= 0x20)
                strings.write_string(sb, "\\u00")
                strings.write_byte(sb, hex[b >> 4])
                strings.write_byte(sb, hex[b & 0x0F])
            } else {
                strings.write_byte(sb, b)
            }
        }
    }
    strings.write_string(sb, "\"")
}

// json_bool appends a JSON boolean. (The JSON emitters deliberately never use
// fmt format strings: Odin's fmt treats '{' as an auto-format placeholder, so
// brace-heavy formats would corrupt the output.)
json_bool :: proc(sb: ^strings.Builder, v: bool) {
    if v {
        strings.write_string(sb, "true")
    } else {
        strings.write_string(sb, "false")
    }
}

// json_int appends an i32 JSON number.
json_int :: proc(sb: ^strings.Builder, v: i32) {
    strings.write_i64(sb, i64(v))
}

// sb_bytes copies the builder's contents into an owned byte slice.
sb_bytes :: proc(sb: ^strings.Builder) -> []byte {
    s := strings.to_string(sb^)
    out := make([]byte, len(s))
    copy(out, s)
    return out
}

// ---------------------------------------------------------------------------
// GET_WORKSPACES / events: the workspace object
// ---------------------------------------------------------------------------

// ipc_ws_entry appends one workspace object in the shape i3's GET_WORKSPACES
// reply and workspace events carry. A workspace is visible when it is current
// on its output, but it is focused only when that output is active. The
// workspace id doubles as num and as its decimal name.
ipc_ws_entry :: proc(sb: ^strings.Builder, m: ^Manager, o: ^Output, ws: ^Workspace) {
    on := o.Current == ws
    strings.write_string(sb, `{"id":`)
    strings.write_int(sb, ws.Id)
    strings.write_string(sb, `,"num":`)
    strings.write_int(sb, ws.Id)
    strings.write_string(sb, `,"name":"`)
    strings.write_int(sb, ws.Id)
    strings.write_string(sb, `","visible":`)
    json_bool(sb, on && o == Active_Output(m))
    strings.write_string(sb, `,"focused":`)
    json_bool(sb, on)
    strings.write_string(sb, `,"urgent":`)
    json_bool(sb, workspace_urgent(ws))
    strings.write_string(sb, `,"rect":{"x":`)
    json_int(sb, o.Geom.X)
    strings.write_string(sb, `,"y":`)
    json_int(sb, o.Geom.Y)
    strings.write_string(sb, `,"width":`)
    json_int(sb, o.Geom.W)
    strings.write_string(sb, `,"height":`)
    json_int(sb, o.Geom.H)
    strings.write_string(sb, `},"output":`)
    ipc_json_string(sb, o.Name)
    strings.write_string(sb, `,"windows":`)
    strings.write_int(sb, workspace_window_count(ws))
    strings.write_string(sb, "}")
}

workspace_urgent :: proc(ws: ^Workspace) -> bool {
    if ws == nil { return false }
    for cl in ws.Floaters { if cl.Urgent { return true } }
    for col in ws.Cols { for cl in col.Wins { if cl.Urgent { return true } } }
    return false
}

workspace_window_count :: proc(ws: ^Workspace) -> int {
    if ws == nil { return 0 }
    n := len(ws.Floaters)
    for col in ws.Cols { n += len(col.Wins) }
    return n
}

// ipc_workspaces_payload renders the GET_WORKSPACES body: one entry per
// existing workspace in id order. Empty workspaces are included — skarwm
// keeps them alive, so they exist from the moment they are created.
ipc_workspaces_payload :: proc(m: ^Manager) -> []byte {
    o := Active_Output(m)
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, "[")
    if o != nil {
        for ws, i in o.Ws {
            if i > 0 { strings.write_string(&sb, ",") }
            ipc_ws_entry(&sb, m, o, ws)
        }
    }
    strings.write_string(&sb, "]")
    return sb_bytes(&sb)
}

// ipc_ws_event_payload renders one workspace-event body. change is one of
// IPC_CHANGE_*; cur/old are the affected workspace objects, rendered as null
// when absent (there is no "old" for an init or an empty).
ipc_ws_event_payload :: proc(m: ^Manager, change: string, cur: ^Workspace, old: ^Workspace) -> []byte {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, `{"change":`)
    ipc_json_string(&sb, change)
    strings.write_string(&sb, `,"current":`)
    cur_o := Output_Of_WS(m, cur)
    old_o := Output_Of_WS(m, old)
    if cur_o != nil && cur != nil {
        ipc_ws_entry(&sb, m, cur_o, cur)
    } else {
        strings.write_string(&sb, "null")
    }
    strings.write_string(&sb, `,"old":`)
    if old_o != nil && old != nil {
        ipc_ws_entry(&sb, m, old_o, old)
    } else {
        strings.write_string(&sb, "null")
    }
    strings.write_string(&sb, "}")
    return sb_bytes(&sb)
}

// ---------------------------------------------------------------------------
// GET_OUTPUTS
// ---------------------------------------------------------------------------

ipc_output_entry :: proc(sb: ^strings.Builder, m: ^Manager, o: ^Output) {
    strings.write_string(sb, `{"name":`)
    ipc_json_string(sb, o.Name)
    strings.write_string(sb, `,"active":true,"primary":`)
    json_bool(sb, o.Primary)
    strings.write_string(sb, `,"focused":`)
    json_bool(sb, o == Active_Output(m))
    strings.write_string(sb, `,"rect":{"x":`)
    json_int(sb, o.Geom.X)
    strings.write_string(sb, `,"y":`)
    json_int(sb, o.Geom.Y)
    strings.write_string(sb, `,"width":`)
    json_int(sb, o.Geom.W)
    strings.write_string(sb, `,"height":`)
    json_int(sb, o.Geom.H)
    strings.write_string(sb, `},"current_workspace":`)
    if o.Current != nil {
        strings.write_string(sb, `"`)
        strings.write_int(sb, o.Current.Id)
        strings.write_string(sb, `"`)
    } else {
        strings.write_string(sb, "null")
    }
    strings.write_string(sb, `,"power":true,"scale":1}`)
}

// ipc_outputs_payload renders every connected monitor in RandR discovery
// order, including its independent current workspace.
ipc_outputs_payload :: proc(m: ^Manager) -> []byte {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, "[")
    for o, i in m.Outputs {
        if i > 0 { strings.write_string(&sb, ",") }
        ipc_output_entry(&sb, m, o)
    }
    strings.write_string(&sb, "]")
    return sb_bytes(&sb)
}

ipc_output_event_payload :: proc(change, output: string) -> []byte {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, `{"change":`)
    ipc_json_string(&sb, change)
    strings.write_string(&sb, `,"output":`)
    ipc_json_string(&sb, output)
    strings.write_string(&sb, "}")
    return sb_bytes(&sb)
}

// ---------------------------------------------------------------------------
// GET_WINDOWS / window events (skarwm extension)
// ---------------------------------------------------------------------------

ipc_window_entry :: proc(sb: ^strings.Builder, m: ^Manager, cl: ^Client) {
    strings.write_string(sb, `{"id":`)
    strings.write_u64(sb, u64(cl.Xid))
    strings.write_string(sb, `,"title":`)
    ipc_json_string(sb, cl.Title)
    strings.write_string(sb, `,"class":`)
    ipc_json_string(sb, cl.Class)
    strings.write_string(sb, `,"instance":`)
    ipc_json_string(sb, cl.Instance)
    strings.write_string(sb, `,"workspace":`)
    if cl.Ws == nil { strings.write_string(sb, "null") } else { strings.write_int(sb, cl.Ws.Id) }
    strings.write_string(sb, `,"output":`)
    if cl.Out == nil { strings.write_string(sb, "null") } else { ipc_json_string(sb, cl.Out.Name) }
    strings.write_string(sb, `,"focused":`)
    json_bool(sb, m.Focused == cl)
    strings.write_string(sb, `,"floating":`)
    json_bool(sb, cl.Floating)
    strings.write_string(sb, `,"fullscreen":`)
    json_bool(sb, cl.Fullscreen)
    strings.write_string(sb, `,"urgent":`)
    json_bool(sb, cl.Urgent)
    ci, col, row := column_of(cl.Ws, cl)
    strings.write_string(sb, `,"column":`)
    if ci < 0 { strings.write_string(sb, "null") } else { strings.write_int(sb, ci) }
    strings.write_string(sb, `,"column_layout":`)
    if col == nil {
        strings.write_string(sb, "null")
    } else if col.Layout == .Tabbed {
        strings.write_string(sb, `"tabbed"`)
    } else {
        strings.write_string(sb, `"stacked"`)
    }
    strings.write_string(sb, `,"tab_index":`)
    if row < 0 { strings.write_string(sb, "null") } else { strings.write_int(sb, row) }
    strings.write_string(sb, `,"tab_count":`)
    if col == nil { strings.write_int(sb, 0) } else { strings.write_int(sb, len(col.Wins)) }
    strings.write_string(sb, `,"tab_active":`)
    json_bool(sb, col != nil && col.Layout == .Tabbed && col.Focus == cl)
    strings.write_string(sb, `,"dock":`)
    json_bool(sb, cl.Dock)
    strings.write_string(sb, `,"rect":{"x":`)
    json_int(sb, cl.Geom.X)
    strings.write_string(sb, `,"y":`)
    json_int(sb, cl.Geom.Y)
    strings.write_string(sb, `,"width":`)
    json_int(sb, cl.Geom.W)
    strings.write_string(sb, `,"height":`)
    json_int(sb, cl.Geom.H)
    strings.write_string(sb, "}}")
}

ipc_windows_payload :: proc(m: ^Manager) -> []byte {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, `{"version":1,"windows":[`)
    for cl, i in m.Clients {
        if i > 0 { strings.write_string(&sb, ",") }
        ipc_window_entry(&sb, m, cl)
    }
    strings.write_string(&sb, "]}")
    return sb_bytes(&sb)
}

ipc_window_event_payload :: proc(m: ^Manager, change: string, cl: ^Client) -> []byte {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, `{"change":`)
    ipc_json_string(&sb, change)
    strings.write_string(&sb, `,"container":`)
    if cl == nil { strings.write_string(&sb, "null") } else { ipc_window_entry(&sb, m, cl) }
    strings.write_string(&sb, "}")
    return sb_bytes(&sb)
}

ipc_version_payload :: proc() -> []byte {
    s := `{"human_readable":"skarwm","loaded_config_file_name":null,"major":0,"minor":1,"patch":0,"protocol":"i3-ipc+skarwm-v1"}`
    out := make([]byte, len(s))
    copy(out, s)
    return out
}

// ---------------------------------------------------------------------------
// RUN_COMMAND replies
// ---------------------------------------------------------------------------

// ipc_command_reply_payload renders the RUN_COMMAND reply body: a one-element
// array holding success, plus the error text when the command was rejected.
ipc_command_reply_payload :: proc(success: bool, err: string) -> []byte {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    if success {
        strings.write_string(&sb, `[{"success":true}]`)
    } else {
        strings.write_string(&sb, `[{"success":false,"error":`)
        ipc_json_string(&sb, err)
        strings.write_string(&sb, "}]")
    }
    return sb_bytes(&sb)
}

// ---------------------------------------------------------------------------
// request parsing
// ---------------------------------------------------------------------------

// ipc_parse_subscribe validates a SUBSCRIBE payload: a JSON array of quoted
// event names. Any name is accepted (i3 replies success to unknown names too;
// skarwm simply never emits the events behind them). Returns which of the two
// event kinds skarwm does emit — workspace / output — were requested, and ok
// = false for malformed payloads (non-array, unquoted tokens, trailing junk).
ipc_parse_subscribe :: proc(data: []byte) -> (workspace: bool, output: bool, window: bool, ok: bool) {
    n := len(data)
    p := 0
    for p < n && is_json_ws(data[p]) { p += 1 }
    if p >= n || data[p] != '[' { return false, false, false, false }
    p += 1

    ws, out, win := false, false, false
    expecting_name := true
    seen_name := false
    after_comma := false
    for p < n {
        c := data[p]
        if expecting_name {
            if is_json_ws(c) { p += 1; continue }
            if c == ']' { // only valid for the genuinely empty list
                if seen_name || after_comma { return false, false, false, false }
                p += 1
                for p < n && is_json_ws(data[p]) { p += 1 }
                if p != n { return false, false, false, false }
                return ws, out, win, true
            }
            if c != '"' { return false, false, false, false }
            p += 1
            start := p
            for p < n && data[p] != '"' {
                if data[p] == '\\' && p + 1 < n { p += 1 }
                p += 1
            }
            if p >= n { return false, false, false, false } // unterminated string
            name := string(data[start:p])
            seen_name = true
            after_comma = false
            p += 1 // closing quote
            switch name {
            case "workspace": ws = true
            case "output":    out = true
            case "window":    win = true
            }
            expecting_name = false
        } else {
            if is_json_ws(c) { p += 1; continue }
            if c == ',' { p += 1; expecting_name = true; after_comma = true; continue }
            if c == ']' {
                p += 1
                for p < n && is_json_ws(data[p]) { p += 1 }
                if p != n { return false, false, false, false }
                return ws, out, win, true
            }
            return false, false, false, false
        }
    }
    return false, false, false, false // never closed
}

// ipc_parse_command parses the compact command language shared by RUN_COMMAND
// and skarwm-msg. It intentionally does not accept i3 criteria or command
// chains; every request is one atomic action.
//
// No core:fmt on purpose: the JSON builders above already avoid format
// strings because this Odin build's fmt mangles them (see ipc_json_string),
// and the error text below is a fixed prefix plus the token — trivially
// assembled with the strings builder.
ipc_parse_command :: proc(data: []byte) -> (cmd: Ipc_Command, err: string, ok: bool) {
    n := len(data)
    // tokenize on whitespace
    tokens: [dynamic]string
    defer delete(tokens)
    p := 0
    for p < n {
        for p < n && is_json_ws(data[p]) { p += 1 }
        if p >= n { break }
        start := p
        for p < n && !is_json_ws(data[p]) { p += 1 }
        append(&tokens, string(data[start:p]))
    }

    if len(tokens) == 2 {
        dir: Ipc_Action
        switch tokens[0] {
        case "focus":
            switch tokens[1] {
            case "left":  dir = .Focus_Left
            case "right": dir = .Focus_Right
            case "up":    dir = .Focus_Up
            case "down":  dir = .Focus_Down
            }
        case "move":
            switch tokens[1] {
            case "left":  dir = .Move_Left
            case "right": dir = .Move_Right
            case "up":    dir = .Move_Up
            case "down":  dir = .Move_Down
            }
        }
        if dir != .Invalid { return Ipc_Command{action = dir}, "", true }
    }

    if len(tokens) == 3 && tokens[1] == "output" {
        if tokens[0] == "focus" {
            if tokens[2] == "next" { return Ipc_Command{action = .Focus_Output_Next}, "", true }
            if tokens[2] == "prev" || tokens[2] == "previous" { return Ipc_Command{action = .Focus_Output_Prev}, "", true }
        } else if tokens[0] == "move" {
            if tokens[2] == "next" { return Ipc_Command{action = .Move_To_Output_Next}, "", true }
            if tokens[2] == "prev" || tokens[2] == "previous" { return Ipc_Command{action = .Move_To_Output_Prev}, "", true }
        }
    }

    if len(tokens) == 1 {
        action: Ipc_Action
        switch tokens[0] {
        case "reload":            action = .Reload
        case "quit":              action = .Quit
        case "close":             action = .Close
        case "toggle-floating":   action = .Toggle_Floating
        case "toggle-fullscreen": action = .Toggle_Fullscreen
        case "toggle-tabbed":     action = .Layout_Toggle
        case "show-bindings":     action = .Show_Bindings
        }
        if action != .Invalid { return Ipc_Command{action = action}, "", true }
    }

    if len(tokens) == 2 && tokens[0] == "layout" {
        switch tokens[1] {
        case "tabbed":           return Ipc_Command{action = .Layout_Tabbed}, "", true
        case "stacked", "stacking": return Ipc_Command{action = .Layout_Stacked}, "", true
        case "toggle":           return Ipc_Command{action = .Layout_Toggle}, "", true
        }
    }

    num: string
    action := Ipc_Action.Invalid
    if len(tokens) == 2 && tokens[0] == "workspace" {
        if tokens[1] == "next" { return Ipc_Command{action = .Workspace_Next}, "", true }
        if tokens[1] == "prev" { return Ipc_Command{action = .Workspace_Prev}, "", true }
        num, action = tokens[1], .Workspace
    } else if len(tokens) == 3 && tokens[0] == "workspace" && tokens[1] == "number" {
        num, action = tokens[2], .Workspace
    } else if len(tokens) == 3 && tokens[0] == "move" && tokens[1] == "workspace" {
        if tokens[2] == "next" { return Ipc_Command{action = .Move_To_Workspace_Next}, "", true }
        if tokens[2] == "prev" || tokens[2] == "previous" { return Ipc_Command{action = .Move_To_Workspace_Prev}, "", true }
        num, action = tokens[2], .Move_To_Workspace
    } else {
        return {}, strings.clone("unknown command"), false
    }

    // every character of the argument must be a digit
    id := 0
    for ch in num {
        if ch < '0' || ch > '9' {
            sb := strings.builder_make()
            strings.write_string(&sb, "workspace: expected a workspace number, got \"")
            strings.write_string(&sb, num)
            strings.write_string(&sb, "\"")
            e := strings.clone(strings.to_string(sb))
            strings.builder_destroy(&sb)
            return {}, e, false
        }
        id = id * 10 + int(ch - '0')
        if id > IPC_MAX_WORKSPACE_ID {
            return {}, strings.clone("workspace: id must be <= 4096"), false
        }
    }
    if id < 1 {
        return {}, strings.clone("workspace: id must be >= 1"), false
    }
    return Ipc_Command{action = action, arg = id}, "", true
}
