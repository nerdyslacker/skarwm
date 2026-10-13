package x11

Xinerama_Screen_Info :: struct {
    x_org, y_org: i16,
    width, height: u16,
}

Xinerama_Is_Active_Reply :: struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    state: u32,
}

Xinerama_Query_Screens_Reply :: struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    number: u32,
    pad1: [20]u8,
}

#assert(size_of(Xinerama_Screen_Info) == 8)
#assert(size_of(Xinerama_Is_Active_Reply) == 12)
#assert(size_of(Xinerama_Query_Screens_Reply) == 32)

foreign import xcb_xinerama "system:xcb-xinerama"

@(default_calling_convention = "c")
foreign xcb_xinerama {
    xcb_xinerama_is_active :: proc(c: ^Connection) -> Cookie ---
    xcb_xinerama_is_active_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Xinerama_Is_Active_Reply ---
    xcb_xinerama_query_screens :: proc(c: ^Connection) -> Cookie ---
    xcb_xinerama_query_screens_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Xinerama_Query_Screens_Reply ---
    xcb_xinerama_query_screens_screen_info :: proc(reply: ^Xinerama_Query_Screens_Reply) -> [^]Xinerama_Screen_Info ---
    xcb_xinerama_query_screens_screen_info_length :: proc(reply: ^Xinerama_Query_Screens_Reply) -> i32 ---
}
