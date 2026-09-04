package main

// Minimal XCB RandR 1.5 foreign surface used for monitor discovery and change
// notifications. Core XCB connection/error/cookie types live in xcb.odin.

Randr_Query_Version_Reply :: struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    major_version: u32,
    minor_version: u32,
    pad1: [16]u8,
}

Randr_Monitor_Info :: struct {
    name: u32,
    primary: u8,
    automatic: u8,
    n_output: u16,
    x, y: i16,
    width, height: u16,
    width_mm, height_mm: u32,
}

Randr_Monitor_Iterator :: struct {
    data: ^Randr_Monitor_Info,
    rem: i32,
    index: i32,
}

Randr_Get_Monitors_Reply :: struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    timestamp: u32,
    n_monitors: u32,
    n_outputs: u32,
    pad1: [12]u8,
}

#assert(size_of(Randr_Query_Version_Reply) == 32)
#assert(size_of(Randr_Monitor_Info) == 24)
#assert(size_of(Randr_Monitor_Iterator) == 16)
#assert(size_of(Randr_Get_Monitors_Reply) == 32)

RANDR_NOTIFY_MASK_SCREEN_CHANGE    :: u16(1 << 0)
RANDR_NOTIFY_MASK_CRTC_CHANGE      :: u16(1 << 1)
RANDR_NOTIFY_MASK_OUTPUT_CHANGE    :: u16(1 << 2)
RANDR_NOTIFY_MASK_OUTPUT_PROPERTY  :: u16(1 << 3)
RANDR_NOTIFY_MASK_RESOURCE_CHANGE  :: u16(1 << 6)

foreign import xcb_randr "system:xcb-randr"

@(default_calling_convention = "c")
foreign xcb_randr {
    xcb_randr_query_version :: proc(c: ^Connection, major, minor: u32) -> Cookie ---
    xcb_randr_query_version_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Randr_Query_Version_Reply ---
    xcb_randr_select_input :: proc(c: ^Connection, window: u32, enable: u16) -> Cookie ---
    xcb_randr_get_monitors :: proc(c: ^Connection, window: u32, get_active: u8) -> Cookie ---
    xcb_randr_get_monitors_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Randr_Get_Monitors_Reply ---
    xcb_randr_get_monitors_monitors_iterator :: proc(reply: ^Randr_Get_Monitors_Reply) -> Randr_Monitor_Iterator ---
    xcb_randr_monitor_info_next :: proc(iter: ^Randr_Monitor_Iterator) ---
}
