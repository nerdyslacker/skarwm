package core

// Layout / geometry — the one authoritative calculation pass. Pure: mutates
// rects and viewports on the model only, never touches X.
//
// Coordinate model
// ----------------
// A workspace owns a horizontal strip of columns. Column 0's left edge sits at
// strip coordinate 0; successive columns are spaced `inner` px apart. Screen x
// = work_x + strip_x - viewport_x. Increasing viewport_x pans content left.
//
// Work area = output rectangle inset by `outer`, after any dock reservation:
//     work_x = geom.X + outer + res.left
//     work_w = geom.W - outer*2 - res.left - res.right
//     work_y = geom.Y + outer + res.top
//     work_h = geom.H - outer*2 - res.top - res.bottom
// A zero `res` reproduces the plain outer-gap inset.
//
// Normal columns use a uniform width derived per workspace (see
// Resolve_Page_Width): fewer columns than a screen page (PAGE_COLS) expand to
// fill the work width; with PAGE_COLS or more exactly PAGE_COLS fit on screen.
// A column containing a maximized client temporarily occupies a complete work
// area page, so following columns move right and remain reachable by scrolling.
// Windows in a stacked column divide the column height minus `inner` gaps. A
// tabbed column gives its full rectangle to the active tab and parks its sibling
// tabs off screen while keeping them mapped.
//
// Each window's `Geom` is the *client* box inset by its border, so the X border
// ring lies strictly inside its tile and never overlaps neighbours:
//     client_geom = tile grown inward by `border`

HIDE_X :: -20000 // park off-screen windows here (kept within X int16 range)
PAGE_COLS :: 2 // columns that fit on screen before the strip starts scrolling
TAB_BAR_HEIGHT :: i32(24)
SCROLL_PREVIEW_WIDTH :: i32(20)

Layout_Params :: struct {
    WorkX, WorkY: i32,
    WorkW, WorkH: i32,
    ColW: i32, // width of every normal (non-maximized) column
    Inner: i32, // gap between columns and between windows in a column
    Border: i32, // per-window X border
}

compute_params :: proc(cfg: Config, geom: Rect, n_cols: int, res: Insets = {}) -> (p: Layout_Params) {
    p.WorkX = geom.X + cfg.OuterGap + max(i32(0), res.Left)
    p.WorkY = geom.Y + cfg.OuterGap + max(i32(0), res.Top)
    p.WorkW = (geom.W - cfg.OuterGap * 2 -
        max(i32(0), res.Left) - max(i32(0), res.Right))
    p.WorkH = (geom.H - cfg.OuterGap * 2 -
        max(i32(0), res.Top) - max(i32(0), res.Bottom))
    p.Inner = cfg.InnerGap
    p.Border = cfg.BorderWidth
    if p.WorkW < 1 || p.WorkH < 1 {
        p.ColW = 0
        return
    }
    p.ColW = Resolve_Page_Width(p.WorkW, p.Inner, n_cols)
    return
}

// Resolve_Page_Width returns the uniform tile width for a workspace holding
// `n_cols` columns. Fewer than PAGE_COLS columns expand to exactly fill the
// work width; with PAGE_COLS or more each column is a page width chosen so that
// PAGE_COLS columns plus their inner gaps fit on screen — extra columns then
// overflow to the right and the viewport scrolls. Clamped so a column never
// exceeds the work width and never becomes unusably narrow.
Resolve_Page_Width :: proc(work_w, inner: i32, n_cols: int) -> i32 {
    if n_cols <= 0 { return 0 }
    k := i32(min(n_cols, PAGE_COLS))
    w := (work_w - inner * (k - 1)) / k
    if w < 60 { w = 60 }
    if w > work_w { w = work_w }
    return w
}

// strip_geometry returns, for n columns of uniform width, the total content
// width and the horizontal step (column width + gap) used to walk the strip.
strip_geometry :: proc(p: Layout_Params, n_cols: int) -> (total: i32, step: i32) {
    if n_cols <= 0 { return 0, 0 }
    n := i32(n_cols)
    step = p.ColW + p.Inner
    total = n * p.ColW + (n - 1) * p.Inner
    return total, step
}

// col_left_px returns the strip-coordinate left edge of column `idx`.
col_left_px :: proc(p: Layout_Params, idx: int) -> i32 {
    return i32(idx) * (p.ColW + p.Inner)
}

