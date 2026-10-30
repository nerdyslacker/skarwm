package audio

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

PULSE_SUBSCRIPTION_MASK_SINK_INPUT :: u32(0x0004)
PULSE_SUBSCRIPTION_EVENT_SINK_INPUT :: i32(0x0002)
PULSE_SUBSCRIPTION_EVENT_REMOVE :: i32(0x0020)
PULSE_SUBSCRIPTION_EVENT_FACILITY_MASK :: i32(0x000f)
PULSE_SUBSCRIPTION_EVENT_TYPE_MASK :: i32(0x0030)
PULSE_CONTEXT_NOAUTOSPAWN :: u32(0x0001)

Stream :: struct {
    Index, Client: u32,
    Generation: u64,
    Process_ID: i64,
    Application_ID, Application_Name, Process_Binary, Process_Host, Machine_ID, Window_XID: string,
    Channels: u8,
    Volume: [32]u32,
    Muted, Corked, Volume_Writable: bool,
}

Index_Version :: struct { Index: u32, Serial: u64 }

IO_Event :: struct {
    Owner: ^State,
    FD: i32,
    Flags: i32,
    Callback: Pulse_IO_CB,
    Destroy: Pulse_IO_Destroy_CB,
    Userdata: rawptr,
    Alive: bool,
}

Time_Event :: struct {
    Owner: ^State,
    Deadline: time.Tick,
    Value: posix.timeval,
    Callback: Pulse_Time_CB,
    Destroy: Pulse_Time_Destroy_CB,
    Userdata: rawptr,
    Alive, Enabled: bool,
}

Defer_Event :: struct {
    Owner: ^State,
    Callback: Pulse_Defer_CB,
    Destroy: Pulse_Defer_Destroy_CB,
    Userdata: rawptr,
    Alive, Enabled: bool,
}

Request :: struct {
    Owner: ^State,
    Context: ^Pulse_Context,
    Epoch, Serial: u64,
    Index: u32,
    List: bool,
}

State :: struct {
    Enabled, Available, Connected: bool,
    Revision, Epoch, Serial, Next_Generation: u64,
    Symbols: Pulse_Symbols,
    API: Pulse_Mainloop_API,
    Context: ^Pulse_Context,
    Streams: [dynamic]Stream,
    Versions: [dynamic]Index_Version,
    IO: [dynamic]^IO_Event,
    Times: [dynamic]^Time_Event,
    Defers: [dynamic]^Defer_Event,
    Requests: [dynamic]^Request,
    Poll_Events: [dynamic]^IO_Event,
    Reset_Pending: bool,
    Reconnect_Due: time.Tick,
    Reconnect_Delay_Ms: i32,
    Odin_Context: runtime.Context,
}

clone_cstring :: proc(value: cstring) -> string {
    if value == nil { return "" }
    return strings.clone(string(value))
}

free_stream :: proc(stream: ^Stream) {
    if stream.Application_ID != "" { delete(stream.Application_ID) }
    if stream.Application_Name != "" { delete(stream.Application_Name) }
    if stream.Process_Binary != "" { delete(stream.Process_Binary) }
    if stream.Process_Host != "" { delete(stream.Process_Host) }
    if stream.Machine_ID != "" { delete(stream.Machine_ID) }
    if stream.Window_XID != "" { delete(stream.Window_XID) }
    stream^ = {}
}

Clear_Streams :: proc(state: ^State) {
    for &stream in state.Streams { free_stream(&stream) }
    clear(&state.Streams)
    clear(&state.Versions)
    state.Revision += 1
}

stream_index :: proc(state: ^State, index: u32) -> int {
    for stream, i in state.Streams { if stream.Index == index { return i } }
    return -1
}

version_index :: proc(state: ^State, index: u32) -> int {
    for version, i in state.Versions { if version.Index == index { return i } }
    return -1
}

Stream_Event_Serial :: proc(state: ^State, index: u32) -> u64 {
    i := version_index(state, index)
    return state.Versions[i].Serial if i >= 0 else 0
}

Note_Stream_Event :: proc(state: ^State, index: u32) -> u64 {
    state.Serial += 1
    i := version_index(state, index)
    if i >= 0 { state.Versions[i].Serial = state.Serial }
    else { append(&state.Versions, Index_Version{Index = index, Serial = state.Serial}) }
    return state.Serial
}

Remove_Stream :: proc(state: ^State, index: u32) {
    i := stream_index(state, index)
    if i < 0 { return }
    free_stream(&state.Streams[i])
    unordered_remove(&state.Streams, i)
    state.Revision += 1
}

