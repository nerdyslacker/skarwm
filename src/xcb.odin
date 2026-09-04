package main

// Thin, hand-written foreign layer over libxcb (X11 core protocol).
//
// Odin ships Xlib bindings but no XCB bindings, so this file mirrors exactly
// the subset of <xcb/xcb.h> and <xcb/xproto.h> that skarwm uses. Every
// struct layout is guarded by a #assert against sizes measured from the real
// headers on the build machine, so ABI drift fails the build instead of
// corrupting state at runtime.
//
// Raw layer only: functions/structs here look like their C counterparts.
// Friendly wrappers live in x11.odin / keys.odin / ewmh.odin.
//
// Foreign symbol names carry the "xcb_" prefix; lib name is system:xcb.

import "core:c"

// ---------------------------------------------------------------------------
// Opaque handles
// ---------------------------------------------------------------------------

Connection :: struct{} // xcb_connection_t
Setup       :: struct{} // xcb_setup_t (never dereferenced)
Event       :: struct{} // xcb_generic_event_t (viewed via casts)
Error       :: struct{} // xcb_generic_error_t (only nil-checked / freed)

X_Error :: struct {
    response_type: u8,
    error_code:    u8,
    sequence:      u16,
    resource_id:   u32,
    minor_code:    u16,
    major_code:    u8,
    pad0:          u8,
    pad:           [5]u32,
    full_sequence: u32,
}

Cookie :: u32 // xcb_*_cookie_t all reduce to unsigned int on the wire

// ---------------------------------------------------------------------------
// Struct mirrors (exact field order/type as the C headers)
// ---------------------------------------------------------------------------

Screen :: struct {
    root:               u32,
    default_colormap:   u32,
    white_pixel:        u32,
    black_pixel:        u32,
    current_input_masks: u32,
    width_in_pixels:    u16,
    height_in_pixels:   u16,
    width_in_millimeters: u16,
    height_in_millimeters: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,
    root_visual:        u32,
    backing_stores:     u8,
    save_unders:        u8,
    root_depth:         u8,
    allowed_depths_len: u8,
}

Screen_Iterator :: struct {
    data:  ^Screen,
    rem:   i32,
    index: i32,
}

// -- events ----------------------------------------------------------------

Map_Request_Event :: struct {
    response_type: u8,
    pad0:          u8,
    sequence:      u16,
    parent:        u32,
    window:        u32,
}

Configure_Request_Event :: struct {
    response_type: u8,
    stack_mode:    u8,
    sequence:      u16,
    parent:        u32,
    window:        u32,
    sibling:       u32,
    x:             i16,
    y:             i16,
    width:         u16,
    height:        u16,
    border_width:  u16,
    value_mask:    u16,
}

Destroy_Notify_Event :: struct {
    response_type: u8,
    pad0:          u8,
    sequence:      u16,
    event:         u32,
    window:        u32,
}

Unmap_Notify_Event :: struct {
    response_type: u8,
    pad0:          u8,
    sequence:      u16,
    event:         u32,
    window:        u32,
    from_configure: u8,
    pad1:          [3]u8,
}

Key_Press_Event :: struct {
    response_type: u8,
    detail:        u8,
    sequence:      u16,
    time:          u32,
    root:          u32,
    event:         u32,
    child:         u32,
    root_x:        i16,
    root_y:        i16,
    event_x:       i16,
    event_y:       i16,
    state:         u16,
    same_screen:   u8,
    pad0:          u8,
}

Button_Press_Event :: Key_Press_Event // layout-identical (detail == button)
Motion_Notify_Event :: Key_Press_Event // layout-identical

Expose_Event :: struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    window: u32,
    x, y, width, height, count: u16,
    pad1: [2]u8,
}

Enter_Notify_Event :: struct {
    response_type: u8,
    detail:        u8,
    sequence:      u16,
    time:          u32,
    root:          u32,
    event:         u32,
    child:         u32,
    root_x:        i16,
    root_y:        i16,
    event_x:       i16,
    event_y:       i16,
    state:         u16,
    mode:          u8,
    same_screen_focus: u8,
}