// A maximized tiled client expands its whole column to one work-area page.
// The extra width participates in strip geometry, pushing later columns right
// instead of drawing the maximized client over them.
column_has_maximized :: proc(col: ^Column) -> bool {
    if col == nil { return false }
    for cl in col.Wins { if cl.Maximized { return true } }
    return false
}

column_width :: proc(p: Layout_Params, col: ^Column) -> i32 {
    if column_has_maximized(col) { return p.WorkW }
    if col != nil && col.Width > 0 { return clamp(col.Width, i32(60), p.WorkW) }
    return p.ColW
}

Column_Width_At :: proc(m: ^Manager, o: ^Output, ws: ^Workspace, index: int) -> i32 {
    if m == nil || o == nil || ws == nil || index < 0 || index >= len(ws.Cols) { return 0 }
    p := compute_params(m.Cfg, o.Geom, len(ws.Cols), o.Reserved)
    return column_width(p, ws.Cols[index])
}

Default_Column_Width :: proc(m: ^Manager, o: ^Output, ws: ^Workspace) -> i32 {
    if m == nil || o == nil || ws == nil { return 0 }
    p := compute_params(m.Cfg, o.Geom, len(ws.Cols), o.Reserved)
    return p.ColW
}

workspace_col_left :: proc(ws: ^Workspace, p: Layout_Params, idx: int) -> i32 {
    x := i32(0)
    if ws == nil { return x }
    for i in 0 ..< min(idx, len(ws.Cols)) {
        x += column_width(p, ws.Cols[i]) + p.Inner
    }
    return x
}

workspace_strip_total :: proc(ws: ^Workspace, p: Layout_Params) -> i32 {
    if ws == nil || len(ws.Cols) == 0 { return 0 }
    total := i32(0)
    for col, i in ws.Cols {
        total += column_width(p, col)
        if i + 1 < len(ws.Cols) { total += p.Inner }
    }
    return total
}

clamp_workspace_viewport :: proc(vp: i32, ws: ^Workspace, p: Layout_Params) -> i32 {
    max_vp := workspace_strip_total(ws, p) - p.WorkW
    if max_vp < 0 { max_vp = 0 }
    return clamp(vp, i32(0), max_vp)
}

ensure_workspace_col_visible :: proc(vp: i32, ws: ^Workspace, p: Layout_Params, idx: int) -> i32 {
    if ws == nil || idx < 0 || idx >= len(ws.Cols) { return 0 }
    left := workspace_col_left(ws, p, idx)
    right := left + column_width(p, ws.Cols[idx])
    next := vp
    if left < next {
        next = left
    } else if right > next + p.WorkW {
        next = right - p.WorkW
    }
    return clamp_workspace_viewport(next, ws, p)
}

Scroll_Preview_Side :: enum u8 { None, Left, Right }

Scroll_Preview :: struct {
    Side:   Scroll_Preview_Side,
    Client: ^Client,
    Geom:   Rect,
}

// scroll_preview_columns finds the nearest completely hidden column on each
// side of the current viewport. Previews belong only to the overflowing tiled
// strip; fullscreen and maximize deliberately suppress them.
scroll_preview_columns :: proc(ws: ^Workspace, p: Layout_Params) -> (left, right: int) {
    left, right = -1, -1
    if ws == nil || len(ws.Cols) == 0 || workspace_strip_total(ws, p) <= p.WorkW { return }
    if ws.Focus != nil && ws.Focus.Fullscreen { return }
    for col in ws.Cols { if column_has_maximized(col) { return } }

    work_left := p.WorkX
    work_right := p.WorkX + p.WorkW
    for col, ci in ws.Cols {
        x := p.WorkX - ws.ViewportX + workspace_col_left(ws, p, ci)
        w := column_width(p, col)
        if x + w <= work_left {
            left = ci
        } else if x >= work_right && right < 0 {
            right = ci
        }
    }
    return
}

