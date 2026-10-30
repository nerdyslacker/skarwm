package wm

import audio "../audio"
import c "../core"
import logger "../log"
import ui "../ui"
import x11 "../x11"

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

Audio_Window :: struct {
    XID: u32,
    Process: audio.Verified_Process,
    Valid, Eligible: bool,
}

Audio_Verified_Stream :: struct {
    Index: u32,
    Generation: u64,
    Candidate: audio.Stream_Candidate,
}

process_stat :: proc(pid: i64) -> (parent_pid: i64, start_time: u64, ok: bool) {
    path := fmt.tprintf("/proc/%d/stat", pid)
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil || len(data) == 0 { return 0, 0, false }
    text := string(data)
    close := -1
    for i := len(text)-1; i >= 0; i -= 1 { if text[i] == ')' { close = i; break } }
    if close < 0 || close+2 >= len(text) { return 0, 0, false }
    fields := text[close+2:]
    for index in 0 ..< 20 {
        field, found := strings.fields_iterator(&fields)
        if !found { return 0, 0, false }
        if index == 1 {
            value, parsed := strconv.parse_i64(field)
            if !parsed { return 0, 0, false }
            parent_pid = value
        }
        if index == 19 {
            value, parsed := strconv.parse_u64(field)
            return parent_pid, value, parsed && value != 0
        }
    }
    return 0, 0, false
}

process_start_time :: proc(pid: i64) -> (u64, bool) {
    _, start, ok := process_stat(pid)
    return start, ok
}

process_uid_matches :: proc(pid: i64) -> bool {
    path := fmt.tprintf("/proc/%d/status", pid)
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil { return false }
    lines := string(data)
    for {
        line, ok := strings.split_lines_iterator(&lines)
        if !ok { break }
        if !strings.has_prefix(line, "Uid:") { continue }
        fields := line
        _, _ = strings.fields_iterator(&fields)
        expected := u64(posix.getuid())
        for _ in 0 ..< 4 {
            field, found := strings.fields_iterator(&fields)
            if !found { return false }
            value, parsed := strconv.parse_u64(field)
            if !parsed || value != expected { return false }
        }
        return true
    }
    return false
}

path_base :: proc(path: string) -> string {
    for i := len(path)-1; i >= 0; i -= 1 { if path[i] == '/' { return path[i+1:] } }
    return path
}

read_process_identity :: proc(pid: i64) -> (audio.Verified_Process, bool) {
    when ODIN_OS != .Linux { return {}, false }
    if pid <= 0 || !process_uid_matches(pid) { return {}, false }
    before, ok := process_start_time(pid)
    if !ok { return {}, false }
    link, err := os.read_link(fmt.tprintf("/proc/%d/exe", pid), context.allocator)
    if err != nil || link == "" { return {}, false }
    defer delete(link)
    after, same := process_start_time(pid)
    if !same || before != after { return {}, false }
    executable := strings.clone(path_base(link))
    if executable == "" { return {}, false }
    return audio.Verified_Process{PID = pid, Start_Time = before, Executable = executable}, true
}

local_hostname :: proc() -> string {
    buf: [256]u8
    if posix.gethostname(&buf[0], len(buf)) != nil { return "" }
    n := 0
    for n < len(buf) && buf[n] != 0 { n += 1 }
    return strings.clone(string(buf[:n]))
}

local_machine_id :: proc() -> string {
    data, err := os.read_entire_file("/etc/machine-id", context.temp_allocator)
    if err != nil { return "" }
    value := strings.trim_space(string(data))
    return strings.clone(value)
}

free_window_meta :: proc(meta: ^Audio_Window) {
    if meta.Process.Executable != "" { delete(meta.Process.Executable) }
    meta^ = {}
}

free_stream_meta :: proc(meta: ^Audio_Verified_Stream) {
    if meta.Candidate.Process.Executable != "" { delete(meta.Candidate.Process.Executable) }
    meta^ = {}
}

audio_refresh_window :: proc(cl: ^c.Client) {
    if cl == nil || !g_wm.audio_state.Enabled { return }
    existing := -1
    for meta, i in g_wm.audio_windows { if meta.XID == cl.Xid { existing = i; break } }
    next := Audio_Window{XID = cl.Xid, Eligible = cl.Decorated && !cl.Dock}
    if pid, ok := x11.get_cardinal32(g_wm.conn, cl.Xid, atom("_NET_WM_PID"), atom("CARDINAL")); ok && pid > 0 {
        next.Process, next.Valid = read_process_identity(i64(pid))
    }
    if !next.Valid { logger.Debug("titlebar audio: window has no verifiable local process", cl.Xid, cl.Title) }
    if existing >= 0 { free_window_meta(&g_wm.audio_windows[existing]); g_wm.audio_windows[existing] = next }
    else { append(&g_wm.audio_windows, next) }
    g_wm.audio_mapping_dirty = true
}

