package core

// Resize_Pair moves one tiled boundary while preserving the pair's total
// extent. max <= 0 means unbounded. It is shared by column and row resizing.
Resize_Pair :: proc(
    first_start, second_start, delta, first_min, second_min: i32,
    first_max: i32 = 0, second_max: i32 = 0,
) -> (first, second: i32) {
    total := max(i32(2), first_start + second_start)
    lo := clamp(max(i32(1), first_min), i32(1), total - 1)
    hi := clamp(total - max(i32(1), second_min), i32(1), total - 1)
    if second_max > 0 { lo = max(lo, total - second_max) }
    if first_max > 0 { hi = min(hi, first_max) }
    lo = clamp(lo, i32(1), total - 1)
    hi = clamp(hi, i32(1), total - 1)
    if hi < lo {
        // Conflicting hints cannot be satisfied while retaining a filled pair.
        // Prefer positive geometry and the requested first-side minimum.
        hi = lo
    }
    first = clamp(first_start + delta, lo, hi)
    second = max(i32(1), total - first)
    return
}

Constrain_Size :: proc(hints: Size_Hints, width, height: i32) -> (w, h: i32) {
    w, h = max(i32(1), width), max(i32(1), height)
    if hints.MinW > 0 { w = max(w, hints.MinW) }
    if hints.MinH > 0 { h = max(h, hints.MinH) }
    if hints.MaxW > 0 { w = min(w, hints.MaxW) }
    if hints.MaxH > 0 { h = min(h, hints.MaxH) }

    base_w := hints.BaseW
    base_h := hints.BaseH
    if base_w <= 0 && hints.MinW > 0 { base_w = hints.MinW }
    if base_h <= 0 && hints.MinH > 0 { base_h = hints.MinH }
    if hints.IncW > 0 && w > base_w { w = base_w + (w - base_w) / hints.IncW * hints.IncW }
    if hints.IncH > 0 && h > base_h { h = base_h + (h - base_h) / hints.IncH * hints.IncH }

    if hints.MinW > 0 { w = max(w, hints.MinW) }
    if hints.MinH > 0 { h = max(h, hints.MinH) }
    if hints.MaxW > 0 { w = min(w, hints.MaxW) }
    if hints.MaxH > 0 { h = min(h, hints.MaxH) }
    return
}

KEYBOARD_RESIZE_STEP :: i32(40)

resize_column_limits :: proc(col: ^Column) -> (minimum, maximum: i32) {
    minimum = 60
    if col == nil { return }
    for cl in col.Wins {
        minimum = max(minimum, cl.SizeHints.MinW + 2 * max(i32(0), cl.Border))
        if cl.SizeHints.MaxW > 0 {
            outer_max := cl.SizeHints.MaxW + 2 * max(i32(0), cl.Border)
            if maximum == 0 || outer_max < maximum { maximum = outer_max }
        }
    }
    return
}

resize_row_limits :: proc(cl: ^Client) -> (minimum, maximum: i32) {
    minimum = 40
    if cl == nil { return }
    border := 2 * max(i32(0), cl.Border)
    minimum = max(minimum, cl.SizeHints.MinH + border)
    if cl.SizeHints.MaxH > 0 { maximum = cl.SizeHints.MaxH + border }
    return
}

// resize_client_width: a column owns its width.
// Resizing it changes the strip extent instead of stealing space from an
// arbitrary (possibly off-screen) neighbor.
resize_client_width :: proc(m: ^Manager, cl: ^Client, delta: i32) -> bool {
    if delta == 0 { return false }
    ci, col, _ := column_of(cl.Ws, cl)
    if col == nil || column_has_maximized(col) { return false }
    start := Column_Width_At(m, cl.Out, cl.Ws, ci)
    minimum, maximum := resize_column_limits(col)
    p := compute_params(m.Cfg, cl.Out.Geom, len(cl.Ws.Cols), cl.Out.Reserved)
    minimum = min(minimum, p.WorkW)
    if maximum <= 0 || maximum > p.WorkW { maximum = p.WorkW }
    width := clamp(start + delta, minimum, maximum)
    if width == start { return false }
    natural := Default_Column_Width(m, cl.Out, cl.Ws)
    col.Width = width if width != natural else 0
    return true
}

// resize_client_row gives the focused row the requested pixel delta and
// redistributes the remaining height proportionally across every other row.
resize_client_row :: proc(cl: ^Client, delta: i32) -> bool {
    if delta == 0 { return false }
    _, col, row := column_of(cl.Ws, cl)
    if col == nil || col.Layout != .Stacked || len(col.Wins) < 2 { return false }

    total, other_start, other_minimum := i32(0), i32(0), i32(0)
    for win, i in col.Wins {
        size := max(i32(1), win.Geom.H + 2 * max(i32(0), win.Border))
        win.TileWeight = f64(size)
        total += size
        if i != row {
            other_start += size
            minimum, _ := resize_row_limits(win)
            other_minimum += minimum
        }
    }
    start := i32(cl.TileWeight)
    minimum, maximum := resize_row_limits(cl)
    available_max := total - other_minimum
    if available_max < minimum { return false }
    if maximum <= 0 || maximum > available_max { maximum = available_max }
    size := clamp(start + delta, minimum, maximum)
    if size == start || other_start <= 0 { return false }

    other_size := total - size
    scale := f64(other_size) / f64(other_start)
    for win, i in col.Wins {
        if i != row { win.TileWeight *= scale }
    }
    cl.TileWeight = f64(size)
    normalize_stack_weights(col)
    return true
}

// Resize_Tiled_Client adjusts the focused column and stacked row independently.
// Negative deltas make that dimension smaller; positive deltas make it larger.
// It is shared by keyboard stepping and pointer resizing.
Resize_Tiled_Client :: proc(m: ^Manager, cl: ^Client, delta_x, delta_y: i32) -> bool {
    if m == nil || cl == nil || cl.Ws == nil || cl.Out == nil ||
       cl.Floating || cl.Fullscreen || cl.Maximized {
        return false
    }
    changed := resize_client_width(m, cl, delta_x)
    if resize_client_row(cl, delta_y) { changed = true }
    return changed
}

// Keyboard semantics: left/up shrink the focused dimension and
// right/down grow it. This makes every resize directly reversible.
Resize_Focused :: proc(m: ^Manager, dir: Dir, amount: i32 = KEYBOARD_RESIZE_STEP) -> bool {
    if m == nil || amount <= 0 { return false }
    ws := Current_WS(m)
    if ws == nil || ws.Focus == nil { return false }
    switch dir {
    case .Left:  return Resize_Tiled_Client(m, ws.Focus, -amount, 0)
    case .Right: return Resize_Tiled_Client(m, ws.Focus, amount, 0)
    case .Up:    return Resize_Tiled_Client(m, ws.Focus, 0, -amount)
    case .Down:  return Resize_Tiled_Client(m, ws.Focus, 0, amount)
    }
    return false
}