// scroll_normal_col_rect reserves the exposed edge of one neighboring window
// plus the normal inner gap
// at each occupied edge, then fits the fully visible page columns into the
// remaining center area. Logical strip widths and ViewportX stay unchanged;
// this is only the rendered page rectangle.
scroll_normal_col_rect :: proc(ws: ^Workspace, p: Layout_Params, wanted: int) -> (x, w: i32, visible: bool) {
    if ws == nil || wanted < 0 || wanted >= len(ws.Cols) { return 0, 0, false }
    left_preview, right_preview := scroll_preview_columns(ws, p)
    main_x := p.WorkX
    main_w := p.WorkW
    if left_preview >= 0 {
        reserve := min(SCROLL_PREVIEW_WIDTH, column_width(p, ws.Cols[left_preview])) + p.Inner
        main_x += reserve
        main_w -= reserve
    }
    if right_preview >= 0 {
        reserve := min(SCROLL_PREVIEW_WIDTH, column_width(p, ws.Cols[right_preview])) + p.Inner
        main_w -= reserve
    }
    if main_w <= 0 { return 0, 0, false }

    work_right := p.WorkX + p.WorkW
    count, ordinal := 0, -1
    desired_total, desired_before, desired_w := i32(0), i32(0), i32(0)
    for col, ci in ws.Cols {
        logical_x := p.WorkX - ws.ViewportX + workspace_col_left(ws, p, ci)
        logical_w := column_width(p, col)
        if logical_x < p.WorkX || logical_x + logical_w > work_right { continue }
        if ci == wanted {
            ordinal = count
            desired_before = desired_total
            desired_w = logical_w
        }
        desired_total += logical_w
        count += 1
    }
    if ordinal < 0 || count == 0 || desired_total <= 0 { return 0, 0, false }
    content_w := max(i32(count), main_w - p.Inner * i32(count - 1))
    scaled_before := i32(i64(content_w) * i64(desired_before) / i64(desired_total))
    scaled_end := i32(i64(content_w) * i64(desired_before + desired_w) / i64(desired_total))
    x = main_x + scaled_before + i32(ordinal) * p.Inner
    w = max(i32(1), scaled_end - scaled_before)
    return x, w, true
}

// Scroll_Previews returns the exposed edge regions of the actual neighboring
// clients produced by the most recent Arrange_All pass. Stacked columns yield
// one hit zone per visible row; tabbed columns yield only their active client.
Scroll_Previews :: proc(m: ^Manager, o: ^Output) -> [dynamic]Scroll_Preview {
    result := make([dynamic]Scroll_Preview, 0, 4)
    if m == nil || o == nil || o.Current == nil { return result }
    ws := o.Current
    p := compute_params(m.Cfg, o.Geom, len(ws.Cols), o.Reserved)
    left, right := scroll_preview_columns(ws, p)
    indices := [2]int{left, right}
    for ci in indices {
        if ci < 0 { continue }
        side := Scroll_Preview_Side.Left
        zone_x := p.WorkX
        if ci == right {
            side = .Right
            zone_x = p.WorkX + p.WorkW - SCROLL_PREVIEW_WIDTH
        }
        zone_w := min(SCROLL_PREVIEW_WIDTH, column_width(p, ws.Cols[ci]))
        for cl in ws.Cols[ci].Wins {
            if cl.Geom.X <= HIDE_X { continue }
            top := max(p.WorkY, cl.Geom.Y - cl.Border)
            bottom := min(p.WorkY + p.WorkH, cl.Geom.Y + cl.Geom.H + cl.Border)
            if bottom <= top { continue }
            append(&result, Scroll_Preview{
                Side = side,
                Client = cl,
                Geom = Rect{X = zone_x, Y = top, W = zone_w, H = bottom - top},
            })
        }
    }
    return result
}

Scroll_Preview_At_Point :: proc(m: ^Manager, x, y: i32) -> (preview: Scroll_Preview, ok: bool) {
    if m == nil { return {}, false }
    for o in m.Outputs {
        previews := Scroll_Previews(m, o)
        for p in previews {
            r := p.Geom
            if x >= r.X && x < r.X + r.W && y >= r.Y && y < r.Y + r.H {
                preview = p
                delete(previews)
                return preview, true
            }
        }
        delete(previews)
    }
    return {}, false
}