Replace_Stream :: proc(state: ^State, stream: Stream) {
    next := stream
    i := stream_index(state, stream.Index)
    if i >= 0 {
        old := &state.Streams[i]
        same_identity := old.Process_ID == stream.Process_ID && old.Process_Binary == stream.Process_Binary &&
            old.Process_Host == stream.Process_Host && old.Machine_ID == stream.Machine_ID && old.Window_XID == stream.Window_XID
        if same_identity { next.Generation = old.Generation }
        free_stream(&state.Streams[i])
        state.Streams[i] = next
    } else {
        append(&state.Streams, next)
    }
    state.Revision += 1
}

prop :: proc(state: ^State, list: ^Pulse_Proplist, key: cstring) -> string {
    if list == nil { return "" }
    return clone_cstring(state.Symbols.proplist_gets(list, key))
}

stream_from_info :: proc(state: ^State, info: ^Pulse_Sink_Input_Info) -> Stream {
    stream: Stream
    stream.Index = info.index
    stream.Client = info.client
    state.Next_Generation += 1
    stream.Generation = state.Next_Generation
    pid_text := prop(state, info.proplist, "application.process.id")
    if pid_text != "" {
        if pid, ok := strconv.parse_i64(pid_text); ok { stream.Process_ID = pid }
        delete(pid_text)
    }
    stream.Application_ID = prop(state, info.proplist, "application.id")
    stream.Application_Name = prop(state, info.proplist, "application.name")
    stream.Process_Binary = prop(state, info.proplist, "application.process.binary")
    stream.Process_Host = prop(state, info.proplist, "application.process.host")
    stream.Machine_ID = prop(state, info.proplist, "application.process.machine_id")
    stream.Window_XID = prop(state, info.proplist, "window.x11.xid")
    if info.has_volume != 0 {
        stream.Channels = min(info.volume.channels, u8(32))
        copy(stream.Volume[:], info.volume.values[:])
    }
    stream.Muted = info.mute != 0
    stream.Corked = info.corked != 0
    stream.Volume_Writable = info.volume_writable != 0
    return stream
}

apply_info :: proc(request: ^Request, info: ^Pulse_Sink_Input_Info) {
    state := request.Owner
    if state == nil || request.Context != state.Context || request.Epoch != state.Epoch { return }
    if request.List {
        if Stream_Event_Serial(state, info.index) > request.Serial { return }
    } else if info.index != request.Index || Stream_Event_Serial(state, info.index) != request.Serial {
        return
    }
    Replace_Stream(state, stream_from_info(state, info))
}

sink_input_cb :: proc "c" (ctx: ^Pulse_Context, info: ^Pulse_Sink_Input_Info, eol: i32, userdata: rawptr) {
    request := (^Request)(userdata)
    if request == nil { return }
    context = request.Owner.Odin_Context
    if eol == 0 && info != nil { apply_info(request, info) }
    if eol != 0 {
        for pending, i in request.Owner.Requests {
            if pending == request { unordered_remove(&request.Owner.Requests, i); break }
        }
        free(request)
    }
}

start_request :: proc(state: ^State, index: u32, list: bool) {
    if state.Context == nil { return }
    request := new(Request)
    request^ = Request{Owner = state, Context = state.Context, Epoch = state.Epoch, Index = index, List = list}
    request.Serial = state.Serial if list else Stream_Event_Serial(state, index)
    append(&state.Requests, request)
    operation: ^Pulse_Operation
    if list { operation = state.Symbols.context_get_sink_input_info_list(state.Context, sink_input_cb, request) }
    else { operation = state.Symbols.context_get_sink_input_info(state.Context, index, sink_input_cb, request) }
    if operation == nil {
        for pending, i in state.Requests { if pending == request { unordered_remove(&state.Requests, i); break } }
        free(request)
        return
    }
    state.Symbols.operation_unref(operation)
}

subscribe_cb :: proc "c" (ctx: ^Pulse_Context, event_type: i32, index: u32, userdata: rawptr) {
    state := (^State)(userdata)
    if state == nil || ctx != state.Context { return }
    context = state.Odin_Context
    if event_type & PULSE_SUBSCRIPTION_EVENT_FACILITY_MASK != PULSE_SUBSCRIPTION_EVENT_SINK_INPUT { return }
    _ = Note_Stream_Event(state, index)
    if event_type & PULSE_SUBSCRIPTION_EVENT_TYPE_MASK == PULSE_SUBSCRIPTION_EVENT_REMOVE {
        Remove_Stream(state, index)
        return
    }
    start_request(state, index, false)
}

