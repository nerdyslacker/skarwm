package audio

import "core:strings"

Verified_Process :: struct {
    PID: i64,
    Start_Time: u64,
    Executable: string,
}

Process_Ref :: struct {
    PID: i64,
    Start_Time: u64,
}

Window_Candidate :: struct {
    XID: u32,
    Process: Verified_Process,
    Eligible: bool,
}

Stream_Candidate :: struct {
    Index, Window_XID: u32,
    Process: Verified_Process,
    Ancestors: [32]Process_Ref,
    Ancestor_Count: u8,
    Valid: bool,
}

Application_Matches_Process :: proc(executable, binary, application_id: string) -> bool {
    if executable == "" { return false }
    binary_base := binary
    for i := len(binary_base)-1; i >= 0; i -= 1 {
        if binary_base[i] == '/' { binary_base = binary_base[i+1:]; break }
    }
    if binary_base != "" && strings.equal_fold(executable, binary_base) { return true }
    id := application_id
    if strings.has_suffix(id, ".desktop") { id = id[:len(id)-len(".desktop")] }
    for i := len(id)-1; i >= 0; i -= 1 {
        if id[i] == '.' || id[i] == '/' { id = id[i+1:]; break }
    }
    return id != "" && strings.equal_fold(executable, id)
}

Window_Model :: struct {
    Window_XID: u32,
    Stream_Indices: [dynamic]u32,
    Volume: u32,
    Muted, Mixed_Mute: bool,
}

process_equal :: proc(a, b: Verified_Process) -> bool {
    return a.PID > 0 && a.PID == b.PID && a.Start_Time != 0 && a.Start_Time == b.Start_Time &&
        a.Executable != "" && a.Executable == b.Executable
}

process_is_ancestor :: proc(process: Verified_Process, stream: Stream_Candidate) -> bool {
    if process.PID <= 0 || process.Start_Time == 0 { return false }
    for i in 0 ..< int(stream.Ancestor_Count) {
        ancestor := stream.Ancestors[i]
        if ancestor.PID == process.PID && ancestor.Start_Time == process.Start_Time { return true }
    }
    return false
}

// The verified process whose windows control this stream: the stream's own
// process when it owns a window, otherwise its nearest ancestor that does. A
// stream XID hint wins when it verifies, so a player that names its window is
// never attached to a launcher. only_xid restricts grouping to that window.
Match_Owner :: proc(stream: Stream_Candidate, windows: []Window_Candidate) -> (owner: Verified_Process, only_xid: u32, ok: bool) {
    if !stream.Valid { return }
    if stream.Window_XID != 0 {
        for window in windows {
            if window.XID == stream.Window_XID && window.Eligible &&
               (process_equal(stream.Process, window.Process) || process_is_ancestor(window.Process, stream)) {
                return window.Process, window.XID, true
            }
        }
    }
    for window in windows {
        if window.Eligible && process_equal(stream.Process, window.Process) { return stream.Process, 0, true }
    }
    for i in 0 ..< int(stream.Ancestor_Count) {
        ancestor := stream.Ancestors[i]
        for window in windows {
            if window.Eligible && window.Process.PID == ancestor.PID && window.Process.Start_Time != 0 &&
               window.Process.Start_Time == ancestor.Start_Time {
                return window.Process, 0, true
            }
        }
    }
    return {}, 0, false
}

stream_volume :: proc(stream: ^Stream) -> u32 {
    if stream == nil || stream.Channels == 0 { return 0 }
    total: u64
    for i in 0 ..< int(stream.Channels) { total += u64(stream.Volume[i]) }
    return u32(total/u64(stream.Channels))
}

Build_Window_Models :: proc(streams: []Stream, verified: []Stream_Candidate, windows: []Window_Candidate) -> [dynamic]Window_Model {
    models := make([dynamic]Window_Model, 0, 4)
    for &stream in streams {
        if !stream.Volume_Writable || stream.Channels == 0 { continue }
        candidate: ^Stream_Candidate
        for &item in verified { if item.Index == stream.Index { candidate = &item; break } }
        if candidate == nil { continue }
        owner, only_xid, matched := Match_Owner(candidate^, windows)
        if !matched { continue }
        // Every eligible window of the owning process is one application, so all
        // of them control the same stream.
        for window in windows {
            if !window.Eligible { continue }
            if only_xid != 0 { if window.XID != only_xid { continue } }
            else if !process_equal(owner, window.Process) { continue }
            model_index := -1
            for model, i in models { if model.Window_XID == window.XID { model_index = i; break } }
            if model_index < 0 {
                model := Window_Model{Window_XID = window.XID, Muted = stream.Muted}
                model.Stream_Indices = make([dynamic]u32, 0, 2)
                append(&models, model)
                model_index = len(models)-1
            }
            model := &models[model_index]
            append(&model.Stream_Indices, stream.Index)
            model.Volume = max(model.Volume, stream_volume(&stream))
            if model.Muted != stream.Muted { model.Mixed_Mute = true }
            model.Muted = model.Muted && stream.Muted
        }
    }
    return models
}

Free_Window_Models :: proc(models: ^[dynamic]Window_Model) {
    if models == nil { return }
    for &model in models { delete(model.Stream_Indices) }
    delete(models^)
    models^ = nil
}
