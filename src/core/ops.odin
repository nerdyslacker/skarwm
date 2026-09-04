package core

// Workspace / column / window operations — pure model behaviour. Callers apply
// the results to X afterwards (Arrange_All + push rects + set input focus).

Dir :: enum {
    Left,
    Right,
    Up,
    Down,
}

// Column_Of exposes a client's current column to the X-facing policy layer
// without exposing the package-private workspace search helper.
Column_Of :: proc(cl: ^Client) -> (column_index: int, col: ^Column, row: int) {
    if cl == nil || cl.Ws == nil { return -1, nil, -1 }
    return column_of(cl.Ws, cl)
}

// ----------------------------------------------------------------------------
// Workspaces
// ----------------------------------------------------------------------------

// Activate_WS makes ws the visible workspace of the active output.
Activate_WS :: proc(m: ^Manager, ws: ^Workspace) {
    o := Active_Output(m)
    if o == nil || ws == nil { return }
    o.Current = ws
    m.Focused = ws.Focus
}

// Focus_Output_Rel selects the next/previous output in discovery order,
// wrapping at both ends. Each output retains its independent current workspace.
Focus_Output_Rel :: proc(m: ^Manager, dir: int) -> bool {
    n := len(m.Outputs)
    if n < 2 || dir == 0 { return false }
    idx := m.Active + (dir / abs(dir))
    if idx < 0 { idx = n - 1 }
    if idx >= n { idx = 0 }
    m.Active = idx
    o := m.Outputs[idx]
    if o.Current == nil { o.Current = Ensure_WS_On_Output(o, 1) }
    m.Focused = o.Current.Focus
    return true
}

// Switch_WS_Id activates the workspace with the given 1-based id, creating it
// when absent. Returns the activated workspace or nil.
Switch_WS_Id :: proc(m: ^Manager, id: int) -> ^Workspace {
    ws := Ensure_WS(m, id)
    if ws == nil { return nil }
    Activate_WS(m, ws)
    return ws
}

// Switch_WS_Rel moves to the next (+1) or previous (-1) workspace *by id*. If
// stepping past the highest existing workspace a new one is created (dynamic
// workspaces). Stepping below 1 does nothing.
Switch_WS_Rel :: proc(m: ^Manager, dir: int) -> bool {
    cur := Current_WS(m)
    if cur == nil { return Switch_WS_Id(m, 1) != nil }
    target := cur.Id + dir
    if target < 1 { return false }
    Switch_WS_Id(m, target)
    return true
}

// ----------------------------------------------------------------------------
// Focus
// ----------------------------------------------------------------------------

// Focus_Client points the workspace's focus (and, when the workspace is
// current, the manager/global focus) at cl. Focusing a different window exits
// the previous one's fullscreen (fullscreen belongs to the focused window).
// The Ws == nil guard is what keeps dock clients (which belong to no
// workspace) permanently unfocusable.
Focus_Client :: proc(m: ^Manager, cl: ^Client) {
    if cl == nil || cl.Ws == nil { return }
    ws := cl.Ws
    o := cl.Out
    if o == nil { o = Output_Of_WS(m, ws); cl.Out = o }
    if o != nil && o.Current == ws {
        if oi := Output_Index(m, o); oi >= 0 { m.Active = oi }
    }
    prev := ws.Focus
    if prev != nil && prev != cl && prev.Fullscreen {
        prev.Fullscreen = false
    }
    ws.Focus = cl
    if _, col, _ := column_of(ws, cl); col != nil {
        col.Focus = cl
    }
    if o != nil && o == Active_Output(m) && ws == o.Current {
        m.Focused = cl
    }
}