Mapping_Notify_Event :: struct {
    response_type: u8,
    pad0:          u8,
    sequence:      u16,
    request:       u8,
    first_keycode: u8,
    count:         u8,
    pad1:          u8,
}

Configure_Notify_Event :: struct {
    response_type:  u8,
    pad0:           u8,
    sequence:       u16,
    event:          u32,
    window:         u32,
    above_sibling:  u32,
    x:              i16,
    y:              i16,
    width:          u16,
    height:         u16,
    border_width:   u16,
    override_redirect: u8,
    pad1:           u8,
}

Client_Message_Data :: struct #raw_union {
    data8:  [20]u8,
    data16: [10]u16,
    data32: [5]u32,
}

Client_Message_Event :: struct {
    response_type: u8,
    format:        u8,
    sequence:      u16,
    window:        u32,
    type_:         u32,
    data:          Client_Message_Data,
}

Property_Notify_Event :: struct {
    response_type: u8,
    pad0:          u8,
    sequence:      u16,
    window:        u32,
    atom:          u32,
    time:          u32,
    state:         u8,
    pad1:          [3]u8,
}

Focus_In_Event :: struct {
    response_type: u8,
    detail:        u8,
    sequence:      u16,
    event:         u32,
    mode:          u8,
    pad0:          [3]u8,
}

Reparent_Notify_Event :: struct {
    response_type: u8,
    pad0:          u8,
    sequence:      u16,
    event:         u32,
    window:        u32,
    parent:        u32,
    x:             i16,
    y:             i16,
    override_redirect: u8,
    pad1:          [3]u8,
}

// -- replies ---------------------------------------------------------------

Intern_Atom_Reply :: struct {
    response_type: u8,
    pad0:          u8,
    sequence:      u16,
    length:        u32,
    atom:          u32,
}

Get_Property_Reply :: struct {
    response_type: u8,
    format:        u8,
    sequence:      u16,
    length:        u32,
    type_:         u32,
    bytes_after:   u32,
    value_len:     u32,
    pad:           [12]u8,
}

Get_Geometry_Reply :: struct {
    response_type: u8,
    depth:         u8,
    sequence:      u16,
    length:        u32,
    root:          u32,
    x:             i16,
    y:             i16,
    width:         u16,
    height:        u16,
    border_width:  u16,
    pad:           [2]u8,
}

Get_Window_Attributes_Reply :: struct {
    response_type:      u8,
    backing_store:      u8,
    sequence:           u16,
    length:             u32,
    visual:             u32,
    class:              u16,
    bit_gravity:        u8,
    win_gravity:        u8,
    backing_planes:     u32,
    backing_pixel:      u32,
    save_under:         u8,
    map_is_installed:   u8,
    map_state:          u8,
    override_redirect:  u8,
    colormap:           u32,
    all_event_masks:    u32,
    your_event_mask:    u32,
    do_not_propagate_mask: u16,
    pad:                [2]u8,
}

Query_Tree_Reply :: struct {
    response_type: u8,
    pad0:          u8,
    sequence:      u16,
    length:        u32,
    root:          u32,
    parent:        u32,
    children_len:  u32,
    pad:           [12]u8,
}

Query_Extension_Reply :: struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    present: u8,
    major_opcode: u8,
    first_event: u8,
    first_error: u8,
}

Get_Atom_Name_Reply :: struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    name_len: u16,
    pad1: [22]u8,
}

Get_Keyboard_Mapping_Reply :: struct {
    response_type:         u8,
    keysyms_per_keycode:   u8,
    sequence:              u16,
    length:                u32,
    pad:                   [24]u8,
}

Get_Modifier_Mapping_Reply :: struct {
    response_type:            u8,
    keycodes_per_modifier:    u8,
    sequence:                 u16,
    length:                   u32,
    pad:                      [24]u8,
}

Event_Header :: struct {
    response_type: u8,
    pad0:          u8,
    sequence:      u16,
}

// -- ABI guards ------------------------------------------------------------

