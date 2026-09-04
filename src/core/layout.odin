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
// Work area = output rectangle inset by `outer`, and further by a dock's
// reserved edge when the reservation exceeds the outer gap:
//     work_x = geom.X + max(outer, res.left)  ; work_w = geom.W - max(outer, res.left) - max(outer, res.right)
//     work_y = geom.Y + max(outer, res.top)   ; work_h = geom.H - max(outer, res.top)  - max(outer, res.bottom)
// A zero `res` reproduces the plain outer-gap inset.
//
// Columns are uniform width derived per workspace (see Resolve_Page_Width):
// fewer columns than a screen page (PAGE_COLS) expand to fill the work width;
// with PAGE_COLS or more each column is one page width so exactly PAGE_COLS fit
// on screen and further columns overflow to the right and scroll. Windows in a
// stacked column divide the column height minus `inner` gaps. A tabbed column
// gives its full rectangle to the active tab and parks its sibling tabs off
// screen while keeping them mapped.
//
// Each window's `Geom` is the *client* box inset by its border, so the X border
// ring lies strictly inside its tile and never overlaps neighbours:
//     client_geom = tile grown inward by `border`

HIDE_X :: -20000 // park off-screen windows here (kept within X int16 range)
PAGE_COLS :: 2 // columns that fit on screen before the strip starts scrolling
TAB_BAR_HEIGHT :: i32(24)

Layout_Params :: struct {
    WorkX, WorkY: i32,
    WorkW, WorkH: i32,
    ColW: i32, // width of every column (uniform)
    Inner: i32, // gap between columns and between windows in a column
    Border: i32, // per-window X border
}

compute_params :: proc(cfg: Config, geom: Rect, n_cols: int, res: Insets = {}) -> (p: Layout_Params) {
    p.WorkX = geom.X + max(cfg.OuterGap, res.Left)
    p.WorkY = geom.Y + max(cfg.OuterGap, res.Top)
    p.WorkW = geom.W - max(cfg.OuterGap, res.Left) - max(cfg.OuterGap, res.Right)
    p.WorkH = geom.H - max(cfg.OuterGap, res.Top) - max(cfg.OuterGap, res.Bottom)
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

// Tab_Bar_Rect returns the root-coordinate strip reserved above a tabbed
// column. The X layer uses it to draw decorations without duplicating layout
// calculations.
Tab_Bar_Rect :: proc(m: ^Manager, o: ^Output, ws: ^Workspace, col_index: int) -> (Rect, bool) {
    if m == nil || o == nil || ws == nil || col_index < 0 || col_index >= len(ws.Cols) {
        return {}, false
    }
    p := compute_params(m.Cfg, o.Geom, len(ws.Cols), o.Reserved)
    if p.ColW <= 0 || p.WorkH <= 1 { return {}, false }
    h := min(TAB_BAR_HEIGHT, p.WorkH - 1)
    return Rect {
        X = p.WorkX - ws.ViewportX + col_left_px(p, col_index),
        Y = p.WorkY,
        W = p.ColW,
        H = h,
    }, true
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
        for ci in 0 ..< n_cols {
            col := ws.Cols[ci]
            nw := len(col.Wins)
            if nw == 0 { continue }
            col_left := base_x + col_left_px(p, ci)

            if col.Layout == .Tabbed {
                active := col.Focus
                if active == nil || !column_member(col, active) {
                    active = col.Wins[0]
                    col.Focus = active
                }
                tab_h := min(TAB_BAR_HEIGHT, max(i32(0), p.WorkH - 1))
                tile := Rect { X = col_left, Y = p.WorkY + tab_h, W = p.ColW, H = p.WorkH - tab_h }
                hide := Rect { X = geom.X + HIDE_X, Y = geom.Y, W = geom.W, H = geom.H }
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
            base_h := content / i32(nw)
            rem := content % i32(nw)

            y := p.WorkY
            for i in 0 ..< nw {
                h := base_h
                if i32(i) < rem { h += 1 }
                tile := Rect { X = col_left, Y = y, W = p.ColW, H = h }
                cl := col.Wins[i]
                cl.Geom = inset_rect(tile, p.Border)
                cl.Border = p.Border
                y += h + p.Inner
            }
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
// all others hidden, docks on top of the output. Call after any structural or
// viewport change, then hand the resulting rects to the X layer.
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
}
