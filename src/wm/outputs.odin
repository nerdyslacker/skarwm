package wm

import logger "../log"
import c "../core"
import x11 "../x11"

// RandR 1.5 monitor discovery. Monitor objects (not raw CRTCs) correctly
// represent mirrored outputs as one logical rectangle and preserve explicit
// monitor names created with xrandr --setmonitor.

import "core:fmt"
import "core:strings"
import "core:time"

Randr_State :: struct {
    available: bool,
    event_base: u8,
    physical: [dynamic]Randr_Physical_Monitor,
    published: [dynamic]u32,
    suppressed: [dynamic]u32,
    refresh: c.Topology_Refresh_State,
    topology: c.Physical_Topology,
    refresh_count: u64,
    transaction_count: u64,
    retry_count: u8,
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
    c.Free_Physical_Topology(&g_randr.topology)
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
    name, _ := x11.get_atom_name(g_wm.conn, id)
    return name
}

Randr_Candidate :: struct {
    topology: c.Physical_Topology,
    specs: [dynamic]c.Output_Spec,
    monitors: [dynamic]Randr_Physical_Monitor,
}

randr_free_candidate :: proc(candidate: ^Randr_Candidate) {
    if candidate == nil { return }
    c.Free_Physical_Topology(&candidate.topology)
    for spec in candidate.specs { if spec.Name != "" { delete(spec.Name) } }
    delete(candidate.specs)
    free_physical_monitors(&candidate.monitors)
    candidate^ = {}
}

randr_specs_valid :: proc(specs: []c.Output_Spec) -> bool {
    if len(specs) == 0 { return false }
    for spec, i in specs {
        if spec.Name == "" || spec.Geom.W <= 0 || spec.Geom.H <= 0 { return false }
        for prior in specs[:i] { if prior.Name == spec.Name { return false } }
    }
    return true
}