#assert(size_of(Screen) == 40)
#assert(size_of(Screen_Iterator) == 16)
#assert(size_of(Map_Request_Event) == 12)
#assert(size_of(Configure_Request_Event) == 28)
#assert(size_of(Destroy_Notify_Event) == 12)
#assert(size_of(Unmap_Notify_Event) == 16)
#assert(size_of(Key_Press_Event) == 32)
#assert(size_of(Button_Press_Event) == 32)
#assert(size_of(Motion_Notify_Event) == 32)
#assert(size_of(Enter_Notify_Event) == 32)
#assert(size_of(Mapping_Notify_Event) == 8)
#assert(size_of(Configure_Notify_Event) == 28)
#assert(size_of(Client_Message_Event) == 32)
#assert(size_of(Client_Message_Data) == 20)
#assert(size_of(Property_Notify_Event) == 20)
#assert(size_of(Focus_In_Event) == 12)
#assert(size_of(Reparent_Notify_Event) == 24)
#assert(size_of(Intern_Atom_Reply) == 12)
#assert(size_of(Get_Property_Reply) == 32)
#assert(size_of(Get_Geometry_Reply) == 24)
#assert(size_of(Get_Window_Attributes_Reply) == 44)
#assert(size_of(Query_Tree_Reply) == 32)
#assert(size_of(Query_Extension_Reply) == 12)
#assert(size_of(Get_Atom_Name_Reply) == 32)
#assert(size_of(Get_Keyboard_Mapping_Reply) == 32)
#assert(size_of(Get_Modifier_Mapping_Reply) == 32)
#assert(size_of(Event_Header) == 4)
#assert(offset_of(Get_Property_Reply, type_) == 8)
#assert(offset_of(Get_Property_Reply, value_len) == 16)
#assert(offset_of(Query_Tree_Reply, children_len) == 16)
#assert(offset_of(Client_Message_Event, data) == 12)
#assert(offset_of(Get_Keyboard_Mapping_Reply, keysyms_per_keycode) == 1)
#assert(offset_of(Get_Modifier_Mapping_Reply, keycodes_per_modifier) == 1)
#assert(offset_of(Screen, root) == 0)

// ---------------------------------------------------------------------------
// Constants (values verified against the installed headers)
// ---------------------------------------------------------------------------

// core event response types
EVENT_MAP_REQUEST :: 20
EVENT_CONFIGURE_REQUEST :: 23
EVENT_DESTROY_NOTIFY :: 17
EVENT_UNMAP_NOTIFY :: 18
EVENT_MAP_NOTIFY :: 19
EVENT_KEY_PRESS :: 2
EVENT_KEY_RELEASE :: 3
EVENT_BUTTON_PRESS :: 4
EVENT_BUTTON_RELEASE :: 5
EVENT_MOTION_NOTIFY :: 6
EVENT_ENTER_NOTIFY :: 7
EVENT_LEAVE_NOTIFY :: 8
EVENT_FOCUS_IN :: 9
EVENT_FOCUS_OUT :: 10
EVENT_EXPOSE :: 12
EVENT_CLIENT_MESSAGE :: 33
EVENT_PROPERTY_NOTIFY :: 28
EVENT_MAPPING_NOTIFY :: 34
EVENT_CONFIGURE_NOTIFY :: 22
EVENT_REPARENT_NOTIFY :: 21

// bit 0x80 marks an error packet (type = error_code | 0x80)
// Bit 7 of an event's response_type marks events injected by a client with
// XSendEvent — every EWMH/ICCCM client message is synthetic, and xcb (unlike
// Xlib) reports the bit as-is. Event dispatch strips it (see main.odin); a
// genuine error packet from an unchecked request has response type 0 after
// stripping.
SEND_EVENT_BIT :: 0x80

ModMask :: enum u16 {
    SHIFT   = 1 << 0,
    LOCK    = 1 << 1,
    CONTROL = 1 << 2,
    MOD1    = 1 << 3,
    MOD2    = 1 << 4,
    MOD3    = 1 << 5,
    MOD4    = 1 << 6,
    MOD5    = 1 << 7,
    ANY     = 1 << 15,
}