// Focus_Dir moves focus Left/Right between columns, Up/Down within a column.
// Horizontal targeting prefers the target column's remembered focus, else its
// bottom window. Returns true when focus moved.
Focus_Dir :: proc(m: ^Manager, dir: Dir) -> bool {
    ws := Current_WS(m)
    if ws == nil || ws.Focus == nil { return false }
    cl := ws.Focus
    if cl.Fullscreen { return false }
    if cl.Floating { return false } // pointer/mouse owns floating windows

    ci, col, row := column_of(ws, cl)
    if col == nil { return false }

    target: ^Client = nil
    switch dir {
    case .Left:
        if ci > 0 {
            tcol := ws.Cols[ci - 1]
            target = tcol.Focus
            if target == nil || !column_member(tcol, target) {
                target = tcol.Wins[len(tcol.Wins) - 1]
            }
        }
    case .Right:
        if ci + 1 < len(ws.Cols) {
            tcol := ws.Cols[ci + 1]
            target = tcol.Focus
            if target == nil || !column_member(tcol, target) {
                target = tcol.Wins[len(tcol.Wins) - 1]
            }
        }
    case .Up:
        if row > 0 { target = col.Wins[row - 1] }
    case .Down:
        if row + 1 < len(col.Wins) { target = col.Wins[row + 1] }
    }

    if target == nil || target == cl { return false }
    Focus_Client(m, target)
    return true
}

// in_column_focus_after_removal picks the window to remember as focused inside
// col after cl at `row` (pre-removal) is removed and the column survives.
in_column_focus_after_removal :: proc(col: ^Column, row: int) -> ^Client {
    n := len(col.Wins)
    if n <= 1 { return nil } // column will become empty; caller handles it
    if row < n - 1 { return col.Wins[row + 1] }
    return col.Wins[n - 2]
}

// neighbor_focus_when_col_gone picks a focus when the removed client was the
// last window of column `ci` (that column is about to be destroyed): prefer the
// left neighbour's bottom window, else the right neighbour's top window.
neighbor_focus_when_col_gone :: proc(ws: ^Workspace, ci: int) -> ^Client {
    for off := -1; off <= 1; off += 2 {
        idx := ci + off
        if idx < 0 || idx >= len(ws.Cols) { continue }
        col := ws.Cols[idx]
        if len(col.Wins) > 0 {
            if off < 0 { return col.Wins[len(col.Wins) - 1] }
            return col.Wins[0]
        }
    }
    return nil
}

// fallback_focus_for_ws returns a sensible focus when none is set.
fallback_focus_for_ws :: proc(ws: ^Workspace) -> ^Client {
    if ws == nil { return nil }
    for col in ws.Cols {
        if col.Focus != nil && column_member(col, col.Focus) {
            return col.Focus
        }
    }
    for col in ws.Cols {
        if len(col.Wins) > 0 { return col.Wins[0] }
    }
    return nil
}

// ----------------------------------------------------------------------------
// Adding windows
// ----------------------------------------------------------------------------

// Add_Managed attaches a newly-managed client to ws. New windows land in a
// brand-new column immediately to the right of the focused column (or as the
// first column of an empty workspace) and become focused. Floating windows go
// to ws.Floaters with a centred default rect.
Add_Managed :: proc(m: ^Manager, ws: ^Workspace, cl: ^Client, floating: bool, tab_target: ^Client = nil) {
    cl.Ws = ws
    cl.Out = Output_Of_WS(m, ws)
    cl.Floating = floating
    if floating {
        cl.FloatingRect = Rect {}
        o := cl.Out
        if o != nil {
            p := compute_params(m.Cfg, o.Geom, 0) // ColW unused for floating
            cl.FloatingRect = default_float_rect(p, o.Geom)
        } else {
            cl.FloatingRect = Rect { X = 40, Y = 40, W = 640, H = 480 }
        }
        append(&ws.Floaters, cl)
        Focus_Client(m, cl)
    } else if tab_target != nil && tab_target.Ws == ws {
        _, col, _ := column_of(ws, tab_target)
        if col != nil && col.Layout == .Tabbed {
            append(&col.Wins, cl)
            col.Focus = cl
            ws.Focus = cl
            if ws == Current_WS(m) { m.Focused = cl }
        } else {
            attach_new_window(m, ws, cl)
        }
    } else {
        attach_new_window(m, ws, cl)
    }
    register_client(m, cl)
}

