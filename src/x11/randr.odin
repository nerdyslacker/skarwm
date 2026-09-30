package x11

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

Randr_Get_Screen_Resources_Reply :: struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    timestamp: u32,
    config_timestamp: u32,
    num_crtcs: u16,
    num_outputs: u16,
    num_modes: u16,
    names_len: u16,
    pad1: [8]u8,
}

Randr_Get_Output_Info_Reply :: struct {
    response_type: u8,
    status: u8,
    sequence: u16,
    length: u32,
    timestamp: u32,
    crtc: u32,
    mm_width, mm_height: u32,
    connection: u8,
    subpixel_order: u8,
    num_crtcs, num_modes, num_preferred, num_clones, name_len: u16,
}

Randr_Get_Crtc_Info_Reply :: struct {
    response_type: u8,
    status: u8,
    sequence: u16,
    length: u32,
    timestamp: u32,
    x, y: i16,
    width, height: u16,
    mode: u32,
    rotation, rotations, num_outputs, num_possible_outputs: u16,
}

Randr_Get_Output_Primary_Reply :: struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    output: u32,
}

Randr_Notify_Event :: struct {
    response_type: u8,
    sub_code: u8,
    sequence: u16,
    data: [28]u8,
}

Randr_Crtc_Change_Notify_Event :: struct {
    response_type, sub_code: u8,
    sequence: u16,
    timestamp, window, crtc, mode: u32,
    rotation: u16,
    pad0: [2]u8,
    x, y: i16,
    width, height: u16,
}

Randr_Output_Change_Notify_Event :: struct {
    response_type, sub_code: u8,
    sequence: u16,
    timestamp, config_timestamp, window, output, crtc, mode: u32,
    rotation: u16,
    connection, subpixel_order: u8,
}

Randr_Output_Property_Notify_Event :: struct {
    response_type, sub_code: u8,
    sequence: u16,
    window, output, atom, timestamp: u32,
    status: u8,
    pad0: [11]u8,
}

Randr_Screen_Change_Notify_Event :: struct {
    response_type: u8,
    rotation: u8,
    sequence: u16,
    timestamp: u32,
    config_timestamp: u32,
    root: u32,
    request_window: u32,
    size_id: u16,
    subpixel_order: u16,
    width, height: u16,
    mwidth, mheight: u16,
}

#assert(size_of(Randr_Query_Version_Reply) == 32)
#assert(size_of(Randr_Monitor_Info) == 24)
#assert(size_of(Randr_Monitor_Iterator) == 16)
#assert(size_of(Randr_Get_Monitors_Reply) == 32)
#assert(size_of(Randr_Get_Screen_Resources_Reply) == 32)
#assert(size_of(Randr_Get_Output_Info_Reply) == 36)
#assert(size_of(Randr_Get_Crtc_Info_Reply) == 32)
#assert(size_of(Randr_Get_Output_Primary_Reply) == 12)
#assert(size_of(Randr_Notify_Event) == 32)
#assert(size_of(Randr_Crtc_Change_Notify_Event) == 32)
#assert(size_of(Randr_Output_Change_Notify_Event) == 32)
#assert(size_of(Randr_Output_Property_Notify_Event) == 32)
#assert(size_of(Randr_Screen_Change_Notify_Event) == 32)

RANDR_NOTIFY_RESOURCE_CHANGE :: u8(5)
RANDR_NOTIFY_CRTC_CHANGE :: u8(0)
RANDR_NOTIFY_OUTPUT_CHANGE :: u8(1)
RANDR_NOTIFY_OUTPUT_PROPERTY :: u8(2)

RANDR_CONNECTION_CONNECTED :: u8(0)
RANDR_CONFIG_SUCCESS :: u8(0)

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
    xcb_randr_monitor_info_outputs :: proc(info: ^Randr_Monitor_Info) -> [^]u32 ---
    xcb_randr_monitor_info_outputs_length :: proc(info: ^Randr_Monitor_Info) -> i32 ---
    xcb_randr_set_monitor_checked :: proc(c: ^Connection, window: u32, info: ^Randr_Monitor_Info) -> Cookie ---
    xcb_randr_delete_monitor_checked :: proc(c: ^Connection, window, name: u32) -> Cookie ---
    xcb_randr_get_screen_resources_current :: proc(c: ^Connection, window: u32) -> Cookie ---
    xcb_randr_get_screen_resources_current_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Randr_Get_Screen_Resources_Reply ---
    xcb_randr_get_screen_resources_current_outputs :: proc(reply: ^Randr_Get_Screen_Resources_Reply) -> [^]u32 ---
    xcb_randr_get_screen_resources_current_outputs_length :: proc(reply: ^Randr_Get_Screen_Resources_Reply) -> i32 ---
    xcb_randr_get_output_info :: proc(c: ^Connection, output, config_timestamp: u32) -> Cookie ---
    xcb_randr_get_output_info_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Randr_Get_Output_Info_Reply ---
    xcb_randr_get_output_info_name :: proc(reply: ^Randr_Get_Output_Info_Reply) -> [^]u8 ---
    xcb_randr_get_output_info_name_length :: proc(reply: ^Randr_Get_Output_Info_Reply) -> i32 ---
    xcb_randr_get_crtc_info :: proc(c: ^Connection, crtc, config_timestamp: u32) -> Cookie ---
    xcb_randr_get_crtc_info_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Randr_Get_Crtc_Info_Reply ---
    xcb_randr_get_output_primary :: proc(c: ^Connection, window: u32) -> Cookie ---
    xcb_randr_get_output_primary_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Randr_Get_Output_Primary_Reply ---
}