MOD_MASK_SHIFT   :: u16(ModMask.SHIFT)
MOD_MASK_LOCK    :: u16(ModMask.LOCK)
MOD_MASK_CONTROL :: u16(ModMask.CONTROL)
MOD_MASK_MOD1    :: u16(ModMask.MOD1)
MOD_MASK_MOD2    :: u16(ModMask.MOD2)
MOD_MASK_MOD3    :: u16(ModMask.MOD3)
MOD_MASK_MOD4    :: u16(ModMask.MOD4)
MOD_MASK_MOD5    :: u16(ModMask.MOD5)
MOD_MASK_ANY     :: u16(ModMask.ANY)

ConfigWindowMask :: enum u32 {
    X           = 1 << 0,
    Y           = 1 << 1,
    WIDTH       = 1 << 2,
    HEIGHT      = 1 << 3,
    BORDER_WIDTH = 1 << 4,
    SIBLING     = 1 << 5,
    STACK_MODE  = 1 << 6,
}

CW_X :: u32(ConfigWindowMask.X)
CW_Y :: u32(ConfigWindowMask.Y)
CW_WIDTH :: u32(ConfigWindowMask.WIDTH)
CW_HEIGHT :: u32(ConfigWindowMask.HEIGHT)
CW_BORDER_WIDTH :: u32(ConfigWindowMask.BORDER_WIDTH)
CW_SIBLING :: u32(ConfigWindowMask.SIBLING)
CW_STACK_MODE :: u32(ConfigWindowMask.STACK_MODE)

// change-window-attributes value masks (subset used)
CW_OVERRIDE_REDIRECT :: u32(1 << 9)
CW_BORDER_PIXEL      :: u32(1 << 3)
CW_EVENT_MASK        :: u32(1 << 11)
CW_CURSOR            :: u32(1 << 14)
CW_BACK_PIXEL        :: u32(1 << 1)

GC_FOREGROUND :: u32(1 << 2)
GC_BACKGROUND :: u32(1 << 3)
GC_FONT       :: u32(1 << 14)

EventMask :: enum u32 {
    KEY_PRESS       = 1 << 0,
    KEY_RELEASE     = 1 << 1,
    BUTTON_PRESS    = 1 << 2,
    BUTTON_RELEASE  = 1 << 3,
    ENTER_WINDOW    = 1 << 4,
    LEAVE_WINDOW    = 1 << 5,
    POINTER_MOTION  = 1 << 6,
    EXPOSURE        = 1 << 15,
    STRUCTURE_NOTIFY = 1 << 17,
    SUBSTRUCTURE_NOTIFY = 1 << 19,
    SUBSTRUCTURE_REDIRECT = 1 << 20,
    FOCUS_CHANGE    = 1 << 21,
    PROPERTY_CHANGE = 1 << 22,
}

EVENT_MASK_KEY_PRESS :: u32(EventMask.KEY_PRESS)
EVENT_MASK_KEY_RELEASE :: u32(EventMask.KEY_RELEASE)
EVENT_MASK_BUTTON_PRESS :: u32(EventMask.BUTTON_PRESS)
EVENT_MASK_BUTTON_RELEASE :: u32(EventMask.BUTTON_RELEASE)
EVENT_MASK_ENTER_WINDOW :: u32(EventMask.ENTER_WINDOW)
EVENT_MASK_LEAVE_WINDOW :: u32(EventMask.LEAVE_WINDOW)
EVENT_MASK_POINTER_MOTION :: u32(EventMask.POINTER_MOTION)
EVENT_MASK_EXPOSURE :: u32(EventMask.EXPOSURE)
EVENT_MASK_STRUCTURE_NOTIFY :: u32(EventMask.STRUCTURE_NOTIFY)
EVENT_MASK_SUBSTRUCTURE_NOTIFY :: u32(EventMask.SUBSTRUCTURE_NOTIFY)
EVENT_MASK_SUBSTRUCTURE_REDIRECT :: u32(EventMask.SUBSTRUCTURE_REDIRECT)
EVENT_MASK_FOCUS_CHANGE :: u32(EventMask.FOCUS_CHANGE)
EVENT_MASK_PROPERTY_CHANGE :: u32(EventMask.PROPERTY_CHANGE)

