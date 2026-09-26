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

resize_column_limits :: proc(col: ^Column, border_width: i32) -> (minimum, maximum: i32) {
    minimum = 60
    if col == nil { return }
    border := 2 * max(i32(0), border_width)
    for cl in col.Wins {
        minimum = max(minimum, cl.SizeHints.MinW + border)
        if cl.SizeHints.MaxW > 0 {
            outer_max := cl.SizeHints.MaxW + border
            if maximum == 0 || outer_max < maximum { maximum = outer_max }
        }
    }
    return
}

resize_row_limits :: proc(cl: ^Client, border_width: i32) -> (minimum, maximum: i32) {
    minimum = 40
    if cl == nil { return }
    border := 2 * max(i32(0), border_width)
    minimum = max(minimum, cl.SizeHints.MinH + border)
    if cl.SizeHints.MaxH > 0 { maximum = cl.SizeHints.MaxH + border }
    return
}

Resize_Edge :: enum i8 { Auto, Left, Right }

store_column_width :: proc(col: ^Column, width, natural: i32) {
    if col == nil { return }
    col.Width = width if width != natural else 0
}

// resize_client_width moves the selected column boundary. When that boundary
// has a neighboring column, the two columns exchange width so their combined
// extent stays fixed. An outer strip edge still resizes independently.
resize_client_width :: proc(
    m: ^Manager, cl: ^Client, delta: i32, edge: Resize_Edge,
) -> bool {
    if delta == 0 { return false }
    ci, col, _ := column_of(cl.Ws, cl)
    if col == nil || column_has_maximized(col) { return false }
    start := Column_Width_At(m, cl.Out, cl.Ws, ci)
    minimum, maximum := resize_column_limits(col, m.Cfg.BorderWidth)
    p := compute_params(m.Cfg, cl.Out.Geom, len(cl.Ws.Cols), cl.Out.Reserved)
    minimum = min(minimum, p.WorkW)
    if maximum <= 0 || maximum > p.WorkW { maximum = p.WorkW }

    neighbor_index := -1
    switch edge {
    case .Left:
        if ci > 0 { neighbor_index = ci - 1 }
    case .Right:
        if ci + 1 < len(cl.Ws.Cols) { neighbor_index = ci + 1 }
    case .Auto:
        // Keyboard width changes have no pointer edge. Prefer the following
        // column, falling back to the previous one at the end of the strip.
        if ci + 1 < len(cl.Ws.Cols) {
            neighbor_index = ci + 1
        } else if ci > 0 {
            neighbor_index = ci - 1
        }
    }

    if neighbor_index >= 0 {
        neighbor := cl.Ws.Cols[neighbor_index]
        if !column_has_maximized(neighbor) {
            neighbor_start := Column_Width_At(m, cl.Out, cl.Ws, neighbor_index)
            neighbor_min, neighbor_max := resize_column_limits(neighbor, m.Cfg.BorderWidth)
            neighbor_min = min(neighbor_min, p.WorkW)
            if neighbor_max <= 0 || neighbor_max > p.WorkW { neighbor_max = p.WorkW }

            focused_width, neighbor_width := i32(0), i32(0)
            if neighbor_index > ci {
                focused_width, neighbor_width = Resize_Pair(
                    start, neighbor_start, delta,
                    minimum, neighbor_min, maximum, neighbor_max,
                )
            } else {
                neighbor_width, focused_width = Resize_Pair(
                    neighbor_start, start, -delta,
                    neighbor_min, minimum, neighbor_max, maximum,
                )
            }
            if focused_width == start { return false }
            natural := Default_Column_Width(m, cl.Out, cl.Ws)
            store_column_width(col, focused_width, natural)
            store_column_width(neighbor, neighbor_width, natural)
            return true
        }
    }

    width := clamp(start + delta, minimum, maximum)
    if width == start { return false }
    natural := Default_Column_Width(m, cl.Out, cl.Ws)
    store_column_width(col, width, natural)
    return true
}

// resize_client_row gives the focused row the requested pixel delta and
// redistributes the remaining height proportionally across every other row.
resize_client_row :: proc(m: ^Manager, cl: ^Client, delta: i32) -> bool {
    if delta == 0 { return false }
    _, col, row := column_of(cl.Ws, cl)
    if col == nil || col.Layout != .Stacked || len(col.Wins) < 2 { return false }

    total, other_start, other_minimum := i32(0), i32(0), i32(0)
    reserved_border := 2 * max(i32(0), m.Cfg.BorderWidth)
    for win, i in col.Wins {
        size := max(i32(1), win.Geom.H + reserved_border)
        win.TileWeight = f64(size)
        total += size
        if i != row {
            other_start += size
            minimum, _ := resize_row_limits(win, m.Cfg.BorderWidth)
            other_minimum += minimum
        }
    }
    start := i32(cl.TileWeight)
    minimum, maximum := resize_row_limits(cl, m.Cfg.BorderWidth)
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

// Resize_Tiled_Client adjusts the focused column and stacked row.
// Negative deltas make that dimension smaller; positive deltas make it larger.
// Horizontal changes move a shared boundary when the selected edge has a
// neighbor. It is shared by keyboard stepping and pointer resizing.
Resize_Tiled_Client :: proc(
    m: ^Manager, cl: ^Client, delta_x, delta_y: i32,
    resize_edge: Resize_Edge = .Auto,
) -> bool {
    if m == nil || cl == nil || cl.Ws == nil || cl.Out == nil ||
       cl.Floating || cl.Fullscreen || cl.Maximized {
        return false
    }
    changed := resize_client_width(m, cl, delta_x, resize_edge)
    if resize_client_row(m, cl, delta_y) { changed = true }
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