// Build a complete temporary snapshot.  No live WM or RandR publication state
// is changed here; any failed/inconsistent reply rejects the whole candidate.
randr_query_candidate :: proc() -> (candidate: Randr_Candidate, ok: bool) {
    root_error: ^x11.Error
    root := x11.xcb_get_geometry_reply(g_wm.conn, x11.xcb_get_geometry(g_wm.conn, g_wm.root), &root_error)
    if root_error != nil { x11.free_libc(root_error) }
    if root == nil { return {}, false }
    candidate.topology.RootGeometry = c.Rect{X = i32(root.x), Y = i32(root.y), W = i32(root.width), H = i32(root.height)}
    x11.free_libc(root)

    resource_error: ^x11.Error
    resources := x11.xcb_randr_get_screen_resources_current_reply(
        g_wm.conn, x11.xcb_randr_get_screen_resources_current(g_wm.conn, g_wm.root), &resource_error)
    if resource_error != nil { x11.free_libc(resource_error) }
    if resources == nil { randr_free_candidate(&candidate); return {}, false }
    defer x11.free_libc(resources)

    primary_error: ^x11.Error
    primary_reply := x11.xcb_randr_get_output_primary_reply(
        g_wm.conn, x11.xcb_randr_get_output_primary(g_wm.conn, g_wm.root), &primary_error)
    if primary_error != nil { x11.free_libc(primary_error) }
    primary := u32(0)
    if primary_reply != nil { primary = primary_reply.output; x11.free_libc(primary_reply) }
    candidate.topology.PrimaryOutputId = primary

    output_count := int(x11.xcb_randr_get_screen_resources_current_outputs_length(resources))
    output_ids := x11.xcb_randr_get_screen_resources_current_outputs(resources)
    cookies := make([]x11.Cookie, output_count)
    defer delete(cookies)
    for id, i in output_ids[:output_count] {
        cookies[i] = x11.xcb_randr_get_output_info(g_wm.conn, id, resources.config_timestamp)
    }
    candidate.topology.Outputs = make([dynamic]c.Physical_Output_State, 0, output_count)
    enabled_count := 0
    for id, i in output_ids[:output_count] {
        output_error: ^x11.Error
        info := x11.xcb_randr_get_output_info_reply(g_wm.conn, cookies[i], &output_error)
        if output_error != nil { x11.free_libc(output_error) }
        if info == nil || info.status != x11.RANDR_CONFIG_SUCCESS {
            if info != nil { x11.free_libc(info) }
            randr_free_candidate(&candidate)
            return {}, false
        }
        name_length := int(x11.xcb_randr_get_output_info_name_length(info))
        name_data := x11.xcb_randr_get_output_info_name(info)
        if name_length <= 0 || name_data == nil {
            x11.free_libc(info)
            randr_free_candidate(&candidate)
            return {}, false
        }
        name := strings.clone(string(name_data[:name_length]))
        state := c.Physical_Output_State{
            StableId = strings.clone(name), Name = name, OutputId = id, CrtcId = info.crtc,
            Connected = info.connection == x11.RANDR_CONNECTION_CONNECTED,
            Primary = id == primary, MmWidth = info.mm_width, MmHeight = info.mm_height,
        }
        if state.Connected && state.CrtcId != 0 {
            crtc_error: ^x11.Error
            crtc := x11.xcb_randr_get_crtc_info_reply(g_wm.conn,
                x11.xcb_randr_get_crtc_info(g_wm.conn, state.CrtcId, resources.config_timestamp), &crtc_error)
            if crtc_error != nil { x11.free_libc(crtc_error) }
            if crtc == nil || crtc.status != x11.RANDR_CONFIG_SUCCESS {
                if crtc != nil { x11.free_libc(crtc) }
                x11.free_libc(info)
                if state.StableId != "" { delete(state.StableId) }
                if state.Name != "" { delete(state.Name) }
                randr_free_candidate(&candidate)
                return {}, false
            }
            state.Rotation = crtc.rotation
            state.Geom = c.Rect{X = i32(crtc.x), Y = i32(crtc.y), W = i32(crtc.width), H = i32(crtc.height)}
            state.Enabled = crtc.mode != 0 && state.Geom.W > 0 && state.Geom.H > 0
            if state.Enabled { enabled_count += 1 }
            x11.free_libc(crtc)
        }
        append(&candidate.topology.Outputs, state)
        x11.free_libc(info)
    }

    monitor_error: ^x11.Error
    monitors_reply := x11.xcb_randr_get_monitors_reply(
        g_wm.conn, x11.xcb_randr_get_monitors(g_wm.conn, g_wm.root, 1), &monitor_error)
    if monitor_error != nil { x11.free_libc(monitor_error) }
    if monitors_reply == nil { randr_free_candidate(&candidate); return {}, false }
    defer x11.free_libc(monitors_reply)
    candidate.specs = make([dynamic]c.Output_Spec, 0, int(monitors_reply.n_monitors) + 1)
    candidate.monitors = make([dynamic]Randr_Physical_Monitor, 0, int(monitors_reply.n_monitors))
    it := x11.xcb_randr_get_monitors_monitors_iterator(monitors_reply)
    index := 0
    for it.rem > 0 && it.data != nil {
        mi := it.data
        if mi.width == 0 || mi.height == 0 { randr_free_candidate(&candidate); return {}, false }
        name := atom_name(mi.name)
        if name == "" { name = fmt.aprintf("monitor-%d", index + 1) }
        geom := c.Rect{X = i32(mi.x), Y = i32(mi.y), W = i32(mi.width), H = i32(mi.height)}
        monitor_outputs := make([dynamic]u32, 0, int(mi.n_output))
        count := int(x11.xcb_randr_monitor_info_outputs_length(mi))
        source := x11.xcb_randr_monitor_info_outputs(mi)
        if count > 0 && source != nil { append(&monitor_outputs, ..source[:count]) }
        monitor_primary := mi.primary != 0 || (primary != 0 && contains_atom(monitor_outputs[:], primary))
        append(&candidate.specs, c.Output_Spec{Name = name, Geom = geom, Primary = monitor_primary})
        append(&candidate.monitors, Randr_Physical_Monitor{
            name = strings.clone(name), primary = monitor_primary, automatic = mi.automatic != 0,
            geom = geom, width_mm = mi.width_mm, height_mm = mi.height_mm, outputs = monitor_outputs,
        })
        index += 1
        x11.xcb_randr_monitor_info_next(&it)
    }
    // An enabled connector must be represented by the active monitor query.
    // If it is not, the server was sampled between related RandR updates.
    if len(candidate.specs) == 0 && enabled_count > 0 {
        randr_free_candidate(&candidate)
        return {}, false
    }
    if len(candidate.specs) == 0 {
        append(&candidate.specs, c.Output_Spec{Name = strings.clone("screen"),
            Geom = candidate.topology.RootGeometry, Primary = true})
    }
    // RandR monitor enumeration order is not identity. Keep the logical input
    // deterministic so a harmless reorder cannot reshuffle screens/workspaces.
    for i in 1 ..< len(candidate.specs) {
        j := i
        for j > 0 {
            a, b := candidate.specs[j - 1], candidate.specs[j]
            ordered := a.Geom.X < b.Geom.X ||
                (a.Geom.X == b.Geom.X && (a.Geom.Y < b.Geom.Y ||
                (a.Geom.Y == b.Geom.Y && a.Name <= b.Name)))
            if ordered { break }
            candidate.specs[j - 1], candidate.specs[j] = candidate.specs[j], candidate.specs[j - 1]
            j -= 1
        }
    }
    has_primary := false
    for spec in candidate.specs { if spec.Primary { has_primary = true; break } }
    if !has_primary {
        // Servers without an output primary (notably nested Xvnc) should not
        // let GetMonitors enumeration order randomly move the logical primary.
        for &spec in candidate.specs {
            old := c.Find_Physical_Output(g_wm.m, spec.Name)
            if old != nil && old.Primary { spec.Primary = true; has_primary = true; break }
        }
    }
    if !has_primary { candidate.specs[0].Primary = true }

    // Detect a configuration racing this multi-reply query and retry after a
    // short settle period instead of committing a mixed generation.
    verify_error: ^x11.Error
    verify := x11.xcb_randr_get_screen_resources_current_reply(
        g_wm.conn, x11.xcb_randr_get_screen_resources_current(g_wm.conn, g_wm.root), &verify_error)
    if verify_error != nil { x11.free_libc(verify_error) }
    consistent := verify != nil && verify.config_timestamp == resources.config_timestamp
    if verify != nil { x11.free_libc(verify) }
    if !consistent || !c.Topology_Valid(&candidate.topology) || !randr_specs_valid(candidate.specs[:]) {
        randr_free_candidate(&candidate)
        return {}, false
    }
    return candidate, true
}

