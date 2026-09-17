package main

import protocol "../core"

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import cc "core:c"

ipc_start :: proc(state: ^State) -> bool {
    if state.IpcFd >= 0 { return true }
    path := protocol.Ipc_Default_Socket_Path()
    defer delete(path)
    fd := protocol.Ipc_Connect(path)
    if fd < 0 { return false }
    flags := posix.fcntl(fd, .GETFL)
    if flags >= 0 { posix.fcntl(fd, .SETFL, int(flags) | int(posix.O_NONBLOCK)) }
    posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
    state.IpcFd = fd
    if !ipc_send_request(state, .Subscribe, `["workspace","window","output"]`) ||
       !ipc_request_workspaces(state) {
        ipc_disconnect(state)
        return false
    }
    return true
}

ipc_disconnect :: proc(state: ^State) {
    if state.IpcFd >= 0 { posix.close(state.IpcFd) }
    state.IpcFd = -1
    protocol.Ipc_Reader_Reset(&state.IpcReader)
}

ipc_send_request :: proc(state: ^State, kind: protocol.Ipc_Type, payload: string) -> bool {
    if state.IpcFd < 0 { return false }
    frame := protocol.ipc_encode(kind, transmute([]u8)payload)
    defer delete(frame)
    return protocol.Ipc_Send_All(state.IpcFd, frame)
}

ipc_request_workspaces :: proc(state: ^State) -> bool {
    return ipc_send_request(state, .Get_Workspaces, "")
}

ipc_switch_workspace :: proc(state: ^State, output: string, id: int) {
    if state.IpcFd < 0 { return }
    command := fmt.aprintf("workspace %d output %s", id, output)
    ok := ipc_send_request(state, .Command, command)
    delete(command)
    if !ok { ipc_disconnect(state) }
}

ipc_service :: proc(state: ^State) -> bool {
    buffer: [8192]u8
    for {
        count := posix.recv(state.IpcFd, &buffer, cc.size_t(len(buffer)), {})
        if count > 0 {
            frames, valid := protocol.ipc_reader_feed(&state.IpcReader, buffer[:count])
            alive := true
            for frame in frames {
                if alive { alive = ipc_handle_frame(state, frame) }
                delete(frame.payload)
            }
            delete(frames)
            if !valid || !alive { return false }
            continue
        }
        if count == 0 { return false }
        error := posix.errno()
        if error == .EINTR { continue }
        if error == .EAGAIN { return true }
        return false
    }
}

ipc_handle_frame :: proc(state: ^State, frame: protocol.Ipc_Frame) -> bool {
    kind := protocol.Ipc_Type(frame.typ)
    #partial switch kind {
    case .Get_Workspaces:
        parse_workspace_snapshot(state, frame.payload)
        draw_all_bars(state)
    case .Event_Workspace, .Event_Window, .Event_Output:
        return ipc_request_workspaces(state)
    case:
    }
    return true
}

clear_workspaces :: proc(state: ^State) {
    for workspace in state.Workspaces {
        if workspace.Name != "" { delete(workspace.Name) }
        if workspace.Output != "" { delete(workspace.Output) }
    }
    delete(state.Workspaces)
    state.Workspaces = make([dynamic]Workspace_State, 0, 16)
}

find_json_field :: proc(object: []byte, name: string) -> int {
    for i := 0; i + len(name) + 3 <= len(object); i += 1 {
        if object[i] != '"' { continue }
        matches := true
        for character, j in name {
            if object[i + 1 + j] != u8(character) { matches = false; break }
        }
        end := i + 1 + len(name)
        if matches && end + 1 < len(object) && object[end] == '"' && object[end + 1] == ':' {
            return end + 2
        }
    }
    return -1
}

json_int_field :: proc(object: []byte, name: string) -> (int, bool) {
    position := find_json_field(object, name)
    if position < 0 { return 0, false }
    end := position
    if end < len(object) && object[end] == '-' { end += 1 }
    for end < len(object) && object[end] >= '0' && object[end] <= '9' { end += 1 }
    if end == position { return 0, false }
    value, ok := strconv.parse_i64(string(object[position:end]), 10)
    return int(value), ok
}

json_bool_field :: proc(object: []byte, name: string) -> bool {
    position := find_json_field(object, name)
    return position >= 0 && position + 4 <= len(object) && string(object[position:position + 4]) == "true"
}

json_string_field :: proc(object: []byte, name: string) -> (string, bool) {
    position := find_json_field(object, name)
    if position < 0 || position >= len(object) || object[position] != '"' { return "", false }
    position += 1
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    for position < len(object) {
        character := object[position]
        if character == '"' { return strings.clone(strings.to_string(builder)), true }
        if character == '\\' && position + 1 < len(object) {
            position += 1
            character = object[position]
            switch character {
            case 'n': character = '\n'
            case 'r': character = '\r'
            case 't': character = '\t'
            }
        }
        strings.write_byte(&builder, character)
        position += 1
    }
    return "", false
}

parse_workspace_object :: proc(state: ^State, object: []byte) {
    id, id_ok := json_int_field(object, "id")
    windows, _ := json_int_field(object, "windows")
    name, name_ok := json_string_field(object, "name")
    output, output_ok := json_string_field(object, "output")
    if !id_ok || !name_ok || !output_ok {
        if name != "" { delete(name) }
        if output != "" { delete(output) }
        return
    }
    append(&state.Workspaces, Workspace_State{
        Id = id, Name = name, Output = output,
        Active = json_bool_field(object, "visible"),
        Occupied = windows > 0,
        Urgent = json_bool_field(object, "urgent"),
    })
}

parse_workspace_snapshot :: proc(state: ^State, payload: []byte) {
    clear_workspaces(state)
    depth := 0
    start := -1
    in_string := false
    escaped := false
    for character, index in payload {
        if in_string {
            if escaped { escaped = false; continue }
            if character == '\\' { escaped = true; continue }
            if character == '"' { in_string = false }
            continue
        }
        if character == '"' { in_string = true; continue }
        if character == '{' {
            if depth == 0 { start = index }
            depth += 1
        } else if character == '}' {
            depth -= 1
            if depth == 0 && start >= 0 {
                parse_workspace_object(state, payload[start:index + 1])
                start = -1
            }
        }
    }
}