// Tab_Bar_Rect returns the root-coordinate strip reserved above a tabbed
// column. The X layer uses it to draw decorations without duplicating layout
// calculations.
Tab_Bar_Rect :: proc(m: ^Manager, o: ^Output, ws: ^Workspace, col_index: int) -> (Rect, bool) {
    if m == nil || o == nil || ws == nil || col_index < 0 || col_index >= len(ws.Cols) {
        return {}, false
    }
    p := compute_params(m.Cfg, o.Geom, len(ws.Cols), o.Reserved)
    if p.ColW <= 0 || p.WorkH <= 1 { return {}, false }
    col_w := column_width(p, ws.Cols[col_index])
    x := p.WorkX - ws.ViewportX + workspace_col_left(ws, p, col_index)
    preview_left, preview_right := scroll_preview_columns(ws, p)
    if (preview_left >= 0 || preview_right >= 0) && !column_has_maximized(ws.Cols[col_index]) {
        if rendered_x, rendered_w, visible := scroll_normal_col_rect(ws, p, col_index); visible {
            x, col_w = rendered_x, rendered_w
        }
    }
    // Top-level X windows cannot be clipped to an individual RandR output.
    // Do not create a decoration for a column parked outside its own output,
    // otherwise that decoration can appear on an adjacent monitor.
    if x < p.WorkX || x + col_w > p.WorkX + p.WorkW || column_has_maximized(ws.Cols[col_index]) { return {}, false }
    h := min(TAB_BAR_HEIGHT, p.WorkH - 1)
    return Rect {
        X = x,
        Y = p.WorkY,
        W = col_w,
        H = h,
    }, true
}

Drop_Kind :: enum u8 {
    None,
    Into_Column, // vertical stack / tab group
    New_Column,  // horizontal column inserted at Insert_Index
}

Drop_Zone :: enum u8 {
    None,
    Left,
    Right,
    Top,
    Bottom,
}

DROP_ZONE_HYSTERESIS  :: i32(12)

Drop_Target :: struct {
    Kind: Drop_Kind,
    Zone: Drop_Zone,
    Out: ^Output,
    Ws: ^Workspace,
    Col: ^Column,
    Insert_Index: int,
    Row_Index: int,
    Geom: Rect,    // visual/final directional target
    HitGeom: Rect, // edge activation region
}

drop_focus_column :: proc(ws: ^Workspace, dragged: ^Client) -> ^Column {
    if ws == nil || len(ws.Cols) == 0 { return nil }
    source_index := -1
    if dragged != nil && dragged.Ws == ws && !dragged.Floating {
        source_index, _, _ = column_of(ws, dragged)
    }
    if ws.Focus != nil && !ws.Focus.Floating {
        if focused_index, col, _ := column_of(ws, ws.Focus); col != nil && focused_index != source_index { return col }
    }
    // Button press focuses the dragged client before overlays are built. When
    // that makes the source column look focused, prefer its nearest neighbor.
    if source_index >= 0 && len(ws.Cols) > 1 {
        if source_index > 0 { return ws.Cols[source_index - 1] }
        return ws.Cols[source_index + 1]
    }
    return ws.Cols[0]
}

// drop_horizontal_column chooses the column a left/right drop is relative to.
// A single-window column moves one position at a time toward that direction;
// dragging a member out of a stack creates a column immediately beside its
// source. Cross-workspace/output drops use the destination's focused column.
drop_horizontal_column :: proc(ws: ^Workspace, dragged: ^Client, zone: Drop_Zone) -> ^Column {
    if ws == nil || len(ws.Cols) == 0 { return nil }
    if dragged != nil && dragged.Ws == ws && !dragged.Floating {
        source_index, source, _ := column_of(ws, dragged)
        if source != nil {
            if len(source.Wins) > 1 { return source }
            if zone == .Left && source_index > 0 { return ws.Cols[source_index - 1] }
            if zone == .Right && source_index + 1 < len(ws.Cols) { return ws.Cols[source_index + 1] }
            return source
        }
    }
    return drop_focus_column(ws, dragged)
}

drop_column_index :: proc(ws: ^Workspace, wanted: ^Column) -> int {
    if ws == nil || wanted == nil { return -1 }
    for col, i in ws.Cols { if col == wanted { return i } }
    return -1
}

