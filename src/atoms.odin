package main

// Atom interning + property read helpers over the raw xcb layer.
//
// libxcb's icccm/ewmh helper headers are not installed on the target (see
// docs/REFERENCE_NOTES.md §5), so property access is done by hand with
// xcb_intern_atom / xcb_get_property / xcb_change_property. This file wraps
// those raw calls behind small, safe procedures used by the WM core.

// intern_atom resolves (and caches in wm.atoms) the atom id for `name`.
// `only_if_exists = 0` tells the server to create the atom if unknown.
intern_atom :: proc(c: ^Connection, cache: ^map[string]u32, name: string, only_if_exists: u8 = 0) -> u32 {
    if v, ok := cache[name]; ok {
        return v
    }
    if len(name) == 0 { return 0 }
    cookie := xcb_intern_atom(c, only_if_exists, u16(len(name)), cstring(raw_data(name)))
    e: ^Error
    reply := xcb_intern_atom_reply(c, cookie, &e)
    if e != nil {
        free_libc(e)
        return 0
    }
    if reply == nil {
        return 0
    }
    id := reply.atom
    free_libc(reply)
    cache[name] = id
    return id
}

// get_prop fetches the value bytes of `prop` on `window`, copied into an owned
// byte slice. `wanted_type` is an atom id to filter on (0 == any type).
// Returns ok=false when the property is absent, has a different format/type, or
// the read fails. The returned slice is allocated; call delete() on it.
get_prop :: proc(c: ^Connection, window: u32, prop: u32, wanted_type: u32 = 0) -> (data: []byte, ok: bool) {
    if prop == 0 { return nil, false }
    // long_length is in 32-bit units; ask for a generous window and grow if the
    // reply reports more data waiting (bytes_after > 0).
    read_len: u32 = 1024
    for {
        cookie := xcb_get_property(c, 0, window, prop, wanted_type, 0, read_len)
        e: ^Error
        reply := xcb_get_property_reply(c, cookie, &e)
        if e != nil {
            free_libc(e)
            return nil, false
        }
        if reply == nil {
            return nil, false
        }
        defer free_libc(reply)

        if reply.format == 0 || reply.value_len == 0 {
            return nil, true // present but empty
        }
        nbytes := int(reply.value_len) * int(reply.format) / 8
        if reply.bytes_after > 0 && uint(reply.bytes_after) > uint(nbytes) {
            read_len = read_len * 4 // grow and retry
            continue
        }
        src := rawptr(uintptr(rawptr(reply)) + uintptr(size_of(Get_Property_Reply)))
        dst := make([]byte, nbytes)
        copy(dst, mem_to_bytes(src, nbytes))
        return dst, true
    }
}

// mem_to_bytes views `n` bytes starting at p as a byte slice (no copy).
mem_to_bytes :: proc(p: rawptr, n: int) -> []byte {
    if p == nil || n <= 0 { return nil }
    return ([^]byte)(p)[:n]
}

// get_text returns the property's bytes re-interpreted as an owned string when
// the property is 8-bit text (format 8). Only useful for WM_NAME-style props.
get_text :: proc(c: ^Connection, window: u32, prop: u32) -> (s: string, ok: bool) {
    data, okp := get_prop(c, window, prop)
    if !okp || len(data) == 0 {
        if okp { delete(data) }
        return "", false
    }
    // trim a trailing NUL if the client NUL-terminated its string
    n := len(data)
    if data[n - 1] == 0 { n -= 1 }
    out := strings_clone_here(string(data[:n]))
    delete(data)
    return out, true
}

// strings_clone_here clones a string with the default allocator (core has its
// own clone helper, but this file avoids an import cycle).
strings_clone_here :: proc(s: string) -> string {
    if s == "" { return "" }
    b := make([]byte, len(s))
    copy(b, s)
    return string(b)
}

// property change (write) — used for EWMH/ICCCM state properties.
set_prop32 :: proc(c: ^Connection, window, prop, type_: u32, values: []u32) {
    if len(values) == 0 {
        // An empty 32-bit list is expressed by deleting the property (X11 has
        // no zero-item properties); e.g. _NET_CLIENT_LIST with no clients.
        xcb_delete_property(c, window, prop)
        return
    }
    xcb_change_property(c, PROP_MODE_REPLACE, window, prop, type_, ATOM_FORMAT_32, u32(len(values)), raw_data(values))
}

set_prop_atom :: proc(c: ^Connection, window, prop: u32, type_: u32, value: u32) {
    vals := [1]u32{value}
    xcb_change_property(c, PROP_MODE_REPLACE, window, prop, type_, ATOM_FORMAT_32, 1, &vals[0])
}

set_prop_text :: proc(c: ^Connection, window, prop: u32, type_: u32, s: string) {
    if len(s) == 0 {
        // deleting is how an empty value is expressed
        xcb_change_property(c, PROP_MODE_REPLACE, window, prop, type_, ATOM_FORMAT_8, 0, nil)
        return
    }
    xcb_change_property(c, PROP_MODE_REPLACE, window, prop, type_, ATOM_FORMAT_8, u32(len(s)), raw_data(s))
}

// delete_prop removes a property.
delete_prop :: proc(c: ^Connection, window, prop: u32) {
    xcb_delete_property(c, window, prop)
}