subscribe_ready_cb :: proc "c" (ctx: ^Pulse_Context, success: i32, userdata: rawptr) {
    state := (^State)(userdata)
    if state == nil || ctx != state.Context { return }
    context = state.Odin_Context
    if success == 0 { state.Reset_Pending = true; return }
    start_request(state, 0, true)
}

context_state_cb :: proc "c" (ctx: ^Pulse_Context, userdata: rawptr) {
    state := (^State)(userdata)
    if state == nil || ctx != state.Context { return }
    context = state.Odin_Context
    #partial switch state.Symbols.context_get_state(ctx) {
    case .Ready:
        state.Connected = true
        state.Reconnect_Delay_Ms = 250
        state.Symbols.context_set_subscribe_callback(ctx, subscribe_cb, state)
        if operation := state.Symbols.context_subscribe(ctx, PULSE_SUBSCRIPTION_MASK_SINK_INPUT, subscribe_ready_cb, state); operation != nil {
            state.Symbols.operation_unref(operation)
        } else {
            state.Reset_Pending = true
        }
    case .Failed, .Terminated:
        state.Reset_Pending = true
    case:
    }
}

wall_deadline :: proc(value: ^posix.timeval) -> (time.Tick, bool) {
    if value == nil { return {}, false }
    now_wall: posix.timeval
    if posix.gettimeofday(&now_wall) != nil { return {}, false }
    delta_us := (i64(value.tv_sec)-i64(now_wall.tv_sec))*1_000_000 + i64(value.tv_usec)-i64(now_wall.tv_usec)
    return time.tick_add(time.tick_now(), time.Duration(max(i64(0), delta_us))*time.Microsecond), true
}

io_new :: proc "c" (api: ^Pulse_Mainloop_API, fd, flags: i32, callback: Pulse_IO_CB, userdata: rawptr) -> ^Pulse_IO_Event {
    state := (^State)(api.userdata)
    context = state.Odin_Context
    event := new(IO_Event)
    event^ = IO_Event{Owner = state, FD = fd, Flags = flags, Callback = callback, Userdata = userdata, Alive = true}
    append(&state.IO, event)
    return (^Pulse_IO_Event)(event)
}

io_enable :: proc "c" (opaque: ^Pulse_IO_Event, flags: i32) { event := (^IO_Event)(opaque); if event != nil && event.Alive { event.Flags = flags } }
io_free :: proc "c" (opaque: ^Pulse_IO_Event) {
    event := (^IO_Event)(opaque)
    if event == nil || !event.Alive { return }
    event.Alive = false
    if event.Destroy != nil { event.Destroy(&event.Owner.API, opaque, event.Userdata) }
}
io_set_destroy :: proc "c" (opaque: ^Pulse_IO_Event, callback: Pulse_IO_Destroy_CB) { event := (^IO_Event)(opaque); if event != nil { event.Destroy = callback } }

time_new :: proc "c" (api: ^Pulse_Mainloop_API, value: ^posix.timeval, callback: Pulse_Time_CB, userdata: rawptr) -> ^Pulse_Time_Event {
    state := (^State)(api.userdata)
    context = state.Odin_Context
    event := new(Time_Event)
    event.Owner, event.Callback, event.Userdata, event.Alive = state, callback, userdata, true
    if deadline, ok := wall_deadline(value); ok { event.Deadline, event.Value, event.Enabled = deadline, value^, true }
    append(&state.Times, event)
    return (^Pulse_Time_Event)(event)
}
time_restart :: proc "c" (opaque: ^Pulse_Time_Event, value: ^posix.timeval) {
    event := (^Time_Event)(opaque)
    if event == nil || !event.Alive { return }
    context = event.Owner.Odin_Context
    deadline, ok := wall_deadline(value)
    event.Enabled = ok
    if ok { event.Deadline, event.Value = deadline, value^ }
}
time_free :: proc "c" (opaque: ^Pulse_Time_Event) {
    event := (^Time_Event)(opaque)
    if event == nil || !event.Alive { return }
    event.Alive = false
    if event.Destroy != nil { event.Destroy(&event.Owner.API, opaque, event.Userdata) }
}
time_set_destroy :: proc "c" (opaque: ^Pulse_Time_Event, callback: Pulse_Time_Destroy_CB) { event := (^Time_Event)(opaque); if event != nil { event.Destroy = callback } }

