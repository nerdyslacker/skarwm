package audio

import "core:dynlib"
import "core:sys/posix"

Pulse_Context :: struct {}
Pulse_Operation :: struct {}
Pulse_Proplist :: struct {}
Pulse_IO_Event :: struct {}
Pulse_Time_Event :: struct {}
Pulse_Defer_Event :: struct {}
Pulse_Format_Info :: struct {}

Pulse_IO_Flags :: enum i32 {
    Null   = 0,
    Input  = 1,
    Output = 2,
    Hangup = 4,
    Error  = 8,
}

Pulse_Context_State :: enum i32 {
    Unconnected,
    Connecting,
    Authorizing,
    Setting_Name,
    Ready,
    Failed,
    Terminated,
}

Pulse_IO_CB :: proc "c" (^Pulse_Mainloop_API, ^Pulse_IO_Event, i32, i32, rawptr)
Pulse_IO_Destroy_CB :: proc "c" (^Pulse_Mainloop_API, ^Pulse_IO_Event, rawptr)
Pulse_Time_CB :: proc "c" (^Pulse_Mainloop_API, ^Pulse_Time_Event, ^posix.timeval, rawptr)
Pulse_Time_Destroy_CB :: proc "c" (^Pulse_Mainloop_API, ^Pulse_Time_Event, rawptr)
Pulse_Defer_CB :: proc "c" (^Pulse_Mainloop_API, ^Pulse_Defer_Event, rawptr)
Pulse_Defer_Destroy_CB :: proc "c" (^Pulse_Mainloop_API, ^Pulse_Defer_Event, rawptr)

Pulse_Mainloop_API :: struct {
    userdata: rawptr,
    io_new: proc "c" (^Pulse_Mainloop_API, i32, i32, Pulse_IO_CB, rawptr) -> ^Pulse_IO_Event,
    io_enable: proc "c" (^Pulse_IO_Event, i32),
    io_free: proc "c" (^Pulse_IO_Event),
    io_set_destroy: proc "c" (^Pulse_IO_Event, Pulse_IO_Destroy_CB),
    time_new: proc "c" (^Pulse_Mainloop_API, ^posix.timeval, Pulse_Time_CB, rawptr) -> ^Pulse_Time_Event,
    time_restart: proc "c" (^Pulse_Time_Event, ^posix.timeval),
    time_free: proc "c" (^Pulse_Time_Event),
    time_set_destroy: proc "c" (^Pulse_Time_Event, Pulse_Time_Destroy_CB),
    defer_new: proc "c" (^Pulse_Mainloop_API, Pulse_Defer_CB, rawptr) -> ^Pulse_Defer_Event,
    defer_enable: proc "c" (^Pulse_Defer_Event, i32),
    defer_free: proc "c" (^Pulse_Defer_Event),
    defer_set_destroy: proc "c" (^Pulse_Defer_Event, Pulse_Defer_Destroy_CB),
    quit: proc "c" (^Pulse_Mainloop_API, i32),
}

Pulse_Sample_Spec :: struct {
    format: i32,
    rate: u32,
    channels: u8,
}

Pulse_Channel_Map :: struct {
    channels: u8,
    positions: [32]i32,
}

Pulse_CVolume :: struct {
    channels: u8,
    values: [32]u32,
}

Pulse_Sink_Input_Info :: struct {
    index: u32,
    name: cstring,
    owner_module: u32,
    client: u32,
    sink: u32,
    sample_spec: Pulse_Sample_Spec,
    channel_map: Pulse_Channel_Map,
    volume: Pulse_CVolume,
    buffer_usec: u64,
    sink_usec: u64,
    resample_method: cstring,
    driver: cstring,
    mute: i32,
    proplist: ^Pulse_Proplist,
    corked: i32,
    has_volume: i32,
    volume_writable: i32,
    format: ^Pulse_Format_Info,
}

#assert(size_of(Pulse_Mainloop_API) == 112)
#assert(size_of(Pulse_Sample_Spec) == 12)
#assert(size_of(Pulse_Channel_Map) == 132)
#assert(size_of(Pulse_CVolume) == 132)
#assert(size_of(Pulse_Sink_Input_Info) == 376)

Pulse_Context_Notify_CB :: proc "c" (^Pulse_Context, rawptr)
Pulse_Context_Success_CB :: proc "c" (^Pulse_Context, i32, rawptr)
Pulse_Subscribe_CB :: proc "c" (^Pulse_Context, i32, u32, rawptr)
Pulse_Sink_Input_CB :: proc "c" (^Pulse_Context, ^Pulse_Sink_Input_Info, i32, rawptr)

Pulse_Symbols :: struct {
    context_new: proc "c" (^Pulse_Mainloop_API, cstring) -> ^Pulse_Context `dynlib:"pa_context_new"`,
    context_unref: proc "c" (^Pulse_Context) `dynlib:"pa_context_unref"`,
    context_set_state_callback: proc "c" (^Pulse_Context, Pulse_Context_Notify_CB, rawptr) `dynlib:"pa_context_set_state_callback"`,
    context_get_state: proc "c" (^Pulse_Context) -> Pulse_Context_State `dynlib:"pa_context_get_state"`,
    context_connect: proc "c" (^Pulse_Context, cstring, u32, rawptr) -> i32 `dynlib:"pa_context_connect"`,
    context_disconnect: proc "c" (^Pulse_Context) `dynlib:"pa_context_disconnect"`,
    context_set_subscribe_callback: proc "c" (^Pulse_Context, Pulse_Subscribe_CB, rawptr) `dynlib:"pa_context_set_subscribe_callback"`,
    context_subscribe: proc "c" (^Pulse_Context, u32, Pulse_Context_Success_CB, rawptr) -> ^Pulse_Operation `dynlib:"pa_context_subscribe"`,
    context_get_sink_input_info_list: proc "c" (^Pulse_Context, Pulse_Sink_Input_CB, rawptr) -> ^Pulse_Operation `dynlib:"pa_context_get_sink_input_info_list"`,
    context_get_sink_input_info: proc "c" (^Pulse_Context, u32, Pulse_Sink_Input_CB, rawptr) -> ^Pulse_Operation `dynlib:"pa_context_get_sink_input_info"`,
    operation_unref: proc "c" (^Pulse_Operation) `dynlib:"pa_operation_unref"`,
    proplist_gets: proc "c" (^Pulse_Proplist, cstring) -> cstring `dynlib:"pa_proplist_gets"`,
    _handle: dynlib.Library,
}

load_pulse :: proc(symbols: ^Pulse_Symbols) -> bool {
    count, ok := dynlib.initialize_symbols(symbols, "libpulse.so.0", handle_field_name = "_handle")
    return ok && count == 12
}

unload_pulse :: proc(symbols: ^Pulse_Symbols) {
    if symbols._handle != nil { _ = dynlib.unload_library(symbols._handle) }
    symbols^ = {}
}
