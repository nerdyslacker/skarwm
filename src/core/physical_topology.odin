package core

// Pure RandR topology types.  These deliberately describe connectors, not
// logical WM screens: a connected connector may have no CRTC and therefore no
// usable geometry.  The X11 layer builds a complete candidate and validates it
// before Reconcile_Outputs is allowed to touch live window-manager state.

Physical_Output_State :: struct {
    StableId: string, // connector name; outputId is the session-local fallback
    Name: string,
    OutputId: u32,
    CrtcId: u32,
    Connected: bool,
    Enabled: bool,
    Geom: Rect,
    Rotation: u16,
    Primary: bool,
    MmWidth: u32,
    MmHeight: u32,
}

Physical_Topology :: struct {
    RootGeometry: Rect,
    Outputs: [dynamic]Physical_Output_State,
    PrimaryOutputId: u32,
    Generation: u64,
}

Topology_Change :: bit_set[Topology_Change_Kind; u16]
Topology_Change_Kind :: enum u16 {
    Added,
    Removed,
    Enabled,
    Disabled,
    Geometry,
    Primary,
    Connection,
    Metadata,
}

Topology_Output_Diff :: struct {
    StableId: string, // non-owning view into old/new snapshots
    Changes: Topology_Change,
}

Topology_Refresh_Phase :: enum u8 { Idle, Scheduled, Refreshing }

Topology_Refresh_State :: struct {
    Phase: Topology_Refresh_Phase,
    Pending: bool,
    Deadline: i64,
}

Topology_Schedule :: proc(state: ^Topology_Refresh_State, now, delay: i64) {
    if state == nil { return }
    if state.Phase == .Refreshing {
        state.Pending = true
        return
    }
    state.Phase = .Scheduled
    state.Deadline = now + max(i64(0), delay)
}

Topology_Begin_Refresh :: proc(state: ^Topology_Refresh_State, now: i64) -> bool {
    if state == nil || state.Phase != .Scheduled || now < state.Deadline { return false }
    state.Phase = .Refreshing
    return true
}

Topology_End_Refresh :: proc(state: ^Topology_Refresh_State, now, delay: i64, retry: bool) {
    if state == nil { return }
    if retry || state.Pending {
        state.Phase = .Scheduled
        state.Pending = false
        state.Deadline = now + max(i64(0), delay)
    } else {
        state^ = {}
    }
}

Topology_Valid :: proc(topology: ^Physical_Topology) -> bool {
    if topology == nil || topology.RootGeometry.W <= 0 || topology.RootGeometry.H <= 0 {
        return false
    }
    for output, i in topology.Outputs {
        if output.OutputId == 0 || output.Name == "" || output.StableId == "" { return false }
        if output.Enabled && (!output.Connected || output.CrtcId == 0 ||
            output.Geom.W <= 0 || output.Geom.H <= 0) { return false }
        for other in topology.Outputs[:i] {
            if output.OutputId == other.OutputId || output.StableId == other.StableId { return false }
        }
    }
    return true
}

Topology_Has_Pending_Enable :: proc(topology: ^Physical_Topology) -> bool {
    if topology == nil { return false }
    for output in topology.Outputs {
        if output.Connected && !output.Enabled { return true }
    }
    return false
}

Topology_Output_Equal :: proc(a, b: Physical_Output_State) -> bool {
    return a.OutputId == b.OutputId && a.CrtcId == b.CrtcId &&
        a.Connected == b.Connected && a.Enabled == b.Enabled && a.Geom == b.Geom &&
        a.Rotation == b.Rotation && a.Primary == b.Primary &&
        a.MmWidth == b.MmWidth && a.MmHeight == b.MmHeight && a.Name == b.Name
}

Topology_Equal :: proc(a, b: ^Physical_Topology) -> bool {
    if a == nil || b == nil || a.RootGeometry != b.RootGeometry ||
       a.PrimaryOutputId != b.PrimaryOutputId || len(a.Outputs) != len(b.Outputs) { return false }
    // Enumeration order is not identity.
    for output in a.Outputs {
        found := false
        for other in b.Outputs {
            if output.StableId == other.StableId {
                found = Topology_Output_Equal(output, other)
                break
            }
        }
        if !found { return false }
    }
    return true
}

Topology_Diff :: proc(old, next: ^Physical_Topology) -> [dynamic]Topology_Output_Diff {
    result := make([dynamic]Topology_Output_Diff, 0,
        (len(old.Outputs) if old != nil else 0) + (len(next.Outputs) if next != nil else 0))
    if next != nil {
        for current in next.Outputs {
            previous: ^Physical_Output_State
            if old != nil {
                for &candidate in old.Outputs {
                    if candidate.StableId == current.StableId { previous = &candidate; break }
                }
            }
            changes: Topology_Change
            if previous == nil {
                changes += {.Added}
                if current.Enabled { changes += {.Enabled} }
            } else {
                if previous.Connected != current.Connected { changes += {.Connection} }
                if !previous.Enabled && current.Enabled { changes += {.Enabled} }
                if previous.Enabled && !current.Enabled { changes += {.Disabled} }
                if previous.Geom != current.Geom || previous.Rotation != current.Rotation ||
                   previous.CrtcId != current.CrtcId { changes += {.Geometry} }
                if previous.Primary != current.Primary { changes += {.Primary} }
                if previous.OutputId != current.OutputId || previous.MmWidth != current.MmWidth ||
                   previous.MmHeight != current.MmHeight || previous.Name != current.Name {
                    changes += {.Metadata}
                }
            }
            if changes != {} { append(&result, Topology_Output_Diff{StableId = current.StableId, Changes = changes}) }
        }
    }
    if old != nil {
        for previous in old.Outputs {
            found := false
            if next != nil {
                for current in next.Outputs { if current.StableId == previous.StableId { found = true; break } }
            }
            if !found { append(&result, Topology_Output_Diff{StableId = previous.StableId, Changes = {.Removed}}) }
        }
    }
    return result
}

Free_Physical_Topology :: proc(topology: ^Physical_Topology) {
    if topology == nil { return }
    for output in topology.Outputs {
        if output.StableId != "" { delete(output.StableId) }
        if output.Name != "" { delete(output.Name) }
    }
    delete(topology.Outputs)
    topology^ = {}
}