defer_new :: proc "c" (api: ^Pulse_Mainloop_API, callback: Pulse_Defer_CB, userdata: rawptr) -> ^Pulse_Defer_Event {
    state := (^State)(api.userdata)
    context = state.Odin_Context
    event := new(Defer_Event)
    event^ = Defer_Event{Owner = state, Callback = callback, Userdata = userdata, Alive = true, Enabled = true}
    append(&state.Defers, event)
    return (^Pulse_Defer_Event)(event)
}
defer_enable :: proc "c" (opaque: ^Pulse_Defer_Event, enabled: i32) { event := (^Defer_Event)(opaque); if event != nil && event.Alive { event.Enabled = enabled != 0 } }
defer_free :: proc "c" (opaque: ^Pulse_Defer_Event) {
    event := (^Defer_Event)(opaque)
    if event == nil || !event.Alive { return }
    event.Alive = false
    if event.Destroy != nil { event.Destroy(&event.Owner.API, opaque, event.Userdata) }
}
defer_set_destroy :: proc "c" (opaque: ^Pulse_Defer_Event, callback: Pulse_Defer_Destroy_CB) { event := (^Defer_Event)(opaque); if event != nil { event.Destroy = callback } }
quit :: proc "c" (api: ^Pulse_Mainloop_API, result: i32) { state := (^State)(api.userdata); if state != nil { state.Reset_Pending = true } }

init_api :: proc(state: ^State) {
    state.API = Pulse_Mainloop_API{userdata = state, io_new = io_new, io_enable = io_enable, io_free = io_free,
        io_set_destroy = io_set_destroy, time_new = time_new, time_restart = time_restart, time_free = time_free,
        time_set_destroy = time_set_destroy, defer_new = defer_new, defer_enable = defer_enable,
        defer_free = defer_free, defer_set_destroy = defer_set_destroy, quit = quit}
}

connect :: proc(state: ^State) -> bool {
    state.Epoch += 1
    state.Context = state.Symbols.context_new(&state.API, "skarwm")
    if state.Context == nil { return false }
    state.Symbols.context_set_state_callback(state.Context, context_state_cb, state)
    if state.Symbols.context_connect(state.Context, nil, PULSE_CONTEXT_NOAUTOSPAWN, nil) < 0 {
        state.Symbols.context_unref(state.Context)
        state.Context = nil
        return false
    }
    return true
}

Init :: proc(state: ^State, enabled: bool) -> bool {
    state.Odin_Context = context
    state.Enabled = enabled
    if !enabled { return true }
    state.Streams = make([dynamic]Stream, 0, 8)
    state.Versions = make([dynamic]Index_Version, 0, 8)
    state.IO = make([dynamic]^IO_Event, 0, 4)
    state.Times = make([dynamic]^Time_Event, 0, 4)
    state.Defers = make([dynamic]^Defer_Event, 0, 4)
    state.Requests = make([dynamic]^Request, 0, 4)
    state.Poll_Events = make([dynamic]^IO_Event, 0, 4)
    init_api(state)
    state.Available = load_pulse(&state.Symbols)
    if !state.Available { return false }
    state.Reconnect_Delay_Ms = 250
    if !connect(state) {
        state.Reconnect_Due = time.tick_add(time.tick_now(), 250*time.Millisecond)
    }
    return true
}

disconnect :: proc(state: ^State) {
    old_context := state.Context
    if old_context != nil {
        state.Symbols.context_set_state_callback(old_context, nil, nil)
        state.Symbols.context_set_subscribe_callback(old_context, nil, nil)
        state.Symbols.context_disconnect(old_context)
        state.Symbols.context_unref(old_context)
        state.Context = nil
    }
    for i := len(state.Requests)-1; i >= 0; i -= 1 {
        if state.Requests[i].Context == old_context {
            free(state.Requests[i])
            unordered_remove(&state.Requests, i)
        }
    }
    state.Connected = false
    Clear_Streams(state)
}

sweep_events :: proc(state: ^State) {
    for i := len(state.IO)-1; i >= 0; i -= 1 { if !state.IO[i].Alive { free(state.IO[i]); unordered_remove(&state.IO, i) } }
    for i := len(state.Times)-1; i >= 0; i -= 1 { if !state.Times[i].Alive { free(state.Times[i]); unordered_remove(&state.Times, i) } }
    for i := len(state.Defers)-1; i >= 0; i -= 1 { if !state.Defers[i].Alive { free(state.Defers[i]); unordered_remove(&state.Defers, i) } }
}

