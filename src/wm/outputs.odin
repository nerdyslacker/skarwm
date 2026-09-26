package wm

import logger "../log"
import c "../core"
import x11 "../x11"

// RandR 1.5 monitor discovery. Monitor objects (not raw CRTCs) correctly
// represent mirrored outputs as one logical rectangle and preserve explicit
// monitor names created with xrandr --setmonitor.

import "core:fmt"
import "core:strings"

Randr_State :: struct {
    available: bool,
    event_base: u8,
    physical: [dynamic]Randr_Physical_Monitor,
    published: [dynamic]u32,
    suppressed: [dynamic]u32,
}

Randr_Physical_Monitor :: struct {
    name: string,
    primary: bool,
    automatic: bool,
    geom: c.Rect,
    width_mm, height_mm: u32,
    outputs: [dynamic]u32,
}

Randr_Pending_Monitor :: struct {
    name: u32,
    cookie: x11.Cookie,
}

Randr_Change :: struct {
    kind: string,
    output: string,
}

g_randr: Randr_State

VIRTUAL_MONITORS_ATOM :: "_SKARWM_VIRTUAL_MONITORS"

free_physical_monitors :: proc(monitors: ^[dynamic]Randr_Physical_Monitor) {
    for monitor in monitors^ {
        if monitor.name != "" { delete(monitor.name) }
        delete(monitor.outputs)
    }
    delete(monitors^)
    monitors^ = nil
}

randr_delete_monitor :: proc(name: u32) {
    if name == 0 { return }
    cookie := x11.xcb_randr_delete_monitor_checked(g_wm.conn, g_wm.root, name)
    if err := x11.xcb_request_check(g_wm.conn, cookie); err != nil {
        // Missing monitor objects are harmless during stale-state cleanup.
        x11.free_libc(err)
    }
}

randr_cleanup_stale_monitors :: proc() {
    property := atom(VIRTUAL_MONITORS_ATOM)
    if data, ok := x11.get_prop(g_wm.conn, g_wm.root, property, atom("ATOM")); ok {
        if len(data) % size_of(u32) == 0 {
            names := ([^]u32)(raw_data(data))[:len(data) / size_of(u32)]
            for name in names { randr_delete_monitor(name) }
        }
        delete(data)
    }
    x11.xcb_delete_property(g_wm.conn, g_wm.root, property)
}

randr_set_monitor_request :: proc(
    name: u32, primary: bool, geom: c.Rect, width_mm, height_mm: u32, outputs: []u32,
) -> x11.Cookie {
    bytes := make([]u8, size_of(x11.Randr_Monitor_Info) + len(outputs) * size_of(u32))
    defer delete(bytes)
    info := (^x11.Randr_Monitor_Info)(raw_data(bytes))
    info^ = x11.Randr_Monitor_Info{
        name = name,
        primary = u8(primary),
        automatic = 0,
        n_output = u16(len(outputs)),
        x = i16(geom.X), y = i16(geom.Y),
        width = u16(geom.W), height = u16(geom.H),
        width_mm = width_mm, height_mm = height_mm,
    }
    if len(outputs) > 0 {
        destination := ([^]u32)(rawptr(uintptr(raw_data(bytes)) + uintptr(size_of(x11.Randr_Monitor_Info))))[:len(outputs)]
        copy(destination, outputs)
    }
    return x11.xcb_randr_set_monitor_checked(g_wm.conn, g_wm.root, info)
}

randr_monitor_request_ok :: proc(cookie: x11.Cookie) -> bool {
    if err := x11.xcb_request_check(g_wm.conn, cookie); err != nil {
        x11.free_libc(err)
        return false
    }
    return true
}

randr_physical_metadata :: proc(name: string) -> ^Randr_Physical_Monitor {
    for &monitor in g_randr.physical { if monitor.name == name { return &monitor } }
    return nil
}

contains_atom :: proc(values: []u32, wanted: u32) -> bool {
    for value in values { if value == wanted { return true } }
    return false
}