// attach_new_window adds cl to ws as a new column to the right of the focused
// column and focuses it. Does NOT register cl (caller does that once).
attach_new_window :: proc(m: ^Manager, ws: ^Workspace, cl: ^Client) {
    cl.Ws = ws
    cl.Out = Output_Of_WS(m, ws)
    idx := len(ws.Cols)
    if ws.Focus != nil && !ws.Focus.Floating {
        if ci, _, _ := column_of(ws, ws.Focus); ci >= 0 {
            idx = ci + 1
        }
    }
    col := new_column()
    append(&col.Wins, cl)
    array_insert_at(&ws.Cols, idx, col)
    col.Focus = cl
    ws.Focus = cl
    if ws == Current_WS(m) { m.Focused = cl }
}

register_client :: proc(m: ^Manager, cl: ^Client) {
    append(&m.Clients, cl)
    m.ByXid[cl.Xid] = cl
}

// ----------------------------------------------------------------------------
// Docks (output-level panels)
// ----------------------------------------------------------------------------

// Add_Dock registers a dock client on the active output. Docks are ws-less
// (Ws == nil) so they are never tiled, parked, or focusable, and they are
// visible on every workspace. They are still registered in m.Clients/ByXid
// like any other managed client (bulk free + _NET_CLIENT_LIST invariants).
// Never focuses.
Add_Dock :: proc(m: ^Manager, cl: ^Client) {
    Add_Dock_To_Output(m, Active_Output(m), cl)
}

Add_Dock_To_Output :: proc(m: ^Manager, o: ^Output, cl: ^Client) {
    if o == nil { return } // no output yet — nothing to pin the dock to
    cl.Ws = nil
    cl.Out = o
    cl.Dock = true
    cl.Floating = false // docks are not ws floaters; they are output-level
    append(&o.Docks, cl)
    register_client(m, cl)
    Update_Reserved(m)
}

// Update_Reserved recomputes each output's Reserved area as the per-side max
// over the struts claimed by its dock clients. Call whenever a dock is added,
// removed, or changes its strut.
Update_Reserved :: proc(m: ^Manager) {
    for o in m.Outputs {
        o.Reserved = Insets {}
        for d in o.Docks {
            o.Reserved.Left = max(o.Reserved.Left, d.Strut.Left)
            o.Reserved.Right = max(o.Reserved.Right, d.Strut.Right)
            o.Reserved.Top = max(o.Reserved.Top, d.Strut.Top)
            o.Reserved.Bottom = max(o.Reserved.Bottom, d.Strut.Bottom)
        }
    }
}

// Ws_Is_Empty reports whether a workspace holds no windows at all.
Ws_Is_Empty :: proc(ws: ^Workspace) -> bool {
    if ws == nil { return true }
    if len(ws.Cols) > 0 {
        for col in ws.Cols {
            if len(col.Wins) > 0 { return false }
        }
    }
    return len(ws.Floaters) == 0
}

detach_column_empty :: proc(ws: ^Workspace, ci: int) {
    col := ws.Cols[ci]
    assert(len(col.Wins) == 0)
    ordered_remove(&ws.Cols, ci)
    free_column(col)
}

// ----------------------------------------------------------------------------
// Moving
// ----------------------------------------------------------------------------

// Move_Dir implements window movement:
//
//   Left/Right : move the focused window into the adjacent column (appended at
//                its bottom). An emptied source column is removed.
//   Up/Down    : swap the window with its vertical neighbour in the column.
//
// Returns true when the window moved.
Move_Dir :: proc(m: ^Manager, dir: Dir) -> bool {
    ws := Current_WS(m)
    if ws == nil || ws.Focus == nil { return false }
    cl := ws.Focus
    if cl.Fullscreen { return false }
    if cl.Floating { return false } // floating windows are pointer-driven

    ci, col, row := column_of(ws, cl)
    if col == nil { return false }

    switch dir {
    case .Up:
        if row <= 0 { return false }
        col.Wins[row], col.Wins[row-1] = col.Wins[row-1], col.Wins[row]
        col.Focus = cl
        return true
    case .Down:
        if row + 1 >= len(col.Wins) { return false }
        col.Wins[row], col.Wins[row+1] = col.Wins[row+1], col.Wins[row]
        col.Focus = cl
        return true
    case .Left:
        if ci <= 0 { return false }
        return move_window_to_column(ws, cl, col, ci, row, ws.Cols[ci - 1])
    case .Right:
        if ci + 1 >= len(ws.Cols) { return false }
        return move_window_to_column(ws, cl, col, ci, row, ws.Cols[ci + 1])
    }
    return false
}