audio_forget_window :: proc(xid: u32) {
    if g_wm.audio_pointer_client != nil && g_wm.audio_pointer_client.Xid == xid { cancel_pointer_operation() }
    for meta, i in g_wm.audio_windows {
        if meta.XID != xid { continue }
        free_window_meta(&g_wm.audio_windows[i])
        unordered_remove(&g_wm.audio_windows, i)
        g_wm.audio_mapping_dirty = true
        return
    }
}

audio_refresh_all_windows :: proc() {
    if !g_wm.audio_state.Enabled || g_wm.m == nil { return }
    for cl in g_wm.m.Clients { if !cl.Dock { audio_refresh_window(cl) } }
}

audio_mapping_init :: proc() {
    g_wm.audio_windows = make([dynamic]Audio_Window, 0, 16)
    g_wm.audio_streams = make([dynamic]Audio_Verified_Stream, 0, 8)
    g_wm.audio_models = make([dynamic]audio.Window_Model, 0, 4)
    g_wm.audio_host = local_hostname()
    g_wm.audio_machine_id = local_machine_id()
    g_wm.audio_mapping_dirty = true
    logger.Debug("titlebar audio: enabled for host", g_wm.audio_host)
    audio_refresh_all_windows()
}

audio_mapping_shutdown :: proc() {
    if g_wm.m != nil {
        for cl in g_wm.m.Clients { ui.Set_Decoration_Audio(&g_wm.ui, g_wm.m, cl, false, 0, false, false) }
    }
    for &meta in g_wm.audio_windows { free_window_meta(&meta) }
    for &meta in g_wm.audio_streams { free_stream_meta(&meta) }
    delete(g_wm.audio_windows)
    delete(g_wm.audio_streams)
    audio.Free_Window_Models(&g_wm.audio_models)
    if g_wm.audio_host != "" { delete(g_wm.audio_host) }
    if g_wm.audio_machine_id != "" { delete(g_wm.audio_machine_id) }
    g_wm.audio_windows, g_wm.audio_streams = nil, nil
    g_wm.audio_host, g_wm.audio_machine_id = "", ""
    g_wm.audio_seen_revision = 0
    g_wm.audio_mapping_dirty = false
}

parse_stream_xid :: proc(value: string) -> u32 {
    if value == "" { return 0 }
    parsed, ok := strconv.parse_u64(value)
    if !ok || parsed == 0 || parsed > u64(max(u32)) { return 0 }
    return u32(parsed)
}

find_application_process :: proc(stream: ^audio.Stream) -> (audio.Verified_Process, bool) {
    entries, err := os.read_directory_by_path("/proc", -1, context.temp_allocator)
    if err != nil { return {}, false }
    match: audio.Verified_Process
    for entry in entries {
        pid, parsed := strconv.parse_i64(entry.name)
        if !parsed || pid <= 1 { continue }
        process, ok := read_process_identity(pid)
        if !ok { continue }
        if !audio.Application_Matches_Process(process.Executable, stream.Process_Binary, stream.Application_ID) {
            delete(process.Executable)
            continue
        }
        if match.PID != 0 {
            delete(match.Executable)
            delete(process.Executable)
            return {}, false
        }
        match = process
    }
    return match, match.PID != 0
}

verified_stream :: proc(stream: ^audio.Stream) -> audio.Stream_Candidate {
    candidate := audio.Stream_Candidate{Index = stream.Index}
    if stream.Process_Host != "" && (g_wm.audio_host == "" || stream.Process_Host != g_wm.audio_host) {
        logger.Debug("titlebar audio: ignored non-local stream", stream.Index, stream.Process_Host)
        return candidate
    }
    if stream.Machine_ID != "" && g_wm.audio_machine_id != "" && stream.Machine_ID != g_wm.audio_machine_id {
        logger.Debug("titlebar audio: ignored stream from another machine", stream.Index)
        return candidate
    }
    process, ok := read_process_identity(stream.Process_ID)
    if stream.Process_ID <= 0 { process, ok = find_application_process(stream) }
    if !ok {
        logger.Debug("titlebar audio: ignored stream without one unique local process", stream.Index, stream.Application_ID)
        return candidate
    }
    identity_matches := audio.Application_Matches_Process(process.Executable, stream.Process_Binary, stream.Application_ID)
    if !identity_matches {
        logger.Debug("titlebar audio: ignored application identity mismatch", stream.Index, process.Executable, stream.Application_ID)
        delete(process.Executable)
        return candidate
    }
    candidate.Process = process
    candidate.Window_XID = parse_stream_xid(stream.Window_XID)
    pid := process.PID
    for candidate.Ancestor_Count < u8(len(candidate.Ancestors)) {
        parent, _, found := process_stat(pid)
        if !found || parent <= 1 || !process_uid_matches(parent) { break }
        _, before, stable := process_stat(parent)
        _, after, same := process_stat(parent)
        if !stable || !same || before != after { break }
        candidate.Ancestors[candidate.Ancestor_Count] = {PID = parent, Start_Time = before}
        candidate.Ancestor_Count += 1
        pid = parent
    }
    candidate.Valid = true
    logger.Debug("titlebar audio: verified stream", stream.Index, stream.Application_Name,
                 "pid", process.PID, "ancestors", candidate.Ancestor_Count)
    return candidate
}