randr_restore_suppressed :: proc(force: bool) {
    remaining := make([dynamic]u32, 0, len(g_randr.suppressed))
    for name in g_randr.suppressed {
        for &metadata in g_randr.physical {
            if atom(metadata.name) != name { continue }
            physical := c.Find_Physical_Output(g_wm.m, metadata.name)
            if !force && physical != nil && physical.Split {
                append(&remaining, name)
                break
            }
            cookie := randr_set_monitor_request(
                name, metadata.primary, metadata.geom,
                metadata.width_mm, metadata.height_mm, metadata.outputs[:],
            )
            _ = randr_monitor_request_ok(cookie)
            break
        }
        // If metadata vanished during hot-unplug there is nothing to restore.
    }
    delete(g_randr.suppressed)
    g_randr.suppressed = remaining
}

// Publish logical screens through the standard RandR 1.5 monitor API. The WM
// never rediscovers topology from these objects: physical metadata was saved
// before publication, and ResourceChange notifications from SetMonitor are
// filtered while the projection is active. CRTC/output notifications still
// drive real hardware hotplug.
randr_sync_virtual_monitors :: proc() {
    if !g_randr.available { return }
    desired := make([dynamic]u32, 0, len(g_wm.m.Outputs))
    defer delete(desired)
    deletions := make([dynamic]x11.Cookie, 0, len(g_randr.published))
    defer delete(deletions)
    pending := make([dynamic]Randr_Pending_Monitor, 0, len(g_wm.m.Outputs))
    defer delete(pending)
    server_grabbed := false
    has_projection := false

    for p in g_wm.m.PhysicalOutputs {
        if !p.Split { continue }
        if len(p.Screens) == 2 { has_projection = true }
        _ = atom(p.Name)
        for screen in p.Screens { _ = atom(screen.Name) }
    }

    if len(g_randr.published) > 0 || has_projection {
        _ = x11.xcb_grab_server(g_wm.conn)
        server_grabbed = true
    }
    if len(g_randr.published) > 0 {
        for name in g_randr.published {
            append(&deletions, x11.xcb_randr_delete_monitor_checked(g_wm.conn, g_wm.root, name))
        }
    }

    for p in g_wm.m.PhysicalOutputs {
        if !p.Split || len(p.Screens) != 2 { continue }
        metadata := randr_physical_metadata(p.Name)
        if metadata == nil { continue }
        // An automatic monitor is replaced when its output is assigned to a
        // user-defined child. Explicit xrandr monitors are allowed to overlap,
        // so suppress and later restore those parents ourselves.
        if !metadata.automatic {
            parent_name := atom(metadata.name)
            if !contains_atom(g_randr.suppressed[:], parent_name) {
                randr_delete_monitor(parent_name)
                append(&g_randr.suppressed, parent_name)
            }
        }
        for screen, index in p.Screens {
            name := atom(screen.Name)
            if !server_grabbed {
                _ = x11.xcb_grab_server(g_wm.conn)
                server_grabbed = true
            }
            // RandR 1.5 explicitly permits multiple user-defined monitors on
            // one output for this split-screen use case.
            outputs := metadata.outputs[:]
            width_mm := u32(0)
            if p.Geom.W > 0 { width_mm = u32(max(i32(1), i32(metadata.width_mm) * screen.Geom.W / p.Geom.W)) }
            cookie := randr_set_monitor_request(
                name, metadata.primary && index == 0, screen.Geom,
                width_mm, metadata.height_mm, outputs,
            )
            append(&pending, Randr_Pending_Monitor{name = name, cookie = cookie})
        }
    }

    randr_restore_suppressed(false)

    if server_grabbed {
        _ = x11.xcb_ungrab_server(g_wm.conn)
    }

    for cookie in deletions {
        if err := x11.xcb_request_check(g_wm.conn, cookie); err != nil {
            x11.free_libc(err)
        }
    }
    for request in pending {
        if randr_monitor_request_ok(request.cookie) { append(&desired, request.name) }
    }

    clear(&g_randr.published)
    append(&g_randr.published, ..desired[:])
    property := atom(VIRTUAL_MONITORS_ATOM)
    if len(desired) == 0 {
        x11.xcb_delete_property(g_wm.conn, g_wm.root, property)
    } else {
        x11.set_prop32(g_wm.conn, g_wm.root, property, atom("ATOM"), desired[:])
    }
    x11.xcb_flush(g_wm.conn)
}