WINDOW_CLASS_COPY_FROM_PARENT :: u16(0)
WINDOW_CLASS_INPUT_OUTPUT     :: u16(1)
WINDOW_CLASS_INPUT_ONLY       :: u16(2)

MAP_STATE_UNMAPPED   :: u8(0)
MAP_STATE_UNVIEWABLE :: u8(1)
MAP_STATE_VIEWABLE   :: u8(2)

PROP_MODE_REPLACE :: u8(0)
PROP_MODE_PREPEND :: u8(1)
PROP_MODE_APPEND  :: u8(2)

INPUT_FOCUS_NONE          :: u8(0)
INPUT_FOCUS_POINTER_ROOT  :: u8(1)
INPUT_FOCUS_PARENT        :: u8(2)

GRAB_MODE_SYNC  :: u8(0)
GRAB_MODE_ASYNC :: u8(1)
ALLOW_ASYNC_POINTER  :: u8(0)
ALLOW_REPLAY_POINTER :: u8(2)

STACK_MODE_ABOVE :: u32(0)
STACK_MODE_BELOW :: u32(1)

CURRENT_TIME :: u32(0)

ATOM_NONE :: u32(0)

// xcb 32-byte property access for common type tags
ATOM_FORMAT_NONE :: u8(0)
ATOM_FORMAT_8    :: u8(8)
ATOM_FORMAT_16   :: u8(16)
ATOM_FORMAT_32   :: u8(32)

// ---------------------------------------------------------------------------
// Foreign functions
// ---------------------------------------------------------------------------

foreign import xcb "system:xcb"
foreign import libc "system:c"