// Drop_Targets creates exactly four targets per output, independent of its
// window count. Top/bottom insert into the selected column at the corresponding
// vertical edge; left/right create a column relative to a neighboring column.
// On an empty output every target creates its first column.
Drop_Targets :: proc(m: ^Manager, dragged: ^Client = nil) -> [dynamic]Drop_Target {
    if m == nil { return make([dynamic]Drop_Target, 0) }
    targets := make([dynamic]Drop_Target, 0, max(1, len(m.Outputs) * 4))
    for o in m.Outputs {
        ws := o.Current
        if ws == nil { continue }
        p := compute_params(m.Cfg, o.Geom, len(ws.Cols), o.Reserved)
        work := Rect{X = p.WorkX, Y = p.WorkY, W = p.WorkW, H = p.WorkH}
        if rect_empty(work) { continue }
        // Preserve the existing directional target geometry, but activate it
        // only near the corresponding workarea edge. The center intentionally
        // has no target so an ordinary drag does not display or apply a snap.
        top_h := max(i32(1), work.H / 3)
        middle_h := max(i32(1), work.H / 3)
        if top_h + middle_h >= work.H { middle_h = max(i32(0), work.H - top_h) }
        bottom_h := work.H - top_h - middle_h
        // Keep the four directional indicators visually balanced: horizontal
        // side width matches the vertical top-zone height.
        side_w := min(work.W, top_h)
        top := Rect{X = work.X, Y = work.Y, W = work.W, H = top_h}
        left := Rect{X = work.X, Y = work.Y, W = side_w, H = work.H}
        right := Rect{X = work.X + work.W - side_w, Y = work.Y, W = side_w, H = work.H}
        bottom := Rect{X = work.X, Y = work.Y + top_h + middle_h, W = work.W, H = bottom_h}
        // Activation and visualization deliberately share the same rectangle:
        // the overlay appears exactly as the drag crosses its inner boundary.
        left_hit := left
        right_hit := right
        top_hit := top
        bottom_hit := bottom

        vertical_col := drop_focus_column(ws, dragged)
        if vertical_col == nil {
            append(&targets, Drop_Target{Kind = .New_Column, Zone = .Left, Out = o, Ws = ws, Insert_Index = 0, Geom = left, HitGeom = left_hit})
            append(&targets, Drop_Target{Kind = .New_Column, Zone = .Right, Out = o, Ws = ws, Insert_Index = 0, Geom = right, HitGeom = right_hit})
            append(&targets, Drop_Target{Kind = .New_Column, Zone = .Top, Out = o, Ws = ws, Insert_Index = 0, Geom = top, HitGeom = top_hit})
            append(&targets, Drop_Target{Kind = .New_Column, Zone = .Bottom, Out = o, Ws = ws, Insert_Index = 0, Geom = bottom, HitGeom = bottom_hit})
        } else {
            left_col := drop_horizontal_column(ws, dragged, .Left)
            right_col := drop_horizontal_column(ws, dragged, .Right)
            left_index := drop_column_index(ws, left_col)
            right_index := drop_column_index(ws, right_col)
            append(&targets, Drop_Target{Kind = .New_Column, Zone = .Left, Out = o, Ws = ws, Col = left_col, Insert_Index = max(0, left_index), Geom = left, HitGeom = left_hit})
            append(&targets, Drop_Target{Kind = .New_Column, Zone = .Right, Out = o, Ws = ws, Col = right_col, Insert_Index = max(0, right_index + 1), Geom = right, HitGeom = right_hit})
            append(&targets, Drop_Target{Kind = .Into_Column, Zone = .Top, Out = o, Ws = ws, Col = vertical_col, Row_Index = 0, Geom = top, HitGeom = top_hit})
            append(&targets, Drop_Target{Kind = .Into_Column, Zone = .Bottom, Out = o, Ws = ws, Col = vertical_col, Row_Index = len(vertical_col.Wins), Geom = bottom, HitGeom = bottom_hit})
        }
    }
    return targets
}

drop_rect_contains :: proc(r: Rect, x, y: i32) -> bool {
    return x >= r.X && x < r.X + r.W && y >= r.Y && y < r.Y + r.H
}

drop_hit_with_hysteresis :: proc(target: Drop_Target) -> Rect {
    r := target.HitGeom
    switch target.Zone {
    case .Left:   r.W += DROP_ZONE_HYSTERESIS
    case .Right:  r.X -= DROP_ZONE_HYSTERESIS; r.W += DROP_ZONE_HYSTERESIS
    case .Top:    r.H += DROP_ZONE_HYSTERESIS
    case .Bottom: r.Y -= DROP_ZONE_HYSTERESIS; r.H += DROP_ZONE_HYSTERESIS
    case .None:
    }
    return r
}

drop_edge_distance :: proc(target: Drop_Target, x, y: i32) -> i32 {
    switch target.Zone {
    case .Left:   return x - target.HitGeom.X
    case .Right:  return target.HitGeom.X + target.HitGeom.W - 1 - x
    case .Top:    return y - target.HitGeom.Y
    case .Bottom: return target.HitGeom.Y + target.HitGeom.H - 1 - y
    case .None:   return max(i32)
    }
    return max(i32)
}

