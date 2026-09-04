package main

// RandR 1.5 monitor discovery. Monitor objects (not raw CRTCs) correctly
// represent mirrored outputs as one logical rectangle and preserve explicit
// monitor names created with xrandr --setmonitor.

import "core:fmt"
import "core:strings"
import c "core"

Randr_State :: struct {
    available: bool,
    event_base: u8,
}

Randr_Change :: struct {
    kind: string,
    output: string,
}

g_randr: Randr_State

randr_init :: proc() {
    name := "RANDR"
    e: ^Error
    qr := xcb_query_extension_reply(
        g_wm.conn,
        xcb_query_extension(g_wm.conn, u16(len(name)), cstring(raw_data(name))),
        &e,
    )
    if e != nil { free_libc(e) }
    if qr == nil || qr.present == 0 {
        if qr != nil { free_libc(qr) }
        log_warn("RandR unavailable; using one screen-sized output")
        return
    }
    g_randr.event_base = qr.first_event
    free_libc(qr)

    e = nil
    vr := xcb_randr_query_version_reply(g_wm.conn, xcb_randr_query_version(g_wm.conn, 1, 5), &e)
    if e != nil { free_libc(e) }
    if vr == nil || vr.major_version < 1 || (vr.major_version == 1 && vr.minor_version < 5) {
        if vr != nil { free_libc(vr) }
        log_warn("RandR 1.5 monitor objects unavailable; using one screen-sized output")
        return
    }
    free_libc(vr)

    mask := RANDR_NOTIFY_MASK_SCREEN_CHANGE | RANDR_NOTIFY_MASK_CRTC_CHANGE |
        RANDR_NOTIFY_MASK_OUTPUT_CHANGE | RANDR_NOTIFY_MASK_OUTPUT_PROPERTY |
        RANDR_NOTIFY_MASK_RESOURCE_CHANGE
    xcb_randr_select_input(g_wm.conn, g_wm.root, mask)
    g_randr.available = true
    randr_scan(false)
}

atom_name :: proc(id: u32) -> string {
    e: ^Error
    reply := xcb_get_atom_name_reply(g_wm.conn, xcb_get_atom_name(g_wm.conn, id), &e)
    if e != nil { free_libc(e) }
    if reply == nil || reply.name_len == 0 {
        if reply != nil { free_libc(reply) }
        return ""
    }
    n := int(reply.name_len)
    src := ([^]u8)(rawptr(uintptr(rawptr(reply)) + uintptr(size_of(Get_Atom_Name_Reply))))[:n]
    out := make([]byte, n)
    copy(out, src)
    free_libc(reply)
    return string(out)
}

randr_scan :: proc(emit_event: bool) {
    if !g_randr.available { return }
    e: ^Error
    reply := xcb_randr_get_monitors_reply(g_wm.conn, xcb_randr_get_monitors(g_wm.conn, g_wm.root, 1), &e)
    if e != nil { free_libc(e) }
    if reply == nil { return }
    defer free_libc(reply)

    specs := make([dynamic]c.Output_Spec, 0, int(reply.n_monitors))
    defer {
        for spec in specs { if spec.Name != "" { delete(spec.Name) } }
        delete(specs)
    }
    it := xcb_randr_get_monitors_monitors_iterator(reply)
    idx := 0
    for it.rem > 0 && it.data != nil {
        mi := it.data
        if mi.width > 0 && mi.height > 0 {
            n := atom_name(mi.name)
            if n == "" { n = fmt.aprintf("monitor-%d", idx + 1) }
            append(&specs, c.Output_Spec {
                Name = n,
                Geom = c.Rect{X = i32(mi.x), Y = i32(mi.y), W = i32(mi.width), H = i32(mi.height)},
                Primary = mi.primary != 0,
            })
            idx += 1
        }
        xcb_randr_monitor_info_next(&it)
    }
    if len(specs) == 0 { return }
    has_primary := false
    for spec in specs { if spec.Primary { has_primary = true; break } }
    if !has_primary { specs[0].Primary = true }

    changes := make([dynamic]Randr_Change, 0, len(specs) + len(g_wm.m.Outputs))
    defer {
        for change in changes { delete(change.output) }
        delete(changes)
    }
    if emit_event {
        for spec in specs {
            old := c.Find_Output(g_wm.m, spec.Name)
            if old == nil {
                append(&changes, Randr_Change{kind = "connected", output = strings.clone(spec.Name)})
            } else if old.Geom != spec.Geom {
                append(&changes, Randr_Change{kind = "geometry", output = strings.clone(spec.Name)})
            }
        }
        for old in g_wm.m.Outputs {
            found := false
            for spec in specs { if spec.Name == old.Name { found = true; break } }
            if !found {
                append(&changes, Randr_Change{kind = "disconnected", output = strings.clone(old.Name)})
            }
        }
    }

    if c.Reconcile_Outputs(g_wm.m, specs[:]) {
        log_info("RandR: outputs changed; active monitors:", len(specs))
        if emit_event {
            reflow()
            for change in changes { ipc_broadcast_output_event(change.kind, change.output) }
        }
    }
}

randr_handle_event :: proc(response_type: u8) -> bool {
    if !g_randr.available { return false }
    if response_type != g_randr.event_base && response_type != g_randr.event_base + 1 {
        return false
    }
    randr_scan(true)
    return true
}
