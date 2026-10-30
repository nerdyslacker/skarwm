package audio

Verified_Process :: struct {
    PID: i64,
    Start_Time: u64,
    Executable: string,
}

Window_Candidate :: struct {
    XID: u32,
    Process: Verified_Process,
    Eligible: bool,
}

Stream_Candidate :: struct {
    Index, Window_XID: u32,
    Process: Verified_Process,
    Valid: bool,
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

Match_Window :: proc(stream: Stream_Candidate, windows: []Window_Candidate) -> u32 {
    if !stream.Valid { return 0 }
    if stream.Window_XID != 0 {
        for window in windows {
            if window.XID == stream.Window_XID && window.Eligible && process_equal(stream.Process, window.Process) {
                return window.XID
            }
        }
        return 0
    }
    match: u32
    for window in windows {
        if !window.Eligible || !process_equal(stream.Process, window.Process) { continue }
        if match != 0 { return 0 }
        match = window.XID
    }
    return match
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
        xid := Match_Window(candidate^, windows)
        if xid == 0 { continue }
        model_index := -1
        for model, i in models { if model.Window_XID == xid { model_index = i; break } }
        if model_index < 0 {
            model := Window_Model{Window_XID = xid, Muted = stream.Muted}
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
    return models
}

Free_Window_Models :: proc(models: ^[dynamic]Window_Model) {
    if models == nil { return }
    for &model in models { delete(model.Stream_Indices) }
    delete(models^)
    models^ = nil
}