// move_window_to_column relocates cl out of (col at source `ci`, `row`) into
// the bottom of `target`, cleaning up an emptied source column.
move_window_to_column :: proc(ws: ^Workspace, cl: ^Client, col: ^Column, ci: int, row: int, target: ^Column) -> bool {
    if col.Focus == cl {
        col.Focus = in_column_focus_after_removal(col, row)
    }
    ordered_remove(&col.Wins, row)
    if len(col.Wins) == 0 { detach_column_empty(ws, ci) }
    append(&target.Wins, cl)
    target.Focus = cl
    ws.Focus = cl
    return true
}

// Move_Focused_To_WS relocates the focused window of the active workspace to the
// workspace with the given id, creating it when needed. The source workspace
// keeps a sensible focus. Returns true when the window moved.
Move_Focused_To_WS :: proc(m: ^Manager, id: int) -> bool {
    src := Current_WS(m)
    if src == nil || src.Focus == nil { return false }
    cl := src.Focus
    tgt := Ensure_WS(m, id)
    if tgt == nil || tgt == src { return false }

    cl.Fullscreen = false // never arrive fullscreen elsewhere

    if cl.Floating {
        remove_floater(src, cl)
        if src.Focus == cl { src.Focus = fallback_focus_for_ws(src) }
    } else {
        ci, col, row := column_of(src, cl)
        if col != nil {
            if col.Focus == cl {
                col.Focus = in_column_focus_after_removal(col, row)
            }
            ordered_remove(&col.Wins, row)
            if len(col.Wins) == 0 { detach_column_empty(src, ci) }
        }
        if src.Focus == cl { src.Focus = fallback_focus_for_ws(src) }
    }

    attach_new_window(m, tgt, cl)
    Sync_Focus(m)
    return true
}

// Move_Focused_To_Output_Rel sends the focused client to the next/previous
// output's currently visible workspace. Output selection wraps; the source
// output remains active and chooses a local fallback focus.
Move_Focused_To_Output_Rel :: proc(m: ^Manager, dir: int) -> bool {
    n := len(m.Outputs)
    src_o := Active_Output(m)
    src := Current_WS(m)
    if n < 2 || dir == 0 || src_o == nil || src == nil || src.Focus == nil { return false }
    cl := src.Focus
    idx := m.Active + (dir / abs(dir))
    if idx < 0 { idx = n - 1 }
    if idx >= n { idx = 0 }
    dst_o := m.Outputs[idx]
    if dst_o.Current == nil { dst_o.Current = Ensure_WS_On_Output(dst_o, 1) }
    dst := dst_o.Current

    cl.Fullscreen = false
    if cl.Floating {
        remove_floater(src, cl)
        p := compute_params(m.Cfg, dst_o.Geom, 0, dst_o.Reserved)
        cl.FloatingRect = default_float_rect(p, dst_o.Geom)
        append(&dst.Floaters, cl)
        cl.Ws, cl.Out = dst, dst_o
        dst.Focus = cl
    } else {
        ci, col, row := column_of(src, cl)
        if col == nil { return false }
        if col.Focus == cl { col.Focus = in_column_focus_after_removal(col, row) }
        ordered_remove(&col.Wins, row)
        if len(col.Wins) == 0 { detach_column_empty(src, ci) }
        attach_new_window(m, dst, cl)
    }
    if src.Focus == cl { src.Focus = fallback_focus_for_ws(src) }
    m.Focused = src.Focus
    return true
}