Drop_Target_At_Point :: proc(
    m: ^Manager,
    x, y: i32,
    dragged: ^Client = nil,
    current: Drop_Target = {},
) -> Drop_Target {
    targets := Drop_Targets(m, dragged)
    defer delete(targets)

    // Retain an active direction for a few extra pixels toward the center.
    // A fresh target is returned so monitor/workarea and row metadata cannot
    // become stale while a drag is in progress.
    if current.Zone != .None {
        for target in targets {
            if target.Out == current.Out && target.Zone == current.Zone &&
               drop_rect_contains(drop_hit_with_hysteresis(target), x, y) {
                return target
            }
        }
    }

    best := Drop_Target{}
    best_distance := max(i32)
    for target in targets {
        if !drop_rect_contains(target.HitGeom, x, y) { continue }
        distance := drop_edge_distance(target, x, y)
        if distance < best_distance {
            best, best_distance = target, distance
        }
    }
    return best
}

// Compatibility helper for callers that specifically want a vertical target.
Column_At_Point :: proc(m: ^Manager, x, y: i32) -> (o: ^Output, ws: ^Workspace, col: ^Column) {
    target := Drop_Target_At_Point(m, x, y)
    if target.Kind != .Into_Column { return nil, nil, nil }
    return target.Out, target.Ws, target.Col
}

// clamp_viewport keeps viewport_x inside [0, max] where max == max(0,
// total - work_w): you can never pan past the last column's right edge.
clamp_viewport :: proc(vp: i32, p: Layout_Params, n_cols: int) -> i32 {
    if n_cols <= 0 { return 0 }
    max_vp := strip_total(p, n_cols) - p.WorkW
    if max_vp < 0 { return 0 }
    if vp < 0 { return 0 }
    if vp > max_vp { return max_vp }
    return vp
}

strip_total :: proc(p: Layout_Params, n_cols: int) -> i32 {
    total, _ := strip_geometry(p, n_cols)
    return total
}

// ensure_col_visible adjusts vp (the viewport) minimally so that the column
// spanning [col_left, col_left+col_w] is fully visible. Returns the new vp.
ensure_col_visible :: proc(vp: i32, p: Layout_Params, n_cols: int, col_left: i32) -> i32 {
    if n_cols <= 0 { return 0 }
    v := vp
    col_right := col_left + p.ColW
    if col_left >= v && col_right <= v + p.WorkW {
        return clamp_viewport(v, p, n_cols)
    }
    if col_left < v {
        v = col_left // off the left → bring its left edge back in view
    } else {
        v = col_left + p.ColW - p.WorkW // off the right → align its right edge
    }
    return clamp_viewport(v, p, n_cols)
}

// inset_rect returns the client rectangle that, with a `border` ring drawn
// around it, exactly fills `tile`.
inset_rect :: proc(tile: Rect, border: i32) -> Rect {
    b := border
    if tile.W <= 2 * b || tile.H <= 2 * b { b = 0 }
    return Rect {
        X = tile.X + b,
        Y = tile.Y + b,
        W = tile.W - 2 * b,
        H = tile.H - 2 * b,
    }
}

// ----------------------------------------------------------------------------
// Arrange
// ----------------------------------------------------------------------------