randr_scan :: proc(emit_event: bool) -> bool {
    if !g_randr.available { return false }
    g_randr.refresh_count += 1
    candidate, ok := randr_query_candidate()
    if !ok {
        logger.Debug("RandR: rejected transient/incomplete topology candidate; retaining generation", g_randr.topology.Generation)
        return false
    }
    defer randr_free_candidate(&candidate)
    logger.Debug("RandR authoritative query: root", candidate.topology.RootGeometry,
        "connectors", len(candidate.topology.Outputs), "monitors", len(candidate.specs))
    for output in candidate.topology.Outputs {
        logger.Debug("RandR connector:", output.Name, "output", output.OutputId,
            "crtc", output.CrtcId, "connected", output.Connected, "enabled", output.Enabled,
            "geometry", output.Geom, "rotation", output.Rotation, "primary", output.Primary)
    }
    for spec in candidate.specs {
        logger.Debug("RandR monitor:", spec.Name, "geometry", spec.Geom, "primary", spec.Primary)
    }

    physical_diff := c.Topology_Diff(&g_randr.topology, &candidate.topology)
    defer delete(physical_diff)
    topology_changed := g_randr.topology.RootGeometry != candidate.topology.RootGeometry ||
        g_randr.topology.PrimaryOutputId != candidate.topology.PrimaryOutputId || len(physical_diff) > 0
    logical_changes := make([dynamic]Randr_Change, 0, len(candidate.specs) + len(g_wm.m.Outputs))
    defer {
        for change in logical_changes { delete(change.output) }
        delete(logical_changes)
    }
    for spec in candidate.specs {
        old := c.Find_Physical_Output(g_wm.m, spec.Name)
        if old == nil {
            append(&logical_changes, Randr_Change{kind = "connected", output = strings.clone(spec.Name)})
        } else if old.Geom != spec.Geom || old.Primary != spec.Primary {
            append(&logical_changes, Randr_Change{kind = "geometry", output = strings.clone(spec.Name)})
        }
    }
    for old in g_wm.m.PhysicalOutputs {
        found := false
        for spec in candidate.specs { if spec.Name == old.Name { found = true; break } }
        if !found { append(&logical_changes, Randr_Change{kind = "disconnected", output = strings.clone(old.Name)}) }
    }

    logical_changed := c.Reconcile_Outputs(g_wm.m, candidate.specs[:])
    logger.Debug("RandR diff: physical", topology_changed, "connector changes", len(physical_diff),
        "logical", logical_changed)
    if topology_changed || logical_changed {
        next_generation := g_randr.topology.Generation + 1
        c.Free_Physical_Topology(&g_randr.topology)
        g_randr.topology = candidate.topology
        candidate.topology = {}
        g_randr.topology.Generation = next_generation
        free_physical_monitors(&g_randr.physical)
        g_randr.physical = candidate.monitors
        candidate.monitors = nil
        g_randr.transaction_count += 1
        apply_current_virtual_screens()
        apply_workspace_layout_rules()
        cancel_pointer_operation()
        logger.Info("RandR: committed topology generation", next_generation,
            "connectors:", len(g_randr.topology.Outputs), "active monitors:", len(candidate.specs))
        if emit_event {
            reflow()
            for change in logical_changes { ipc_broadcast_output_event(change.kind, change.output) }
            ipc_broadcast_output_event("topology-changed", "")
        }
    } else {
        // Metadata is still refreshed after a stable query (for virtual-screen
        // publication), but no generation/event is produced for a no-op burst.
        free_physical_monitors(&g_randr.physical)
        g_randr.physical = candidate.monitors
        candidate.monitors = nil
    }
    return true
}