remove_floater :: proc(ws: ^Workspace, cl: ^Client) {
    for i in 0 ..< len(ws.Floaters) {
        if ws.Floaters[i] == cl {
            ordered_remove(&ws.Floaters, i)
            return
        }
    }
}

// ----------------------------------------------------------------------------
// Floating / fullscreen
// ----------------------------------------------------------------------------

// Set_Floating moves cl into or out of the workspace's floating list. A window
// being tiled again becomes its own new column to the right of the focus.
Set_Floating :: proc(m: ^Manager, cl: ^Client, on: bool) {
    if cl == nil || cl.Ws == nil { return }
    ws := cl.Ws

    if on && !cl.Floating {
        if rect_empty(cl.FloatingRect) {
            o := cl.Out
            if o != nil {
                p := compute_params(m.Cfg, o.Geom, 0) // ColW unused for floating
                cl.FloatingRect = default_float_rect(p, o.Geom)
            } else {
                cl.FloatingRect = Rect { X = 40, Y = 40, W = 640, H = 480 }
            }
        }
        if ci, col, row := column_of(ws, cl); col != nil {
            if col.Focus == cl { col.Focus = in_column_focus_after_removal(col, row) }
            ordered_remove(&col.Wins, row)
            if len(col.Wins) == 0 { detach_column_empty(ws, ci) }
        }
        cl.Floating = true
        append(&ws.Floaters, cl)
        Focus_Client(m, cl)
    } else if !on && cl.Floating {
        remove_floater(ws, cl)
        cl.Floating = false
        attach_new_window(m, ws, cl)
    }
}

// Toggle_Floating flips the focused window between tiled and floating.
Toggle_Floating :: proc(m: ^Manager) -> bool {
    ws := Current_WS(m)
    if ws == nil || ws.Focus == nil { return false }
    cl := ws.Focus
    cl.Fullscreen = false
    Set_Floating(m, cl, !cl.Floating)
    return true
}

// Toggle_Fullscreen flips the focused window's fullscreen state and returns the
// new state.
Toggle_Fullscreen :: proc(m: ^Manager) -> (on: bool, changed: bool) {
    ws := Current_WS(m)
    if ws == nil || ws.Focus == nil { return false, false }
    cl := ws.Focus
    cl.Fullscreen = !cl.Fullscreen
    return cl.Fullscreen, true
}

// Set_Column_Layout changes only the focused column between a vertical stack
// and tabs. Other columns remain tiled and visible. Windows are explicitly
// added to a tab group by moving them into that column.
Set_Column_Layout :: proc(m: ^Manager, layout: Column_Layout) -> bool {
    ws := Current_WS(m)
    if ws == nil || ws.Focus == nil || ws.Focus.Floating { return false }
    _, col, _ := column_of(ws, ws.Focus)
    if col == nil { return false }

    if col.Layout == layout { return false }
    col.Layout = layout
    col.Focus = ws.Focus
    return true
}

// Toggle_Column_Layout switches the focused tiled column between stacked and
// tabbed modes.
Toggle_Column_Layout :: proc(m: ^Manager) -> bool {
    ws := Current_WS(m)
    if ws == nil || ws.Focus == nil || ws.Focus.Floating { return false }
    _, col, _ := column_of(ws, ws.Focus)
    if col == nil { return false }
    if col.Layout == .Stacked {
        return Set_Column_Layout(m, .Tabbed)
    }
    if len(col.Wins) <= 1 {
        return Set_Column_Layout(m, .Stacked)
    }

    // The toggle's inverse returns to skarwm's default horizontal layout:
    // each former tab becomes its own column at the tab group's position.
    ci, _, _ := column_of(ws, ws.Focus)
    ordered_remove(&ws.Cols, ci)
    for cl, i in col.Wins {
        restored := new_column()
        append(&restored.Wins, cl)
        restored.Focus = cl
        array_insert_at(&ws.Cols, ci + i, restored)
    }
    free_column(col)
    ws.ViewportX = 0
    return true
}

