package x11

// Minimal X-Resource foreign surface: maps a window to the local process that
// owns its client connection. The server records this itself, so unlike
// _NET_WM_PID it is available even for toolkits that never publish the property.

Res_Client_Id_Spec :: struct {
    client: u32,
    mask:   u32,
}

Res_Query_Ids_Reply :: struct {
    response_type: u8,
    pad0:          u8,
    sequence:      u16,
    length:        u32, // whole reply in 32-bit units, after this header
    num_ids:       u32,
    pad1:          [20]u8,
}

#assert(size_of(Res_Client_Id_Spec) == 8)
#assert(size_of(Res_Query_Ids_Reply) == 32)

RES_CLIENT_ID_MASK_LOCAL_CLIENT_PID :: u32(2)

foreign import xcb_res "system:xcb-res"

@(default_calling_convention = "c")
foreign xcb_res {
    xcb_res_query_client_ids :: proc(c: ^Connection, num_specs: u32, specs: ^Res_Client_Id_Spec) -> Cookie ---
    xcb_res_query_client_ids_reply :: proc(c: ^Connection, cookie: Cookie, e: ^^Error) -> ^Res_Query_Ids_Reply ---
}

// client_pid returns the server's local PID for the client owning `window`.
// One ClientIdValue follows the reply header: 12 bytes of spec/length, then
// the PID as its first value. `length >= 4` bounds the read to the reply.
client_pid :: proc(c: ^Connection, window: u32) -> (u32, bool) {
    spec := Res_Client_Id_Spec{client = window, mask = RES_CLIENT_ID_MASK_LOCAL_CLIENT_PID}
    e: ^Error
    reply := xcb_res_query_client_ids_reply(c, xcb_res_query_client_ids(c, 1, &spec), &e)
    if e != nil {
        free_libc(e)
        return 0, false
    }
    if reply == nil {
        return 0, false
    }
    defer free_libc(reply)
    if reply.num_ids != 1 || reply.length < 4 {
        return 0, false
    }
    pid := (^u32)(uintptr(reply) + size_of(Res_Query_Ids_Reply) + 12)^
    return pid, pid > 0
}