// arrange_workspace lays one workspace out into per-client rects.
//
// When `on_screen` is true the windows are positioned relative to the current
// workspace viewport. When false (an inactive workspace) every window is parked
// far off-screen so it can never be seen or pointed at; the viewport value is
// left untouched so the workspace reappears where it was when reactivated.
//
// A fullscreen client (which, by invariant, is the workspace focus while shown)
// covers the whole output and every other window of the workspace is hidden.
arrange_workspace :: proc(ws: ^Workspace, p: Layout_Params, geom: Rect, on_screen: bool) {
    if ws == nil { return }
    n_cols := len(ws.Cols)

    if !on_screen {
        hide := Rect { X = geom.X + HIDE_X, Y = geom.Y, W = geom.W, H = geom.H }
        for col in ws.Cols {
            for cl in col.Wins { cl.Geom = hide; cl.Border = p.Border }
        }
        for cl in ws.Floaters { cl.Geom = hide; cl.Border = p.Border }
        return
    }

    // Active workspace.
    // 1) fullscreen cover
    if ws.Focus != nil && ws.Focus.Fullscreen && find_client_in_ws(ws, ws.Focus.Xid) != nil {
        fs := ws.Focus
        fs.Geom = geom
        fs.Border = 0
        hide := Rect { X = geom.X + HIDE_X, Y = geom.Y, W = geom.W, H = geom.H }
        for col in ws.Cols {
            for cl in col.Wins {
                if cl != fs { cl.Geom = hide; cl.Border = p.Border }
            }
        }
        for cl in ws.Floaters {
            if cl != fs { cl.Geom = hide; cl.Border = p.Border }
        }
        return
    }

    // 2) tiled columns
    if n_cols > 0 && p.ColW > 0 && p.WorkH > 0 {
        base_x := p.WorkX - ws.ViewportX
        hide := Rect { X = geom.X + HIDE_X, Y = geom.Y, W = geom.W, H = geom.H }
        preview_left, preview_right := scroll_preview_columns(ws, p)
        for ci in 0 ..< n_cols {
            col := ws.Cols[ci]
            nw := len(col.Wins)
            if nw == 0 { continue }
            col_w := column_width(p, col)
            col_left := base_x + workspace_col_left(ws, p, ci)
            is_preview := ci == preview_left || ci == preview_right
            if ci == preview_left {
                col_left = p.WorkX + min(SCROLL_PREVIEW_WIDTH, col_w) - col_w
            } else if ci == preview_right {
                col_left = p.WorkX + p.WorkW - min(SCROLL_PREVIEW_WIDTH, col_w)
            } else if (preview_left >= 0 || preview_right >= 0) && !column_has_maximized(col) {
                rendered_x, rendered_w, visible := scroll_normal_col_rect(ws, p, ci)
                if !visible {
                    for cl in col.Wins {
                        cl.Geom = hide
                        cl.Border = p.Border
                    }
                    continue
                }
                col_left, col_w = rendered_x, rendered_w
            }

            // A maximized column is one full page. While scrolling between it
            // and a neighbor, translate the complete maximized rectangle: the
            // root viewport naturally reveals only the on-screen portion, but
            // the client remains maximized and the following column stays
            // directly adjacent in strip coordinates.
            if column_has_maximized(col) {
                if col_left + col_w <= p.WorkX || col_left >= p.WorkX + p.WorkW {
                    for cl in col.Wins {
                        cl.Geom = hide
                        cl.Border = p.Border
                    }
                    continue
                }
                tile := Rect{X = col_left, Y = p.WorkY, W = col_w, H = p.WorkH}
                for cl in col.Wins {
                    cl.Border = p.Border
                    if cl.Maximized { cl.Geom = inset_rect(tile, p.Border) } else { cl.Geom = hide }
                }
                continue
            }

            // RandR outputs share one root window, so a normal column outside
            // this output would otherwise remain visible on a neighbouring one.
            // Park normal columns unless their complete tile belongs to this page.
            if !is_preview && (col_left < p.WorkX || col_left + col_w > p.WorkX + p.WorkW) {
                for cl in col.Wins {
                    cl.Geom = hide
                    cl.Border = p.Border
                }
                continue
            }

            if col.Layout == .Tabbed {
                active := col.Focus
                if active == nil || !column_member(col, active) {
                    active = col.Wins[0]
                    col.Focus = active
                }
                tab_h := min(TAB_BAR_HEIGHT, max(i32(0), p.WorkH - 1))
                tile := Rect { X = col_left, Y = p.WorkY + tab_h, W = col_w, H = p.WorkH - tab_h }
                for cl in col.Wins {
                    cl.Border = p.Border
                    if cl == active {
                        cl.Geom = inset_rect(tile, p.Border)
                    } else {
                        cl.Geom = hide
                    }
                }
                continue
            }

            avail := p.WorkH
            content := avail - p.Inner * i32(nw - 1)
            if content < i32(nw) { content = i32(nw) }

            total_weight := f64(0)
            positive_weights := 0
            for cl in col.Wins {
                if cl.TileWeight > 0 {
                    total_weight += cl.TileWeight
                    positive_weights += 1
                }
            }
            // A default/new row must use the same scale as existing weights.
            // Using literal 1 beside weights captured as pixel heights is what
            // previously collapsed newly inserted windows to almost nothing.
            default_weight := f64(1)
            if positive_weights > 0 { default_weight = total_weight / f64(positive_weights) }
            total_weight += default_weight * f64(nw - positive_weights)
            heights := make([]i32, nw)
            used := i32(0)
            distributable := content - i32(nw)
            for cl, i in col.Wins {
                weight := cl.TileWeight
                if weight <= 0 { weight = default_weight }
                heights[i] = 1 + i32(f64(distributable) * weight / total_weight)
                used += heights[i]
            }
            // Flooring leaves fewer than nw pixels. Match the historic layout
            // by handing remainder pixels to rows from the top downward.
            rem := content - used
            for i := 0; rem > 0; i = (i + 1) % nw {
                heights[i] += 1
                rem -= 1
            }

            y := p.WorkY
            for i in 0 ..< nw {
                h := heights[i]
                tile := Rect { X = col_left, Y = y, W = col_w, H = h }
                cl := col.Wins[i]
                cl.Geom = inset_rect(tile, p.Border)
                cl.Border = p.Border
                y += h + p.Inner
            }
            delete(heights)
        }
    }

    // 3) floating windows keep their own geometry
    for fl in ws.Floaters {
        fl.Border = p.Border
        r := fl.FloatingRect
        if rect_empty(r) { r = default_float_rect(p, geom) }
        r = clamp_float_rect(r, geom)
        fl.Geom = inset_rect(r, p.Border)
    }

    // 4) maximized floaters temporarily override their saved floating geometry.
    // Tiled maximize is handled as a full-width strip column above so it
    // displaces, rather than overlaps, neighboring columns.
    for cl in ws.Floaters {
        if cl.Maximized {
            cl.Border = p.Border
            cl.Geom = inset_rect(Rect{X = p.WorkX, Y = p.WorkY, W = p.WorkW, H = p.WorkH}, p.Border)
        }
    }
}