// Scroll_Viewport pans the active workspace one column step. A positive
// direction reveals content to the right (windows move left); a negative
// direction reveals content to the left (windows move right). Focus is not
// changed and the viewport is clamped to the strip edges.
Scroll_Viewport :: proc(m: ^Manager, dir: int) -> bool {
    if dir == 0 { return false }
    ws := Current_WS(m)
    o := Active_Output(m)
    if ws == nil || o == nil || len(ws.Cols) == 0 { return false }
    p := compute_params(m.Cfg, o.Geom, len(ws.Cols), o.Reserved)
    _, step := strip_geometry(p, len(ws.Cols))
    if step <= 0 { return false }
    sign := i32(dir / abs(dir))
    next := clamp_viewport(ws.ViewportX + step * sign, p, len(ws.Cols))
    if next == ws.ViewportX { return false }
    ws.ViewportX = next
    return true
}

// ----------------------------------------------------------------------------
// Unmanage
// ----------------------------------------------------------------------------

// Unmanage_Client removes cl from every container (workspace, columns, registry)
// without freeing it. Returns the sensible window to focus next (or nil).
Unmanage_Client :: proc(m: ^Manager, cl: ^Client) -> ^Client {
    ws := cl.Ws
    if cl.Dock {
        // Dock clients are output-level (Ws == nil): remove them from their
        // output's dock list and release the reserved area they claimed. The
        // registry removal below still runs (m.Clients/ByXid), and the focus
        // tail exits cleanly because a dock is never the global focus.
        for o in m.Outputs {
            for i in 0 ..< len(o.Docks) {
                if o.Docks[i] == cl {
                    ordered_remove(&o.Docks, i)
                    break
                }
            }
        }
        Update_Reserved(m)
    }
    if ws != nil {
        ci, col, row := column_of(ws, cl)
        if col != nil {
            if col.Focus == cl {
                col.Focus = in_column_focus_after_removal(col, row)
            }
            ordered_remove(&col.Wins, row)
            if len(col.Wins) == 0 { detach_column_empty(ws, ci) }
            if ws.Focus == cl {
                if ci < len(ws.Cols) && len(ws.Cols[ci].Wins) > 0 {
                    r := row
                    if r >= len(ws.Cols[ci].Wins) { r = len(ws.Cols[ci].Wins) - 1 }
                    ws.Focus = ws.Cols[ci].Wins[r]
                } else {
                    ws.Focus = fallback_focus_for_ws(ws)
                }
            }
        } else {
            remove_floater(ws, cl)
            if ws.Focus == cl { ws.Focus = fallback_focus_for_ws(ws) }
        }
        cl.Ws = nil
    }

    for i in 0 ..< len(m.Clients) {
        if m.Clients[i] == cl {
            ordered_remove(&m.Clients, i)
            break
        }
    }
    delete_key(&m.ByXid, cl.Xid)

    cur := Current_WS(m)
    if cur == nil {
        m.Focused = nil
        return nil
    }
    if ws == cur || m.Focused == cl {
        Sync_Focus(m)
        return m.Focused
    }
    return nil
}

// ----------------------------------------------------------------------------
// Reconcile
// ----------------------------------------------------------------------------

// Sync_Focus makes the global focus mirror match the active workspace focus.
Sync_Focus :: proc(m: ^Manager) {
    cur := Current_WS(m)
    if cur == nil { m.Focused = nil } else { m.Focused = cur.Focus }
}

// Ensure_Active_Focus_Visible adjusts the active workspace viewport so its
// focused (tiled) column is fully visible. No-op for nil / floating /
// fullscreen focus. Call Arrange_All afterwards.
Ensure_Active_Focus_Visible :: proc(m: ^Manager) {
    ws := Current_WS(m)
    if ws == nil || ws.Focus == nil { return }
    cl := ws.Focus
    if cl.Floating || cl.Fullscreen { return }
    ci, _, _ := column_of(ws, cl)
    if ci < 0 { return }
    o := Active_Output(m)
    if o == nil { return }
    p := compute_params(m.Cfg, o.Geom, len(ws.Cols), o.Reserved)
    ws.ViewportX = ensure_col_visible(ws.ViewportX, p, len(ws.Cols), col_left_px(p, ci))
}