audio_reconcile :: proc() {
    if !g_wm.audio_state.Enabled || (!g_wm.audio_mapping_dirty && g_wm.audio_seen_revision == g_wm.audio_state.Revision) { return }
    for i := len(g_wm.audio_streams)-1; i >= 0; i -= 1 {
        live := false
        for stream in g_wm.audio_state.Streams {
            if stream.Index == g_wm.audio_streams[i].Index && stream.Generation == g_wm.audio_streams[i].Generation { live = true; break }
        }
        if !live { free_stream_meta(&g_wm.audio_streams[i]); unordered_remove(&g_wm.audio_streams, i) }
    }
    for &stream in g_wm.audio_state.Streams {
        found := false
        for meta in g_wm.audio_streams {
            if meta.Index == stream.Index && meta.Generation == stream.Generation { found = true; break }
        }
        if !found {
            append(&g_wm.audio_streams, Audio_Verified_Stream{
                Index = stream.Index, Generation = stream.Generation, Candidate = verified_stream(&stream),
            })
        }
    }
    windows := make([]audio.Window_Candidate, len(g_wm.audio_windows), context.temp_allocator)
    for meta, i in g_wm.audio_windows {
        windows[i] = audio.Window_Candidate{XID = meta.XID, Process = meta.Process, Eligible = meta.Valid && meta.Eligible}
    }
    streams := make([]audio.Stream_Candidate, len(g_wm.audio_streams), context.temp_allocator)
    for meta, i in g_wm.audio_streams { streams[i] = meta.Candidate }
    audio.Free_Window_Models(&g_wm.audio_models)
    g_wm.audio_models = audio.Build_Window_Models(g_wm.audio_state.Streams[:], streams, windows)
    logger.Debug("titlebar audio: reconcile streams", len(g_wm.audio_state.Streams),
                 "windows", len(windows), "mapped", len(g_wm.audio_models))
    for cl in g_wm.m.Clients {
        model := audio_model_for_window(cl.Xid)
        if model == nil {
            if g_wm.audio_pointer_client == cl { cancel_pointer_operation() }
            ui.Set_Decoration_Audio(&g_wm.ui, g_wm.m, cl, false, 0, false, false)
        }
        else { ui.Set_Decoration_Audio(&g_wm.ui, g_wm.m, cl, true, model.Volume, model.Muted, model.Mixed_Mute) }
    }
    g_wm.audio_seen_revision = g_wm.audio_state.Revision
    g_wm.audio_mapping_dirty = false
}

audio_preview :: proc(cl: ^c.Client, volume: u32, toggle_mute: bool, final := true) {
    if cl == nil { return }
    model := audio_model_for_window(cl.Xid)
    if model == nil { return }
    target := min(volume, u32(65_536))
    reference := model.Volume
    desired_mute := !model.Muted
    for index in model.Stream_Indices {
        for &stream in g_wm.audio_state.Streams {
            if stream.Index != index { continue }
            if toggle_mute { _ = audio.Queue_Stream_Mute(&g_wm.audio_state, index, stream.Generation, desired_mute) }
            else { _ = audio.Queue_Stream_Volume(&g_wm.audio_state, index, stream.Generation, target, reference, final) }
            break
        }
    }
    model.Volume = target
    if toggle_mute { model.Muted = desired_mute; model.Mixed_Mute = false }
    ui.Set_Decoration_Audio(&g_wm.ui, g_wm.m, cl, true, model.Volume, model.Muted, model.Mixed_Mute)
}

audio_model_for_window :: proc(xid: u32) -> ^audio.Window_Model {
    for &model in g_wm.audio_models { if model.Window_XID == xid { return &model } }
    return nil
}
