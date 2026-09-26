package core

// Pure logical-screen topology operations. RandR callers update
// Physical_Output geometry through Reconcile_Outputs; runtime/config callers
// use these operations so both paths share the same invariants.

Physical_Output_Of :: proc(o: ^Output) -> ^Physical_Output {
    if o == nil { return nil }
    return o.Parent
}

replace_logical_list :: proc(m: ^Manager, wanted: ^Output) {
    old := m.Outputs
    m.Outputs = logical_list_from_physical(m)
    delete(old)
    reset_active_output(m, wanted)
}

Enable_Output_Split :: proc(
    m: ^Manager, o: ^Output, ratio: f64 = 0.5, offset: i32 = 0,
) -> bool {
    if m == nil || o == nil || ratio <= 0 || ratio >= 1 { return false }
    p := o.Parent
    if p == nil || len(p.Screens) == 0 { return false }

    // Validate without mutating so a rejected request is transactional.
    _, _, valid := split_rects(p.Geom, ratio, offset)
    if !valid { return false }

    if p.Split {
        if len(p.Screens) != 2 { return false }
        old_ratio, old_offset := p.SplitRatio, p.SplitOffset
        p.SplitRatio, p.SplitOffset = ratio, offset
        if !apply_split_geometry(p) {
            p.SplitRatio, p.SplitOffset = old_ratio, old_offset
            return false
        }
        Update_Reserved(m)
        return old_ratio != ratio || old_offset != offset
    }

    if len(p.Screens) != 1 { return false }
    active := Active_Output(m)
    left := p.Screens[0]
    right_name := logical_child_name(p.Name, "right")
    right := new_logical_output(p, right_name, {}, {}, true)
    delete(right_name)
    right.Current = Ensure_WS_On_Output(right, max(1, p.SecondaryWorkspace))

    p.Split = true
    p.SplitRatio = ratio
    p.SplitOffset = offset
    append(&p.Screens, right)
    if !apply_split_geometry(p) {
        resize(&p.Screens, 1)
        free_output(right)
        p.Split = false
        set_unsplit_geometry(p, left)
        return false
    }
    replace_logical_list(m, active)
    Update_Reserved(m)
    return true
}

Disable_Output_Split :: proc(m: ^Manager, o: ^Output) -> bool {
    if m == nil || o == nil || o.Parent == nil { return false }
    p := o.Parent
    if !p.Split || len(p.Screens) != 2 { return false }
    left, right := p.Screens[0], p.Screens[1]
    active := Active_Output(m)
    if right.Current != nil { p.SecondaryWorkspace = right.Current.Id }
    migrate_output_state(m, right, left)
    if active == right { active = left }
    free_output(right)
    resize(&p.Screens, 1)
    p.Split = false
    p.SplitOffset = 0
    set_unsplit_geometry(p, left)
    replace_logical_list(m, active)
    Update_Reserved(m)
    return true
}

Toggle_Output_Split :: proc(m: ^Manager, o: ^Output, ratio: f64 = 0.5) -> bool {
    if o == nil || o.Parent == nil { return false }
    if o.Parent.Split { return Disable_Output_Split(m, o) }
    return Enable_Output_Split(m, o, ratio)
}

Set_Output_Split_Ratio :: proc(m: ^Manager, o: ^Output, ratio: f64) -> bool {
    if m == nil || o == nil || o.Parent == nil || !o.Parent.Split { return false }
    return Enable_Output_Split(m, o, ratio, 0)
}

Resize_Output_Split :: proc(m: ^Manager, o: ^Output, delta: i32) -> bool {
    if m == nil || o == nil || o.Parent == nil || delta == 0 { return false }
    p := o.Parent
    if !p.Split || len(p.Screens) != 2 { return false }
    desired := p.Screens[0].Geom.W + delta
    if desired < MIN_LOGICAL_SCREEN_WIDTH || desired > p.Geom.W - MIN_LOGICAL_SCREEN_WIDTH {
        return false
    }
    base := i32(f64(p.Geom.W) * p.SplitRatio + 0.5)
    old_offset := p.SplitOffset
    p.SplitOffset = desired - base
    if !apply_split_geometry(p) {
        p.SplitOffset = old_offset
        return false
    }
    Update_Reserved(m)
    return true
}