// default_float_rect centers a floating window in the work area at ~60% size.
default_float_rect :: proc(p: Layout_Params, geom: Rect) -> Rect {
    w := geom.W * 3 / 5
    h := geom.H * 3 / 5
    if w > p.WorkW { w = p.WorkW }
    if h > p.WorkH { h = p.WorkH }
    return Rect {
        X = geom.X + (geom.W - w) / 2,
        Y = geom.Y + (geom.H - h) / 2,
        W = w,
        H = h,
    }
}

// clamp_float_rect nudges a floating rect so part of it stays reachable.
clamp_float_rect :: proc(r: Rect, geom: Rect) -> Rect {
    res := r
    if res.W < 40 { res.W = 40 }
    if res.H < 20 { res.H = 20 }
    if res.X + 40 > geom.X + geom.W { res.X = geom.X + geom.W - 40 }
    if res.X < geom.X - res.W + 40 { res.X = geom.X - res.W + 40 }
    if res.Y + 20 > geom.Y + geom.H { res.Y = geom.Y + geom.H - 20 }
    if res.Y < geom.Y - res.H + 20 { res.Y = geom.Y - res.H + 20 }
    return res
}

// Arrange_All recomputes every window rect: the current workspace on screen,
// all others hidden, and output docks at their requested geometry. X stacking
// keeps docks above normal windows and below fullscreen. Call after any
// structural or viewport change, then hand the resulting rects to the X layer.
Arrange_All :: proc(m: ^Manager) {
    for o in m.Outputs {
        cur := o.Current
        if cur != nil {
            p := compute_params(m.Cfg, o.Geom, len(cur.Cols), o.Reserved)
            arrange_workspace(cur, p, o.Geom, true)
        }
        for ws in o.Ws {
            if ws == cur { continue }
            p := compute_params(m.Cfg, o.Geom, len(ws.Cols), o.Reserved)
            arrange_workspace(ws, p, o.Geom, false)
        }
        // Docks belong to an output rather than a workspace and remain visible
        // regardless of that output's selected workspace.
        for d in o.Docks {
            r := d.FloatingRect
            if rect_empty(r) {
                r = Rect { X = o.Geom.X, Y = o.Geom.Y, W = o.Geom.W, H = 24 }
            }
            d.Geom = clamp_float_rect(r, o.Geom)
            d.Border = 0
        }
    }
    // Scratchpads are workspace-less while hidden, so no output layout pass
    // above sees them. Keep them mapped but safely outside the root geometry.
    for cl in m.Clients {
        if cl.Stashed {
            cl.Geom = Rect { X = HIDE_X, Y = 0, W = max(cl.Geom.W, i32(1)), H = max(cl.Geom.H, i32(1)) }
            cl.Border = m.Cfg.BorderWidth
        }
    }
}