Shutdown :: proc(state: ^State) {
    if state == nil { return }
    if !state.Enabled { state^ = {}; return }
    disconnect(state)
    for event in state.IO { if event.Alive { io_free((^Pulse_IO_Event)(event)) } }
    for event in state.Times { if event.Alive { time_free((^Pulse_Time_Event)(event)) } }
    for event in state.Defers { if event.Alive { defer_free((^Pulse_Defer_Event)(event)) } }
    sweep_events(state)
    for request in state.Requests { free(request) }
    delete(state.Streams); delete(state.Versions); delete(state.IO); delete(state.Times); delete(state.Defers); delete(state.Requests); delete(state.Poll_Events)
    unload_pulse(&state.Symbols)
    state^ = {}
}

IO_Count :: proc(state: ^State) -> int {
    if state == nil || !state.Enabled || !state.Available { return 0 }
    count := 0
    for event in state.IO { if event.Alive && event.Flags != 0 { count += 1 } }
    return count
}

Append_Poll_FDs :: proc(state: ^State, fds: []posix.pollfd, start: int) -> int {
    clear(&state.Poll_Events)
    i := start
    for event in state.IO {
        if !event.Alive || event.Flags == 0 { continue }
        flags: posix.Poll_Event
        if event.Flags & i32(Pulse_IO_Flags.Input) != 0 { flags += {.IN} }
        if event.Flags & i32(Pulse_IO_Flags.Output) != 0 { flags += {.OUT} }
        fds[i] = posix.pollfd{fd = posix.FD(event.FD), events = flags}
        append(&state.Poll_Events, event)
        i += 1
    }
    return i
}

Dispatch_Poll :: proc(state: ^State, fds: []posix.pollfd, start: int) {
    for event, offset in state.Poll_Events {
        if !event.Alive || event.Callback == nil { continue }
        revents := fds[start+offset].revents
        flags: i32
        if .IN in revents { flags |= i32(Pulse_IO_Flags.Input) }
        if .OUT in revents { flags |= i32(Pulse_IO_Flags.Output) }
        if .HUP in revents { flags |= i32(Pulse_IO_Flags.Hangup) }
        if .ERR in revents || .NVAL in revents { flags |= i32(Pulse_IO_Flags.Error) }
        if flags != 0 { event.Callback(&state.API, (^Pulse_IO_Event)(event), event.FD, flags, event.Userdata) }
    }
}

Poll_Timeout_Ms :: proc(state: ^State) -> i32 {
    if state == nil || !state.Enabled || !state.Available { return -1 }
    for event in state.Defers { if event.Alive && event.Enabled { return 0 } }
    now := time.tick_now()
    timeout: i32 = -1
    for event in state.Times {
        if !event.Alive || !event.Enabled { continue }
        remaining := max(time.Duration(0), time.tick_diff(now, event.Deadline))
        ms := i32((remaining + time.Millisecond - 1)/time.Millisecond)
        if timeout < 0 || ms < timeout { timeout = ms }
    }
    if state.Reconnect_Due != {} {
        remaining := max(time.Duration(0), time.tick_diff(now, state.Reconnect_Due))
        ms := i32((remaining + time.Millisecond - 1)/time.Millisecond)
        if timeout < 0 || ms < timeout { timeout = ms }
    }
    return timeout
}

Run_Due :: proc(state: ^State) {
    if state == nil || !state.Enabled || !state.Available { return }
    now := time.tick_now()
    for event in state.Times {
        if event.Alive && event.Enabled && time.tick_diff(event.Deadline, now) >= 0 {
            event.Enabled = false
            event.Callback(&state.API, (^Pulse_Time_Event)(event), &event.Value, event.Userdata)
        }
    }
    for event in state.Defers { if event.Alive && event.Enabled { event.Callback(&state.API, (^Pulse_Defer_Event)(event), event.Userdata) } }
    if state.Reset_Pending {
        state.Reset_Pending = false
        disconnect(state)
        state.Reconnect_Due = time.tick_add(now, time.Duration(state.Reconnect_Delay_Ms)*time.Millisecond)
        state.Reconnect_Delay_Ms = min(i32(10_000), state.Reconnect_Delay_Ms*2)
    } else if state.Context == nil && state.Reconnect_Due != {} && time.tick_diff(state.Reconnect_Due, now) >= 0 {
        state.Reconnect_Due = {}
        if !connect(state) {
            state.Reconnect_Due = time.tick_add(now, time.Duration(state.Reconnect_Delay_Ms)*time.Millisecond)
            state.Reconnect_Delay_Ms = min(i32(10_000), state.Reconnect_Delay_Ms*2)
        }
    }
    sweep_events(state)
}