randr_clear_virtual_monitors :: proc() {
    if !g_randr.available { return }
    for name in g_randr.published { randr_delete_monitor(name) }
    clear(&g_randr.published)
    randr_restore_suppressed(true)
    x11.xcb_delete_property(g_wm.conn, g_wm.root, atom(VIRTUAL_MONITORS_ATOM))
    x11.xcb_flush(g_wm.conn)
}

randr_shutdown :: proc() {
    randr_clear_virtual_monitors()
    free_physical_monitors(&g_randr.physical)
    delete(g_randr.published)
    delete(g_randr.suppressed)
    g_randr = {}
}

randr_init :: proc() {
    name := "RANDR"
    e: ^x11.Error
    qr := x11.xcb_query_extension_reply(
        g_wm.conn,
        x11.xcb_query_extension(g_wm.conn, u16(len(name)), cstring(raw_data(name))),
        &e,
    )
    if e != nil { x11.free_libc(e) }
    if qr == nil || qr.present == 0 {
        if qr != nil { x11.free_libc(qr) }
        logger.Warn("RandR unavailable; using one screen-sized output")
        return
    }
    g_randr.event_base = qr.first_event
    x11.free_libc(qr)

    e = nil
    vr := x11.xcb_randr_query_version_reply(g_wm.conn, x11.xcb_randr_query_version(g_wm.conn, 1, 5), &e)
    if e != nil { x11.free_libc(e) }
    if vr == nil || vr.major_version < 1 || (vr.major_version == 1 && vr.minor_version < 5) {
        if vr != nil { x11.free_libc(vr) }
        logger.Warn("RandR 1.5 monitor objects unavailable; using one screen-sized output")
        return
    }
    x11.free_libc(vr)

    // SetMonitor/DeleteMonitor emit ResourceChange. The event handler filters
    // those while a projection is active, but retains the subscription so an
    // external xrandr --setmonitor/--delmonitor is still discovered normally.
    mask := x11.RANDR_NOTIFY_MASK_SCREEN_CHANGE | x11.RANDR_NOTIFY_MASK_CRTC_CHANGE |
        x11.RANDR_NOTIFY_MASK_OUTPUT_CHANGE | x11.RANDR_NOTIFY_MASK_OUTPUT_PROPERTY |
        x11.RANDR_NOTIFY_MASK_RESOURCE_CHANGE
    x11.xcb_randr_select_input(g_wm.conn, g_wm.root, mask)
    g_randr.available = true
    g_randr.physical = make([dynamic]Randr_Physical_Monitor, 0, 4)
    g_randr.published = make([dynamic]u32, 0, 4)
    g_randr.suppressed = make([dynamic]u32, 0, 2)
    randr_cleanup_stale_monitors()
    randr_scan(false)
}

atom_name :: proc(id: u32) -> string {
    e: ^x11.Error
    reply := x11.xcb_get_atom_name_reply(g_wm.conn, x11.xcb_get_atom_name(g_wm.conn, id), &e)
    if e != nil { x11.free_libc(e) }
    if reply == nil || reply.name_len == 0 {
        if reply != nil { x11.free_libc(reply) }
        return ""
    }
    n := int(reply.name_len)
    src := ([^]u8)(rawptr(uintptr(rawptr(reply)) + uintptr(size_of(x11.Get_Atom_Name_Reply))))[:n]
    out := make([]byte, n)
    copy(out, src)
    x11.free_libc(reply)
    return string(out)
}