@(default_calling_convention = "c")
foreign xcb {
    xcb_connect :: proc(display: cstring, screenp: ^i32) -> ^Connection ---

    xcb_connection_has_error :: proc(c: ^Connection) -> i32 ---
    xcb_get_file_descriptor  :: proc(c: ^Connection) -> i32 ---
    xcb_flush                :: proc(c: ^Connection) -> i32 ---
    xcb_generate_id          :: proc(c: ^Connection) -> u32 ---

    xcb_get_setup             :: proc(c: ^Connection) -> ^Setup ---
    xcb_setup_roots_iterator  :: proc(s: ^Setup) -> Screen_Iterator ---

    xcb_create_window :: proc(
        c: ^Connection,
        depth: u8,
        wid: u32,
        parent: u32,
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        border_width: u16,
        class: u16,
        visual: u32,
        value_mask: u32,
        value_list: ^u32,
    ) -> Cookie ---
    xcb_create_window_checked :: proc(
        c: ^Connection,
        depth: u8,
        wid: u32,
        parent: u32,
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        border_width: u16,
        class: u16,
        visual: u32,
        value_mask: u32,
        value_list: ^u32,
    ) -> Cookie ---

    xcb_change_window_attributes :: proc(c: ^Connection, window: u32, value_mask: u32, value_list: ^u32) -> Cookie ---
    xcb_change_window_attributes_checked :: proc(c: ^Connection, window: u32, value_mask: u32, value_list: ^u32) -> Cookie ---
    xcb_destroy_window :: proc(c: ^Connection, window: u32) -> Cookie ---
    xcb_map_window     :: proc(c: ^Connection, window: u32) -> Cookie ---
    xcb_unmap_window   :: proc(c: ^Connection, window: u32) -> Cookie ---
    xcb_configure_window :: proc(c: ^Connection, window: u32, value_mask: u32, value_list: ^u32) -> Cookie ---

    xcb_open_font :: proc(c: ^Connection, fid: u32, name_len: u16, name: cstring) -> Cookie ---
    xcb_close_font :: proc(c: ^Connection, font: u32) -> Cookie ---
    xcb_create_gc :: proc(c: ^Connection, cid, drawable, value_mask: u32, value_list: ^u32) -> Cookie ---
    xcb_change_gc :: proc(c: ^Connection, gc, value_mask: u32, value_list: ^u32) -> Cookie ---
    xcb_free_gc :: proc(c: ^Connection, gc: u32) -> Cookie ---
    xcb_image_text_8 :: proc(c: ^Connection, string_len: u8, drawable, gc: u32, x, y: i16, string: cstring) -> Cookie ---

    xcb_set_input_focus :: proc(c: ^Connection, revert_to: u8, focus: u32, time: u32) -> Cookie ---

    xcb_grab_key   :: proc(c: ^Connection, owner_events: u8, grab_window: u32, modifiers: u16, key: u8, pointer_mode: u8, keyboard_mode: u8) -> Cookie ---
    xcb_ungrab_key :: proc(c: ^Connection, key: u8, grab_window: u32, modifiers: u16) -> Cookie ---
    xcb_grab_button :: proc(c: ^Connection, owner_events: u8, grab_window: u32, event_mask: u16, pointer_mode, keyboard_mode: u8, confine_to, cursor: u32, button: u8, modifiers: u16) -> Cookie ---
    xcb_ungrab_button :: proc(c: ^Connection, button: u8, grab_window: u32, modifiers: u16) -> Cookie ---
    xcb_allow_events :: proc(c: ^Connection, mode: u8, time: u32) -> Cookie ---

    xcb_intern_atom      :: proc(c: ^Connection, only_if_exists: u8, name_len: u16, name: cstring) -> Cookie ---
    xcb_intern_atom_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Intern_Atom_Reply ---

    xcb_change_property :: proc(
        c: ^Connection,
        mode: u8,
        window: u32,
        property: u32,
        type_: u32,
        format: u8,
        data_len: u32,
        data: rawptr,
    ) -> Cookie ---

    xcb_get_property      :: proc(c: ^Connection, _delete: u8, window: u32, property: u32, type_: u32, long_offset: u32, long_length: u32) -> Cookie ---
    xcb_get_property_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Get_Property_Reply ---
    xcb_delete_property   :: proc(c: ^Connection, window: u32, property: u32) -> Cookie ---

    xcb_get_geometry       :: proc(c: ^Connection, drawable: u32) -> Cookie ---
    xcb_get_geometry_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Get_Geometry_Reply ---

    xcb_get_window_attributes       :: proc(c: ^Connection, window: u32) -> Cookie ---
    xcb_get_window_attributes_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Get_Window_Attributes_Reply ---

    xcb_query_tree       :: proc(c: ^Connection, window: u32) -> Cookie ---
    xcb_query_tree_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Query_Tree_Reply ---

    xcb_query_extension :: proc(c: ^Connection, name_len: u16, name: cstring) -> Cookie ---
    xcb_query_extension_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Query_Extension_Reply ---

    xcb_get_atom_name :: proc(c: ^Connection, atom: u32) -> Cookie ---
    xcb_get_atom_name_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Get_Atom_Name_Reply ---

    xcb_get_modifier_mapping       :: proc(c: ^Connection) -> Cookie ---
    xcb_get_modifier_mapping_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Get_Modifier_Mapping_Reply ---

    xcb_get_keyboard_mapping       :: proc(c: ^Connection, first_keycode: u8, count: u8) -> Cookie ---
    xcb_get_keyboard_mapping_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Get_Keyboard_Mapping_Reply ---

    xcb_poll_for_event        :: proc(c: ^Connection) -> ^Event ---
    xcb_poll_for_queued_event :: proc(c: ^Connection) -> ^Event ---
    xcb_request_check         :: proc(c: ^Connection, cookie: Cookie) -> ^Error ---

    xcb_send_event :: proc(c: ^Connection, propagate: u8, destination: u32, event_mask: u32, event: rawptr) -> Cookie ---
    xcb_kill_client :: proc(c: ^Connection, resource: u32) -> Cookie ---

    xcb_disconnect :: proc(c: ^Connection) ---
}

@(default_calling_convention = "c")
foreign libc {
    @(link_name = "free")
    free_libc :: proc(ptr: rawptr) ---
}

// xcb_connect's screen output pointer: passing nil is allowed.