RANDR_RESCAN_DELAY :: 75 * time.Millisecond
RANDR_RETRY_DELAY :: 125 * time.Millisecond
RANDR_MAX_RETRIES :: u8(4)

randr_now_ns :: proc() -> i64 {
    return i64(time.tick_diff({}, time.tick_now()))
}

randr_schedule_rescan :: proc() {
    if !g_randr.available { return }
    c.Topology_Schedule(&g_randr.refresh, randr_now_ns(), i64(RANDR_RESCAN_DELAY))
}

randr_request_rescan :: proc() {
    if !g_randr.available { return }
    c.Topology_Schedule(&g_randr.refresh, randr_now_ns(), 0)
}

randr_poll_timeout_ms :: proc() -> i32 {
    if g_randr.refresh.Phase != .Scheduled { return -1 }
    remaining := g_randr.refresh.Deadline - randr_now_ns()
    if remaining <= 0 { return 0 }
    return i32(min(i64(max(i32)), (remaining + i64(time.Millisecond) - 1) / i64(time.Millisecond)))
}

randr_run_due :: proc() {
    now := randr_now_ns()
    if !c.Topology_Begin_Refresh(&g_randr.refresh, now) { return }
    randr_clear_virtual_monitors()
    ok := randr_scan(true)
    randr_sync_virtual_monitors()
    retry := !ok && g_randr.retry_count < RANDR_MAX_RETRIES
    if retry { g_randr.retry_count += 1 } else { g_randr.retry_count = 0 }
    delay := i64(RANDR_RESCAN_DELAY)
    if retry { delay = i64(RANDR_RETRY_DELAY) }
    c.Topology_End_Refresh(&g_randr.refresh, randr_now_ns(), delay, retry)
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
        switch notify.sub_code {
        case x11.RANDR_NOTIFY_CRTC_CHANGE:
            change := (^x11.Randr_Crtc_Change_Notify_Event)(event)
            logger.Debug("RandR event: crtc-change timestamp", change.timestamp, "crtc", change.crtc,
                "geometry", change.x, change.y, change.width, change.height,
                "rotation", change.rotation, "mode", change.mode)
        case x11.RANDR_NOTIFY_OUTPUT_CHANGE:
            change := (^x11.Randr_Output_Change_Notify_Event)(event)
            logger.Debug("RandR event: output-change timestamp", change.timestamp,
                "config timestamp", change.config_timestamp, "output", change.output,
                "crtc", change.crtc, "connection", change.connection,
                "rotation", change.rotation, "mode", change.mode)
        case x11.RANDR_NOTIFY_OUTPUT_PROPERTY:
            change := (^x11.Randr_Output_Property_Notify_Event)(event)
            logger.Debug("RandR event: output-property timestamp", change.timestamp,
                "output", change.output, "atom", change.atom, "status", change.status)
        case:
            logger.Debug("RandR event: notify subtype", notify.sub_code)
        }
    } else {
        screen := (^x11.Randr_Screen_Change_Notify_Event)(event)
        logger.Debug("RandR event: screen-change root", screen.root,
            "geometry", screen.width, "x", screen.height, "rotation", screen.rotation)
        if screen.root == g_wm.root && screen.width > 0 && screen.height > 0 {
            g_wm.scr_w = i32(screen.width)
            g_wm.scr_h = i32(screen.height)
        }
    }
    randr_schedule_rescan()
    return true
}