randr_scan :: proc(emit_event: bool) {
    if !g_randr.available { return }
    e: ^x11.Error
    reply := x11.xcb_randr_get_monitors_reply(g_wm.conn, x11.xcb_randr_get_monitors(g_wm.conn, g_wm.root, 1), &e)
    if e != nil { x11.free_libc(e) }
    if reply == nil { return }
    defer x11.free_libc(reply)

    specs := make([dynamic]c.Output_Spec, 0, int(reply.n_monitors))
    physical := make([dynamic]Randr_Physical_Monitor, 0, int(reply.n_monitors))
    defer {
        for spec in specs { if spec.Name != "" { delete(spec.Name) } }
        delete(specs)
        free_physical_monitors(&physical)
    }
    it := x11.xcb_randr_get_monitors_monitors_iterator(reply)
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
            outputs := make([dynamic]u32, 0, int(mi.n_output))
            if mi.n_output > 0 {
                source := ([^]u32)(rawptr(uintptr(rawptr(mi)) + uintptr(size_of(x11.Randr_Monitor_Info))))[:int(mi.n_output)]
                append(&outputs, ..source)
            }
            append(&physical, Randr_Physical_Monitor{
                name = strings.clone(n), primary = mi.primary != 0,
                automatic = mi.automatic != 0,
                geom = c.Rect{X = i32(mi.x), Y = i32(mi.y), W = i32(mi.width), H = i32(mi.height)},
                width_mm = mi.width_mm, height_mm = mi.height_mm, outputs = outputs,
            })
            idx += 1
        }
        x11.xcb_randr_monitor_info_next(&it)
    }
    if len(specs) == 0 { return }
    has_primary := false
    for spec in specs { if spec.Primary { has_primary = true; break } }
    if !has_primary { specs[0].Primary = true }

    free_physical_monitors(&g_randr.physical)
    g_randr.physical = physical
    physical = nil

    changes := make([dynamic]Randr_Change, 0, len(specs) + len(g_wm.m.Outputs))
    defer {
        for change in changes { delete(change.output) }
        delete(changes)
    }
    if emit_event {
        for spec in specs {
            old := c.Find_Physical_Output(g_wm.m, spec.Name)
            if old == nil {
                append(&changes, Randr_Change{kind = "connected", output = strings.clone(spec.Name)})
            } else if old.Geom != spec.Geom {
                append(&changes, Randr_Change{kind = "geometry", output = strings.clone(spec.Name)})
            }
        }
        for old in g_wm.m.PhysicalOutputs {
            found := false
            for spec in specs { if spec.Name == old.Name { found = true; break } }
            if !found {
                append(&changes, Randr_Change{kind = "disconnected", output = strings.clone(old.Name)})
            }
        }
    }

    if c.Reconcile_Outputs(g_wm.m, specs[:]) {
        // Re-derive configured logical geometry from the authoritative current
        // physical rectangle after hotplug or resolution changes.
        apply_current_virtual_screens()
        // The target output or its workarea may have disappeared. Require a
        // fresh drag instead of leaving an indicator at stale root geometry.
        if g_wm.mouse_client != nil { cancel_pointer_operation() }
        logger.Info("RandR: outputs changed; active monitors:", len(specs))
        if emit_event {
            reflow()
            for change in changes { ipc_broadcast_output_event(change.kind, change.output) }
        }
    }
}

randr_handle_event :: proc(event: ^x11.Event, response_type: u8) -> bool {
    if !g_randr.available { return false }
    if response_type != g_randr.event_base && response_type != g_randr.event_base + 1 {
        return false
    }
    if response_type == g_randr.event_base + 1 {
        notify := (^x11.Randr_Notify_Event)(event)
        if notify.sub_code == x11.RANDR_NOTIFY_RESOURCE_CHANGE && len(g_randr.published) > 0 {
            return true
        }
    }
    // Remove our monitor objects before asking RandR for physical monitors;
    // the blocking GetMonitors reply in randr_scan orders this cleanup first.
    randr_clear_virtual_monitors()
    randr_scan(true)
    randr_sync_virtual_monitors()
    return true
}
