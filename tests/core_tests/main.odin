// Unit tests for the pure core model (src/core), which has no X11 dependency.
//
// Run from the repository root:
//     odin run tests/core_tests
//
// Self-contained runner (no `odin test` harness dependency): every check is a
// hand-written assertion; failures print and bump a counter; exit code is 0 on
// success, 1 on any failure.

package main

import "core:fmt"
import "core:os"
import "core:strings"
import c "../../src/core"

g_fail: int
g_pass: int

ok :: proc(cond: bool, msg: string, args: ..any) {
    if cond {
        g_pass += 1
    } else {
        g_fail += 1
        fmt.eprintln("FAIL:", fmt.tprintf(msg, ..args))
    }
}

eq :: proc(got, want: $T, msg: string, args: ..any) {
    if got == want {
        g_pass += 1
    } else {
        g_fail += 1
        fmt.eprintln("FAIL:", fmt.tprintf(msg, ..args), " got=", got, " want=", want)
    }
}

GEOM :: c.Rect{X = 0, Y = 0, W = 1920, H = 1080}

main :: proc() {
    test_config()
    test_animation_math()
    test_resize_math()
    test_workspaces()
    test_add_and_focus()
    test_focus_direction()
    test_move_dir()
    test_pointer_column_move()
    test_pointer_tabbed_drop()
    test_pointer_tabbed_column_drop()
    test_relative_column_drop()
    test_unmanage()
    test_floating()
    test_fullscreen()
    test_maximize()
    test_tabbed_layout()
    test_multi_output()
    test_multi_output_scrolling()
    test_layout_geometry()
    test_scrolling()
    test_scroll_previews()
    test_two_columns_fit()
    test_borderless_layout()
    test_arrange_hidden()
    test_move_to_ws()
    test_scratchpads()
    test_dock_model()
    test_dock_geometry_and_struts()
    test_dock_sticky()
    test_dock_fullscreen_coexists()
    test_dock_unmanage_restores()
    test_dock_reserved_ensure_visible()
    test_ipc_frames()
    test_ipc_workspaces_payload()
    test_ipc_outputs_payload()
    test_ipc_windows_payload()
    test_ipc_ws_event_payload()
    test_ipc_command_reply_payload()
    test_ipc_parse_subscribe()
    test_ipc_parse_command()

    fmt.printf("\n%d passed, %d failed\n", g_pass, g_fail)
    if g_fail > 0 {
        fmt.eprintln("UNIT TESTS FAILED")
        os.exit(1)
    }
}

// ----------------------------------------------------------------------------
// helpers
// ----------------------------------------------------------------------------

mk_man :: proc() -> ^c.Manager {
    m := c.New_Manager()
    c.Setup_Output(m, "eDP-1", GEOM)
    return m
}

// add_tiled adds a fresh tiled window to the manager's current workspace and
// returns it. With the default layout each new window becomes a new column to
// the right of the focused column, so sequential calls give cols [a][b][d]…
add_tiled :: proc(m: ^c.Manager, id: u32) -> ^c.Client {
    cl := c.New_Client(id)
    ws := c.Current_WS(m)
    c.Add_Managed(m, ws, cl, false)
    return cl
}

// add_dock registers a dock client (panel) on the active output claiming
// `strut` and sitting at `rect`. A zero rect exercises the default top strip.
add_dock :: proc(m: ^c.Manager, id: u32, strut: c.Insets, rect: c.Rect) -> ^c.Client {
    cl := c.New_Client(id)
    cl.Strut = strut
    cl.FloatingRect = rect
    c.Add_Dock(m, cl)
    return cl
}

// ----------------------------------------------------------------------------
// config / width resolution
// ----------------------------------------------------------------------------

test_config :: proc() {
    cfg := c.Default_Config()
    eq(cfg.OuterGap, 8, "default outer gap")
    eq(cfg.InnerGap, 8, "default inner gap")
    eq(cfg.BorderWidth, 2, "default border")
    eq(cfg.CornerRadius, 0, "rounded corners disabled by default")
    ok(cfg.FocusFollowsMouse, "default focus-follows-mouse")
    ok(cfg.Animations, "animations enabled by default")
    eq(cfg.AnimationDurationMs, i32(180), "default animation duration")
    eq(cfg.AnimationFps, i32(60), "default animation frame rate")
    eq(cfg.AnimationEasing, c.Animation_Easing.Ease_Out_Cubic, "default animation easing")
    ok(!cfg.BarEnabled, "built-in bar is opt-in")
    eq(cfg.BarPosition, c.Bar_Position.Top, "default bar position")
    eq(cfg.BarHeight, i32(26), "default bar height")
    eq(cfg.BarForeground, u32(0xE6E6E6), "default bar foreground")
    eq(cfg.BarBackground, u32(0x1E1E2E), "default bar background")

    gapped := cfg
    gapped.Gap = 16
    c.Apply_Gap_Alias(&gapped)
    eq(gapped.OuterGap, 16, "Gap alias seeds OuterGap")
    eq(gapped.InnerGap, 16, "Gap alias seeds InnerGap")

    // column widths are derived from the column count (work width = 1920-2*8 = 1904)
    eq(c.Resolve_Page_Width(1904, 8, 1), 1904, "1 column fills the work width")
    eq(c.Resolve_Page_Width(1904, 8, 2), 948, "2 columns -> page width (1904-8)/2")
    eq(c.Resolve_Page_Width(1904, 8, 3), 948, "3+ columns keep the same page width")
    eq(2 * c.Resolve_Page_Width(1904, 8, 2) + 8, 1904, "two pages + one inner gap fill the screen")
    eq(c.Resolve_Page_Width(100, 8, 2), 60, "page width floored at 60 px")
}

test_animation_math :: proc() {
    eq(c.Animation_Progress(-1, 100), f64(0), "animation progress clamps negative elapsed")
    eq(c.Animation_Progress(50, 100), f64(0.5), "animation progress uses elapsed time")
    eq(c.Animation_Progress(100, 100), f64(1), "animation progress completes exactly")
    eq(c.Animation_Progress(1, 0), f64(1), "zero duration completes immediately")

    eq(c.Animation_Ease(.Linear, 0.4), f64(0.4), "linear easing preserves progress")
    eq(c.Animation_Ease(.Ease_Out_Cubic, 0.5), f64(0.875), "ease-out cubic curve")
    eq(c.Animation_Ease(.Ease_Out_Cubic, 2), f64(1), "easing clamps high input")

    start := c.Rect{X = 0, Y = 10, W = 100, H = 50}
    target := c.Rect{X = 101, Y = -10, W = 201, H = 100}
    eq(c.Animation_Lerp_Rect(start, target, 0), start, "rect interpolation starts exactly")
    eq(c.Animation_Lerp_Rect(start, target, 1), target, "rect interpolation ends exactly")
    eq(
        c.Animation_Lerp_Rect(start, target, 0.5),
        c.Rect{X = 51, Y = 0, W = 151, H = 75},
        "rect interpolation rounds consistently",
    )
}

test_resize_math :: proc() {
    first, second := c.Resize_Pair(500, 500, 200, 100, 100)
    eq(first, i32(700), "paired resize grows first side")
    eq(second, i32(300), "paired resize shrinks following side")
    first, second = c.Resize_Pair(500, 500, 900, 100, 100)
    eq(first, i32(900), "paired resize honors neighbor minimum")
    eq(second, i32(100), "paired resize keeps neighbor positive")
    first, second = c.Resize_Pair(500, 500, 300, 100, 100, 600, 0)
    eq(first, i32(600), "paired resize honors first maximum")
    eq(first + second, i32(1000), "paired resize preserves total extent")

    hints := c.Size_Hints{
        MinW = 100, MinH = 80, MaxW = 500, MaxH = 400,
        BaseW = 100, BaseH = 80, IncW = 20, IncH = 10,
    }
    w, h := c.Constrain_Size(hints, 337, 249)
    eq(w, i32(320), "size hints apply width base/increment")
    eq(h, i32(240), "size hints apply height base/increment")
    w, h = c.Constrain_Size(hints, 20, 900)
    eq(w, i32(100), "size hints enforce minimum")
    eq(h, i32(400), "size hints enforce maximum")

    keyboard_horizontal := mk_man()
    defer c.Destroy_Manager(keyboard_horizontal)
    c.Activate_WS(keyboard_horizontal, c.Ensure_WS(keyboard_horizontal, 1))
    kha := add_tiled(keyboard_horizontal, 291)
    khb := add_tiled(keyboard_horizontal, 292)
    c.Arrange_All(keyboard_horizontal)
    kha_before := kha.Geom.W + 2 * keyboard_horizontal.Cfg.BorderWidth
    khb_before := khb.Geom.W + 2 * keyboard_horizontal.Cfg.BorderWidth
    ok(c.Resize_Focused(keyboard_horizontal, .Left),
       "keyboard left resize grows the focused column")
    c.Arrange_All(keyboard_horizontal)
    kha_after := kha.Geom.W + 2 * keyboard_horizontal.Cfg.BorderWidth
    khb_after := khb.Geom.W + 2 * keyboard_horizontal.Cfg.BorderWidth
    eq(kha_after, kha_before,
       "keyboard width resize leaves neighboring columns unchanged")
    eq(khb_after, khb_before - c.KEYBOARD_RESIZE_STEP,
       "keyboard left resize shrinks the focused column by one step")
    ok(c.Resize_Focused(keyboard_horizontal, .Right),
       "keyboard right resize grows the focused column again")
    c.Arrange_All(keyboard_horizontal)
    eq(khb.Geom.W + 2 * keyboard_horizontal.Cfg.BorderWidth, khb_before,
       "opposite keyboard width steps are reversible")

    keyboard_vertical := mk_man()
    defer c.Destroy_Manager(keyboard_vertical)
    c.Activate_WS(keyboard_vertical, c.Ensure_WS(keyboard_vertical, 1))
    kva := add_tiled(keyboard_vertical, 293)
    kvb := add_tiled(keyboard_vertical, 294)
    ok(c.Move_Dir(keyboard_vertical, .Left),
       "keyboard row resize fixture creates a vertical stack")
    c.Arrange_All(keyboard_vertical)
    kva_before := kva.Geom.H + 2 * keyboard_vertical.Cfg.BorderWidth
    kvb_before := kvb.Geom.H + 2 * keyboard_vertical.Cfg.BorderWidth
    ok(c.Resize_Focused(keyboard_vertical, .Up),
       "keyboard up resize grows the focused stacked row")
    c.Arrange_All(keyboard_vertical)
    kva_after := kva.Geom.H + 2 * keyboard_vertical.Cfg.BorderWidth
    kvb_after := kvb.Geom.H + 2 * keyboard_vertical.Cfg.BorderWidth
    ok(abs((kva_after - kva_before) - c.KEYBOARD_RESIZE_STEP) <= 1,
       "other rows proportionally receive the released height")
    ok(abs((kvb_before - kvb_after) - c.KEYBOARD_RESIZE_STEP) <= 1,
       "keyboard up resize shrinks the focused row by one step")
    eq(kva_after + kvb_after, kva_before + kvb_before,
       "keyboard row resize preserves the pair extent")
    ok(c.Resize_Focused(keyboard_vertical, .Down),
       "keyboard down resize grows the focused row again")
    c.Arrange_All(keyboard_vertical)
    ok(abs((kvb.Geom.H + 2 * keyboard_vertical.Cfg.BorderWidth) - kvb_before) <= 1,
       "opposite keyboard height steps are reversible")

    m := mk_man()
    defer c.Destroy_Manager(m)
    c.Activate_WS(m, c.Ensure_WS(m, 1))
    a := add_tiled(m, 301)
    b := add_tiled(m, 302)
    ws := c.Current_WS(m)
    ws.Cols[0].Width = 700
    ws.Cols[1].Width = 1196
    c.Arrange_All(m)
    eq(a.Geom, c.Rect{X = 10, Y = 10, W = 696, H = 1060}, "unfocused resized tile reserves the border inset")
    eq(b.Geom, c.Rect{X = 718, Y = 10, W = 1192, H = 1060}, "adjacent resized column follows boundary")

    ok(c.Move_Dir(m, .Left), "resize row fixture stacks windows")
    a.TileWeight, b.TileWeight = 3, 1
    c.Arrange_All(m)
    eq(a.Geom.Y, i32(10), "unfocused weighted row reserves its border inset")
    eq(a.Geom.H, i32(788), "unfocused weighted row keeps stable bordered geometry")
    eq(b.Geom.Y, i32(810), "following row moves with resized boundary")
    eq(b.Geom.H, i32(260), "following row consumes remaining column height")

    inserted := mk_man()
    defer c.Destroy_Manager(inserted)
    c.Activate_WS(inserted, c.Ensure_WS(inserted, 1))
    ia := add_tiled(inserted, 311)
    ib := add_tiled(inserted, 312)
    iws := c.Current_WS(inserted)
    iws.Cols[0].Width = 700
    iws.Cols[1].Width = 1196
    c.Arrange_All(inserted)
    _ = ia
    id := add_tiled(inserted, 313)
    c.Ensure_Active_Focus_Visible(inserted)
    c.Arrange_All(inserted)
    // With no natural edge intersection, reserve the narrow hover preview and
    // fit the visible page between it. When spare space exists elsewhere, the
    // contiguous custom-width path below keeps all widths unchanged instead.
    eq(ib.Geom, c.Rect{X = 38, Y = 10, W = 1174, H = 1060}, "resized page reserves its hidden-neighbor preview")
    eq(id.Geom, c.Rect{X = 1224, Y = 10, W = 686, H = 1060}, "new column keeps the normal gap inside the reserved page")
    inserted_previews := c.Scroll_Previews(inserted, c.Active_Output(inserted))
    eq(len(inserted_previews), 1, "fully hidden neighbor retains a hover preview after resizing")
    if len(inserted_previews) == 1 {
        eq(inserted_previews[0].Client, ia, "resized page preview targets the hidden neighboring window")
        eq(inserted_previews[0].Side, c.Scroll_Preview_Side.Left, "hidden neighbor is exposed on the correct edge")
    }
    delete(inserted_previews)

    reordered := mk_man()
    defer c.Destroy_Manager(reordered)
    c.Activate_WS(reordered, c.Ensure_WS(reordered, 1))
    ra := add_tiled(reordered, 321)
    rb := add_tiled(reordered, 322)
    rws := c.Current_WS(reordered)
    rws.Cols[0].Width = 700
    rws.Cols[1].Width = 1196
    ok(c.Move_Client_To_Drop(reordered, rb, c.Drop_Target{
        Kind = .New_Column, Out = rb.Out, Ws = rws, Insert_Index = 0,
    }), "resized column can be reordered")
    eq(rws.Cols[0].Wins[0], rb, "reordered client enters requested column position")
    eq(rws.Cols[0].Width, i32(1196), "horizontal drop carries resized column width")
    _ = ra

    stacked := mk_man()
    defer c.Destroy_Manager(stacked)
    c.Activate_WS(stacked, c.Ensure_WS(stacked, 1))
    sa := add_tiled(stacked, 331)
    sb := add_tiled(stacked, 332)
    sws := c.Current_WS(stacked)
    sws.Cols[0].Width = 700
    ok(c.Move_Client_To_Drop(stacked, sa, c.Drop_Target{
        Kind = .Into_Column, Out = sb.Out, Ws = sws, Col = sws.Cols[1], Row_Index = 0,
    }), "resized column can be stacked by drop")
    eq(len(sws.Cols), 1, "stacking drop removes emptied source column")
    eq(sws.Cols[0].Width, i32(700), "stacking drop preserves explicit source width")
    c.Arrange_All(stacked)
    eq(sa.Geom.W, i32(696), "lone resized stack does not expand to full screen")
    eq(sb.Geom.W, i32(696), "unfocused windows reserve the same border inset")

    new_after_resize := mk_man()
    defer c.Destroy_Manager(new_after_resize)
    c.Activate_WS(new_after_resize, c.Ensure_WS(new_after_resize, 1))
    na := add_tiled(new_after_resize, 341)
    nws := c.Current_WS(new_after_resize)
    nws.Cols[0].Width = 700
    nb := add_tiled(new_after_resize, 342)
    no := c.Active_Output(new_after_resize)
    work_w := no.Geom.W - 2 * new_after_resize.Cfg.OuterGap - no.Reserved.Left - no.Reserved.Right
    placed_w := c.Column_Width_At(new_after_resize, no, nws, 0) +
        new_after_resize.Cfg.InnerGap + c.Column_Width_At(new_after_resize, no, nws, 1)
    eq(placed_w, work_w, "new column complements a lone resized column without empty space")
    _ = na
    _ = nb

    close_after_resize := mk_man()
    defer c.Destroy_Manager(close_after_resize)
    c.Activate_WS(close_after_resize, c.Ensure_WS(close_after_resize, 1))
    ca := add_tiled(close_after_resize, 351)
    cb := add_tiled(close_after_resize, 352)
    cc := add_tiled(close_after_resize, 353)
    cd := add_tiled(close_after_resize, 354)
    cws := c.Current_WS(close_after_resize)
    cws.Cols[0].Width = 700
    cws.Cols[1].Width = 1196
    c.Unmanage_Client(close_after_resize, cb)
    cws.ViewportX = 0
    c.Arrange_All(close_after_resize)
    eq(cws.Cols[0].Width, i32(700), "closing a column does not resize a visible survivor")
    eq(cws.Cols[1].Width, i32(0), "closing a column does not resize a hidden survivor")
    eq(cws.Cols[2].Width, i32(0), "later hidden columns retain their natural width")
    cborder := close_after_resize.Cfg.BorderWidth
    first_gap := (cc.Geom.X - cborder) - (ca.Geom.X + ca.Geom.W + cborder)
    next_gap := (cd.Geom.X - cborder) - (cc.Geom.X + cc.Geom.W + cborder)
    eq(first_gap, close_after_resize.Cfg.InnerGap,
       "surviving column moves directly beside the resized column")
    eq(next_gap, close_after_resize.Cfg.InnerGap,
       "partially visible next column continues with the normal gap")
    ok(cd.Geom.X < 1920 && cd.Geom.X + cd.Geom.W > 1920,
       "next hidden column fills the remaining area without being resized")
    custom_previews := c.Scroll_Previews(close_after_resize, c.Active_Output(close_after_resize))
    eq(len(custom_previews), 1, "partially visible custom-width neighbor remains hoverable")
    if len(custom_previews) == 1 {
        eq(custom_previews[0].Client, cd, "custom-width preview targets the real intersecting window")
        eq(custom_previews[0].Side, c.Scroll_Preview_Side.Right, "custom-width continuation uses the right edge")
    }
    delete(custom_previews)

    cws.ViewportX = 9999
    c.Arrange_All(close_after_resize)
    co := c.Active_Output(close_after_resize)
    cwork_w := co.Geom.W - 2 * close_after_resize.Cfg.OuterGap - co.Reserved.Left - co.Reserved.Right
    content_w := c.Column_Width_At(close_after_resize, co, cws, 0) +
        c.Column_Width_At(close_after_resize, co, cws, 1) +
        c.Column_Width_At(close_after_resize, co, cws, 2) +
        2 * close_after_resize.Cfg.InnerGap
    eq(cws.ViewportX, content_w - cwork_w,
       "stale viewport clamps so the strip cannot leave empty space at the right")
    eq(cd.Geom.X + cd.Geom.W + cborder,
       co.Geom.X + co.Geom.W - close_after_resize.Cfg.OuterGap - co.Reserved.Right,
       "last unchanged column is pulled flush to the work-area edge")
    _ = ca
    _ = cc
    _ = cd

    rows_after_resize := mk_man()
    defer c.Destroy_Manager(rows_after_resize)
    c.Activate_WS(rows_after_resize, c.Ensure_WS(rows_after_resize, 1))
    va := add_tiled(rows_after_resize, 361)
    vb := add_tiled(rows_after_resize, 362)
    ok(c.Move_Dir(rows_after_resize, .Left), "row reset fixture creates a stack")
    va.TileWeight, vb.TileWeight = 800, 200
    vc := add_tiled(rows_after_resize, 363)
    ok(c.Move_Dir(rows_after_resize, .Left), "new window joins the resized stack")
    vws := c.Current_WS(rows_after_resize)
    weight_sum := va.TileWeight + vb.TileWeight + vc.TileWeight
    ok(abs(weight_sum - 1) < 0.000001, "stack membership change normalizes resize weights")
    ok(vc.TileWeight > 0.25, "new row receives a useful share instead of pixel weight one")
    c.Arrange_All(rows_after_resize)
    vborder := rows_after_resize.Cfg.BorderWidth
    vb_gap := (vb.Geom.Y - vborder) - (va.Geom.Y + va.Geom.H + vborder)
    vc_gap := (vc.Geom.Y - vborder) - (vb.Geom.Y + vb.Geom.H + vborder)
    eq(vb_gap, rows_after_resize.Cfg.InnerGap, "existing and inserted rows retain the normal gap")
    eq(vc_gap, rows_after_resize.Cfg.InnerGap, "new row aligns with the same normal gap")
    va.TileWeight, vb.TileWeight, vc.TileWeight = 600, 300, 100
    c.Focus_Client(rows_after_resize, vc)
    ok(c.Move_Dir(rows_after_resize, .Up), "resized row can be reordered")
    ok(abs(vws.Cols[0].Wins[0].TileWeight - 0.6) < 0.000001,
       "row reorder preserves the first size slot")
    ok(abs(vws.Cols[0].Wins[1].TileWeight - 0.3) < 0.000001,
       "reordered row takes the destination size slot")
    ok(abs(vws.Cols[0].Wins[2].TileWeight - 0.1) < 0.000001,
       "displaced row takes the source size slot")
    va.TileWeight, vb.TileWeight, vc.TileWeight = 600, 300, 100
    c.Unmanage_Client(rows_after_resize, vc)
    c.Arrange_All(rows_after_resize)
    ok(abs(va.TileWeight + vb.TileWeight - 1) < 0.000001,
       "closing a resized row renormalizes the surviving proportions")
    remaining_gap := (vb.Geom.Y - vborder) - (va.Geom.Y + va.Geom.H + vborder)
    eq(remaining_gap, rows_after_resize.Cfg.InnerGap,
       "rows retain the normal gap after closing a resized neighbor")

    vertical_preview := mk_man()
    defer c.Destroy_Manager(vertical_preview)
    c.Activate_WS(vertical_preview, c.Ensure_WS(vertical_preview, 1))
    pa := add_tiled(vertical_preview, 371)
    pb := add_tiled(vertical_preview, 372)
    pc := add_tiled(vertical_preview, 373)
    pd := add_tiled(vertical_preview, 374)
    pe := add_tiled(vertical_preview, 375)
    pws := c.Current_WS(vertical_preview)
    for col in pws.Cols { col.Width = 700 }
    ok(c.Move_Client_To_Drop(vertical_preview, pd, c.Drop_Target{
        Kind = .Into_Column, Out = pd.Out, Ws = pws, Col = pws.Cols[2], Row_Index = 1,
    }), "vertical preview fixture creates a middle stack")
    ok(c.Move_Dir(vertical_preview, .Up), "middle stack can be reordered vertically")
    c.Ensure_Active_Focus_Visible(vertical_preview)
    c.Arrange_All(vertical_preview)
    mixed_previews := c.Scroll_Previews(vertical_preview, c.Active_Output(vertical_preview))
    saw_left, saw_right := false, false
    for preview in mixed_previews {
        if preview.Side == .Left && preview.Client == pa { saw_left = true }
        if preview.Side == .Right && preview.Client == pe { saw_right = true }
    }
    ok(saw_left, "vertical reorder retains the natural partial preview")
    ok(saw_right, "vertical reorder reveals the previously hidden opposite preview")
    pborder := vertical_preview.Cfg.BorderWidth
    left_preview_gap := (pb.Geom.X - pborder) - (pa.Geom.X + pa.Geom.W + pborder)
    right_preview_gap := (pe.Geom.X - pborder) - (pc.Geom.X + pc.Geom.W + pborder)
    eq(left_preview_gap, vertical_preview.Cfg.InnerGap,
       "left preview remains a contiguous neighbor instead of overlapping")
    eq(right_preview_gap, vertical_preview.Cfg.InnerGap,
       "right preview remains a contiguous neighbor instead of overlapping")
    delete(mixed_previews)
}

// ----------------------------------------------------------------------------
// workspaces
// ----------------------------------------------------------------------------

test_workspaces :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)

    ok(c.Current_WS(m) == nil, "no current workspace initially")

    w1 := c.Ensure_WS(m, 1)
    ok(w1 != nil, "Ensure_WS creates ws 1")
    c.Ensure_WS(m, 3)
    c.Ensure_WS(m, 2)
    o := c.Active_Output(m)
    eq(len(o.Ws), 3, "three workspaces exist")
    eq(o.Ws[0].Id, 1, "workspaces sorted (1)")
    eq(o.Ws[1].Id, 2, "workspaces sorted (2)")
    eq(o.Ws[2].Id, 3, "workspaces sorted (3)")

    ok(c.Find_WS(m, 2) != nil, "Find_WS finds 2")
    ok(c.Find_WS(m, 9) == nil, "Find_WS misses 9")

    c.Switch_WS_Id(m, 2)
    eq(c.Current_WS(m).Id, 2, "switch to ws 2")
    ok(c.Switch_WS_Rel(m, 1), "switch rel +1")
    eq(c.Current_WS(m).Id, 3, "rel +1 lands on 3")
    ok(c.Switch_WS_Rel(m, -1), "switch rel -1")
    eq(c.Current_WS(m).Id, 2, "rel -1 lands on 2")

    eq(len(o.Ws), 3, "workspaces persist once created (even empty)")

    // rel stepping past the top id creates a new workspace (dynamic)
    ok(c.Switch_WS_Rel(m, 1), "rel +1 from 2")
    ok(c.Switch_WS_Rel(m, 1), "rel +1 from 3 -> creates ws 4")
    eq(c.Current_WS(m).Id, 4, "dynamic creation on rel-next")
    // stepping below 1 is a no-op
    for i in 0 ..< 8 { c.Switch_WS_Rel(m, -1) }
    eq(c.Current_WS(m).Id, 1, "rel-previous stops at ws 1")
}

// ----------------------------------------------------------------------------
// adding windows / focus placement
// ----------------------------------------------------------------------------

test_add_and_focus :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    d := add_tiled(m, 102)

    eq(len(ws.Cols), 3, "three new windows make three columns")
    eq(ws.Cols[0].Wins[0], a, "col0 holds a")
    eq(ws.Cols[1].Wins[0], b, "col1 holds b")
    eq(ws.Cols[2].Wins[0], d, "col2 holds d")
    eq(ws.Focus, d, "newest window focused")
    eq(m.Focused, d, "manager focus is newest")

    eq(len(m.Clients), 3, "three registered clients")
    ok(m.ByXid[100] == a, "ByXid maps 100 -> a")
    ok(m.ByXid[101] == b, "ByXid maps 101 -> b")

    c.Focus_Client(m, a)
    eq(m.Focused, a, "focus a updates global focus (current ws)")
    eq(ws.Focus, a, "workspace focus is a")
    ok(ws.Cols[0].Focus == a, "col0 remembers focus a")

    // focusing a window on a non-current workspace does not steal global focus
    ws2 := c.Ensure_WS(m, 2)
    x := c.New_Client(200)
    c.Add_Managed(m, ws2, x, false)
    c.Focus_Client(m, x)
    ok(m.Focused == a, "global focus unchanged while another ws focused")
}

// ----------------------------------------------------------------------------
// directional focus
// ----------------------------------------------------------------------------

test_focus_direction :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    d := add_tiled(m, 102) // cols: [a] [b] [d]

    // horizontal: no wrap
    ok(c.Focus_Dir(m, .Left), "left from d -> b")
    eq(ws.Focus, b, "focused b")
    ok(c.Focus_Dir(m, .Left), "left from b -> a")
    eq(ws.Focus, a, "focused a")
    ok(!c.Focus_Dir(m, .Left), "left at leftmost column no-op")
    eq(ws.Focus, a, "focus unchanged after no-op")

    // vertical in single-window columns: no-op
    ok(!c.Focus_Dir(m, .Up), "up in single-window column no-op")
    ok(!c.Focus_Dir(m, .Down), "down in single-window column no-op")

    // build a two-stack [b][d] on col1 by pulling d left into b's column
    c.Focus_Client(m, d)
    ok(c.Move_Dir(m, .Left), "pull d into b's column")
    eq(len(ws.Cols), 2, "cols now [a] [b,d]")
    eq(len(ws.Cols[1].Wins), 2, "col1 is a two-stack")

    // vertical within the stack
    c.Focus_Client(m, b) // top of col1
    ok(c.Focus_Dir(m, .Down), "down b -> d")
    eq(ws.Focus, d, "focused d (bottom)")
    ok(!c.Focus_Dir(m, .Down), "down at bottom no-op")
    ok(c.Focus_Dir(m, .Up), "up d -> b")
    eq(ws.Focus, b, "focused b (top)")

    // horizontal from inside the stack jumps columns whole
    ok(c.Focus_Dir(m, .Left), "left from b -> a")
    eq(ws.Focus, a, "focus left lands on a")
}

// ----------------------------------------------------------------------------
// move direction / column transfers
// ----------------------------------------------------------------------------

test_move_dir :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    d := add_tiled(m, 102) // cols: [a] [b] [d]

    // b moves right into d's column, appended at the bottom.
    c.Focus_Client(m, b)
    ok(c.Move_Dir(m, .Right), "b moves right")
    eq(len(ws.Cols), 2, "source col removed -> [a] [d,b]")
    eq(len(ws.Cols[1].Wins), 2, "col1 now holds two")
    eq(ws.Cols[1].Wins[0], d, "d stays on top")
    eq(ws.Cols[1].Wins[1], b, "b appended at bottom")
    eq(ws.Focus, b, "moved window keeps focus")

    // no-wrap right at the last column
    ok(!c.Move_Dir(m, .Right), "right at last column no-op")

    // vertical swap up
    ok(c.Move_Dir(m, .Up), "b swaps up")
    eq(ws.Cols[1].Wins[0], b, "b now on top")
    eq(ws.Cols[1].Wins[1], d, "d pushed below")
    eq(ws.Focus, b, "swapped window stays focused")

    // vertical swap down
    ok(c.Move_Dir(m, .Down), "b swaps down")
    eq(ws.Cols[1].Wins[0], d, "d back on top")
    eq(ws.Cols[1].Wins[1], b, "b back at bottom")

    // d moves left into a's column (a single-window col0 survives).
    c.Focus_Client(m, d)
    ok(c.Move_Dir(m, .Left), "d moves left into col0")
    eq(len(ws.Cols), 2, "two columns remain")
    eq(len(ws.Cols[0].Wins), 2, "col0 now [a,d]")
    eq(ws.Cols[0].Wins[0], a, "a on top")
    eq(ws.Cols[0].Wins[1], d, "d appended below a")

    // a moves left into an empty strip: no target column -> no-op
    c.Focus_Client(m, a)
    ok(!c.Move_Dir(m, .Left), "left at first column no-op")
}

test_pointer_column_move :: proc() {
    m := c.New_Manager()
    defer c.Destroy_Manager(m)
    specs := []c.Output_Spec {
        {Name = "LEFT", Geom = c.Rect{X = 0, Y = 0, W = 1280, H = 800}, Primary = true},
        {Name = "RIGHT", Geom = c.Rect{X = 1280, Y = 0, W = 1280, H = 800}},
        {Name = "EMPTY", Geom = c.Rect{X = 2560, Y = 0, W = 1280, H = 800}},
    }
    c.Reconcile_Outputs(m, specs)
    left := m.Outputs[0]
    right := m.Outputs[1]
    empty := m.Outputs[2]
    moving := add_tiled(m, 100)
    left_neighbor := add_tiled(m, 101)
    c.Focus_Output(m, right)
    target := add_tiled(m, 200)
    right_neighbor := add_tiled(m, 201)
    c.Focus_Client(m, target)
    c.Arrange_All(m)

    center := c.Drop_Target_At_Point(m, right.Geom.X + right.Geom.W / 2, right.Geom.Y + right.Geom.H / 2)
    eq(center.Kind, c.Drop_Kind.None, "drag center has no active drop zone")

    vertical := c.Drop_Target_At_Point(m, right.Geom.X + right.Geom.W / 2, right.Geom.Y + 10)
    eq(vertical.Kind, c.Drop_Kind.Into_Column, "top chooser selects vertical drop")
    eq(vertical.Zone, c.Drop_Zone.Top, "top edge reports one explicit direction")
    eq(vertical.Out, right, "drop hit resolves destination output")
    eq(vertical.Ws, right.Current, "drop hit resolves visible destination workspace")
    ok(vertical.Col != nil, "drop hit resolves destination column")

    c.Focus_Client(m, moving)
    ok(c.Move_Client_To_Drop(m, moving, vertical), "tiled client drops vertically on another output")
    eq(moving.Out, right, "dropped client changes output ownership")
    eq(moving.Ws, right.Current, "dropped client changes workspace ownership")
    eq(len(vertical.Col.Wins), 2, "destination column receives dropped client")
    eq(vertical.Col.Wins[0], moving, "top drop inserts client above destination windows")
    eq(c.Active_Output(m), right, "focus follows cross-output drop")
    eq(m.Focused, moving, "dropped client retains focus")
    eq(len(left.Current.Cols), 1, "empty source column is removed")
    eq(left.Current.Cols[0].Wins[0], left_neighbor, "source neighbor remains tiled")

    c.Arrange_All(m)
    bottom := c.Drop_Target_At_Point(m, right.Geom.X + right.Geom.W / 2, right.Geom.Y + right.Geom.H - 10)
    eq(bottom.Zone, c.Drop_Zone.Bottom, "bottom edge reports one explicit direction")
    ok(c.Move_Client_To_Drop(m, moving, bottom), "bottom chooser reorders within the vertical column")
    eq(vertical.Col.Wins[len(vertical.Col.Wins) - 1], moving, "bottom drop inserts client below destination windows")

    horizontal := c.Drop_Target_At_Point(m, right.Geom.X + 10, right.Geom.Y + right.Geom.H / 2)
    eq(horizontal.Kind, c.Drop_Kind.New_Column, "left chooser selects horizontal drop")
    eq(horizontal.Zone, c.Drop_Zone.Left, "left edge reports one explicit direction")
    eq(horizontal.Geom, c.Rect{X = 1288, Y = 8, W = 261, H = 784}, "left width matches top height and spans the workarea")
    eq(horizontal.Geom.W, vertical.Geom.H, "side overlay width equals top overlay height")
    at_overlay_border := c.Drop_Target_At_Point(
        m, horizontal.Geom.X + horizontal.Geom.W - 1, right.Geom.Y + right.Geom.H / 2,
    )
    eq(at_overlay_border.Zone, c.Drop_Zone.Left, "overlay activates through its inner boundary pixel")
    past_overlay_border := c.Drop_Target_At_Point(
        m, horizontal.Geom.X + horizontal.Geom.W, right.Geom.Y + right.Geom.H / 2,
    )
    eq(past_overlay_border.Kind, c.Drop_Kind.None, "fresh drag position outside overlay boundary stays inactive")
    no_sticky := c.Drop_Target_At_Point(
        m, horizontal.Geom.X + horizontal.Geom.W + 6, right.Geom.Y + right.Geom.H / 2,
    )
    eq(no_sticky.Kind, c.Drop_Kind.None, "pointer beyond enter threshold has no fresh target")
    sticky := c.Drop_Target_At_Point(
        m, horizontal.Geom.X + horizontal.Geom.W + 6, right.Geom.Y + right.Geom.H / 2,
        nil, horizontal,
    )
    eq(sticky.Zone, c.Drop_Zone.Left, "active zone remains stable inside hysteresis margin")
    released := c.Drop_Target_At_Point(
        m, horizontal.Geom.X + horizontal.Geom.W + c.DROP_ZONE_HYSTERESIS + 1,
        right.Geom.Y + right.Geom.H / 2, nil, horizontal,
    )
    eq(released.Kind, c.Drop_Kind.None, "active zone releases beyond hysteresis margin")
    ok(c.Move_Client_To_Drop(m, moving, horizontal), "tiled client creates a horizontal column on the same output")
    eq(len(right.Current.Cols), 3, "horizontal drop adds a destination column")
    eq(len(right.Current.Cols[0].Wins), 1, "new horizontal column contains only dropped client")
    eq(right.Current.Cols[0].Wins[0], moving, "horizontal column inserted at left edge")

    c.Arrange_All(m)

    right_edge := c.Drop_Target_At_Point(
        m, right.Geom.X + right.Geom.W - 10, right.Geom.Y + right.Geom.H / 2, moving,
    )
    eq(right_edge.Zone, c.Drop_Zone.Left, "partially visible next tile exposes its left insertion side")
    eq(right_edge.Target, right_neighbor, "Drop anchors to the tiled window under the pointer")
    eq(right_edge.Geom, c.Rect{X = 2532, Y = 8, W = 314, H = 784}, "drop overlay covers the target window's nearest half")
    ok(c.Move_Client_To_Drop(m, moving, right_edge), "right chooser reorders the tiled client")
    eq(right.Current.Cols[1].Wins[0], moving, "right drop moves client immediately after its neighboring column")

    empty_drop := c.Drop_Target_At_Point(m, empty.Geom.X + 10, empty.Geom.Y + empty.Geom.H / 2)
    eq(empty_drop.Kind, c.Drop_Kind.New_Column, "empty output exposes a first-column target")
    ok(c.Move_Client_To_Drop(m, moving, empty_drop), "tiled client drops onto an empty output")
    eq(moving.Out, empty, "empty-output drop changes ownership")
    eq(len(empty.Current.Cols), 1, "empty output gains its first column")
    eq(empty.Current.Cols[0].Wins[0], moving, "first column contains dropped client")

    c.Focus_Output(m, left)
    floater := c.New_Client(300)
    c.Add_Managed(m, left.Current, floater, true)
    floater.FloatingRect = c.Rect{X = 1400, Y = 100, W = 500, H = 400}
    ok(c.Move_Floating_To_Output(m, floater, right), "floating drag crosses to another output")
    eq(floater.Out, right, "floating drag changes output ownership")
    eq(floater.Ws, right.Current, "floating drag changes workspace ownership")
    eq(floater.FloatingRect.X, 1400, "floating drag preserves root-coordinate position")
    eq(c.Active_Output(m), right, "focus follows cross-output floating drag")
}

test_pointer_tabbed_drop :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    c.Arrange_All(m)

    target := c.Tabbed_Drop_Target_At_Point(
        m, a.Geom.X + a.Geom.W / 2, a.Geom.Y + a.Geom.H / 2, b,
    )
    eq(target.Kind, c.Drop_Kind.Into_Column, "tab gesture targets the window beneath the pointer")
    eq(target.Target, a, "tab gesture records the destination client")
    eq(target.Col, ws.Cols[0], "tab gesture records the destination column")
    eq(target.Row_Index, 1, "tab gesture inserts after its destination client")
    eq(target.Geom, c.Rect{X = 8, Y = 8, W = 948, H = 1064}, "tab overlay covers the complete destination tile")

    gap := c.Tabbed_Drop_Target_At_Point(m, 960, 540, b)
    eq(gap.Kind, c.Drop_Kind.None, "tab gesture requires the pointer to be on a window")
    self := c.Tabbed_Drop_Target_At_Point(
        m, b.Geom.X + b.Geom.W / 2, b.Geom.Y + b.Geom.H / 2, b,
    )
    eq(self.Kind, c.Drop_Kind.None, "drag preview cannot target its own tiled position")

    ok(c.Move_Client_To_Tabbed_Drop(m, b, target), "tab gesture joins the destination column")
    eq(len(ws.Cols), 1, "tab drop removes the empty source column")
    eq(len(ws.Cols[0].Wins), 2, "tab drop groups both clients")
    eq(ws.Cols[0].Wins[0], a, "destination tab keeps its position")
    eq(ws.Cols[0].Wins[1], b, "dragged client follows the destination tab")
    eq(ws.Cols[0].Layout, c.Column_Layout.Tabbed, "tab drop enables tabbed layout")
    eq(ws.Cols[0].Focus, b, "dragged client becomes the active tab")
    eq(m.Focused, b, "keyboard focus follows the tab drop")
}

test_pointer_tabbed_column_drop :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    ok(c.Move_Dir(m, .Left), "column drag fixture groups two windows")
    ok(c.Set_Column_Layout(m, .Tabbed), "column drag fixture enables tabs")
    group := ws.Cols[0]
    group.Width = 700
    d := add_tiled(m, 102)
    c.Arrange_All(m)

    self := c.Column_Drop_Target_At_Point(
        m, b.Geom.X + b.Geom.W / 2, b.Geom.Y + b.Geom.H / 2, b,
    )
    eq(self.Kind, c.Drop_Kind.None, "tab-header drag does not target its own group")

    target := c.Column_Drop_Target_At_Point(
        m, d.Geom.X + 3 * d.Geom.W / 4, d.Geom.Y + d.Geom.H / 2, b,
    )
    eq(target.Kind, c.Drop_Kind.New_Column, "tab-header drag targets another column")
    eq(target.Zone, c.Drop_Zone.Right, "right half places the tab group after its target")
    eq(target.Col, ws.Cols[1], "column drop records the neighboring column")
    eq(target.Target, d, "column drop records a visible destination client")

    ok(c.Move_Tabbed_Column_To_Drop(m, b, target), "tab header moves the complete group")
    eq(len(ws.Cols), 2, "whole-column reorder keeps the column count")
    eq(ws.Cols[0].Wins[0], d, "destination column moves before the group")
    eq(ws.Cols[1], group, "the original column allocation is retained")
    eq(len(group.Wins), 2, "every tab moves with the group")
    eq(group.Wins[0], a, "first tab retains its order")
    eq(group.Wins[1], b, "second tab retains its order")
    eq(group.Layout, c.Column_Layout.Tabbed, "moved group remains tabbed")
    eq(group.Focus, b, "moved group retains its active tab")
    eq(group.Width, i32(700), "moved group retains its resized width")
}

test_relative_column_drop :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    d := add_tiled(m, 102)
    c.Arrange_All(m)
    _, b_col, _ := c.Column_Of(b)

    left := c.Drop_Target_At_Point(m, b.Geom.X + 10, b.Geom.Y + b.Geom.H / 2, d)
    eq(left.Zone, c.Drop_Zone.Left, "third column finds a relative left drop")
    eq(left.Col, b_col, "relative left drop targets the immediately preceding column")
    eq(left.Insert_Index, 1, "relative left drop inserts before the preceding target")
    ok(c.Move_Client_To_Drop(m, d, left), "third column can move between the first two")
    eq(ws.Cols[0].Wins[0], a, "first column stays first after relative drop")
    eq(ws.Cols[1].Wins[0], d, "dragged third column becomes the middle column")
    eq(ws.Cols[2].Wins[0], b, "former middle column shifts right")

    c.Arrange_All(m)
    right := c.Drop_Target_At_Point(m, b.Geom.X + b.Geom.W - 10, b.Geom.Y + b.Geom.H / 2, d)
    eq(right.Col, b_col, "relative right drop targets the immediately following column")
    ok(c.Move_Client_To_Drop(m, d, right), "middle column can move right again")
    eq(ws.Cols[0].Wins[0], a, "first column remains stable after right drop")
    eq(ws.Cols[1].Wins[0], b, "following column shifts into the middle")
    eq(ws.Cols[2].Wins[0], d, "dragged column moves immediately after its neighbor")
}

// ----------------------------------------------------------------------------
// unmanage / destroy
// ----------------------------------------------------------------------------

test_unmanage :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    d := add_tiled(m, 102)
    // collapse into a single column [a,b,d]
    c.Focus_Client(m, b)
    c.Move_Dir(m, .Left)
    c.Focus_Client(m, d)
    c.Move_Dir(m, .Left)
    eq(len(ws.Cols), 1, "single column")
    eq(len(ws.Cols[0].Wins), 3, "stack of three")
    eq(ws.Cols[0].Wins[0], a, "top a")
    eq(ws.Cols[0].Wins[1], b, "middle b")
    eq(ws.Cols[0].Wins[2], d, "bottom d")

    // unmanage middle b -> focus falls to the window below (d)
    c.Focus_Client(m, b)
    nxt := c.Unmanage_Client(m, b)
    eq(nxt, d, "unmanage b -> next focus d")
    eq(len(ws.Cols[0].Wins), 2, "two remain")
    eq(ws.Cols[0].Wins[0], a, "a stays top")
    eq(ws.Cols[0].Wins[1], d, "d stays bottom")
    eq(ws.Focus, d, "workspace focus d")
    eq(len(m.Clients), 2, "registry shrunk")
    ok(m.ByXid[101] == nil, "ByXid cleared for b")

    // unmanage top a -> focus d (the new top)
    c.Focus_Client(m, a)
    nxt2 := c.Unmanage_Client(m, a)
    eq(nxt2, d, "unmanage top a -> focus d")
    eq(len(ws.Cols[0].Wins), 1, "single window left")

    // unmanage the last window destroys the column; workspace survives empty
    c.Focus_Client(m, d)
    nxt3 := c.Unmanage_Client(m, d)
    ok(nxt3 == nil, "no focus left after last window gone")
    eq(len(ws.Cols), 0, "no columns remain")
    ok(c.Current_WS(m) == ws, "workspace persists")
    ok(ws.Focus == nil, "workspace focus nil")
    ok(m.Focused == nil, "manager focus nil")
    eq(len(m.Clients), 0, "registry empty")
    eq(len(m.ByXid), 0, "ByXid empty")
}

// ----------------------------------------------------------------------------
// floating / fullscreen
// ----------------------------------------------------------------------------

test_floating :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    b := add_tiled(m, 101) // cols [a] [b]

    c.Focus_Client(m, a)
    ok(c.Toggle_Floating(m), "float a")
    ok(a.Floating, "a is floating")
    eq(len(ws.Floaters), 1, "one floater")
    eq(len(ws.Cols), 1, "one tiled column left (b)")
    // default float rect is centered at 60% of the output
    eq(a.FloatingRect.W, 1152, "float width 3/5 * 1920")
    eq(a.FloatingRect.H, 648, "float height 3/5 * 1080")
    eq(a.FloatingRect.X, 384, "float centered X")
    eq(a.FloatingRect.Y, 216, "float centered Y")
    eq(ws.Focus, a, "floater keeps workspace focus")

    // float b too -> no tiled columns left
    c.Focus_Client(m, b)
    ok(c.Toggle_Floating(m), "float b")
    eq(len(ws.Floaters), 2, "two floaters")
    eq(len(ws.Cols), 0, "no tiled columns")

    // re-tile a -> becomes its own column; b stays floating
    c.Set_Floating(m, a, false)
    ok(!a.Floating, "a no longer floating")
    eq(len(ws.Cols), 1, "a re-tiled as one column")
    eq(len(ws.Floaters), 1, "b still floating")
    eq(ws.Cols[0].Wins[0], a, "a is in the column")
    eq(ws.Focus, a, "a focused after re-tile")

    // floating windows ignore Move_Dir (pointer-driven)
    c.Focus_Client(m, b)
    ok(!c.Move_Dir(m, .Left), "floating windows ignore Move_Dir")
    ok(!c.Focus_Dir(m, .Left), "floating windows ignore Focus_Dir")
}

test_fullscreen :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    add_tiled(m, 100)
    b := add_tiled(m, 101)

    on, changed := c.Toggle_Fullscreen(m)
    ok(on && changed, "focus window went fullscreen")
    ok(b.Fullscreen, "b is fullscreen")

    // focusing another window exits b's fullscreen
    c.Focus_Client(m, c.Find_WS(m, 1).Cols[0].Wins[0])
    ok(!b.Fullscreen, "focus change exits fullscreen")

    // fullscreen focus ignores directional focus/move
    c.Focus_Client(m, b)
    c.Toggle_Fullscreen(m)
    ok(b.Fullscreen, "b fullscreen again")
    ok(!c.Focus_Dir(m, .Left), "no focus nav out of fullscreen")
    ok(!c.Move_Dir(m, .Left), "no move out of fullscreen")
}

test_maximize :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    c.Arrange_All(m)
    original := a.Geom
    c.Focus_Client(m, a)
    ok(c.Toggle_Maximized(a), "maximize tiled client")
    ok(a.Maximized, "tiled client records maximized state")
    ok(!a.Floating, "maximize preserves tiled membership")
    eq(a.MaxRestoreGeom, original, "maximize snapshots tiled geometry")
    c.Arrange_All(m)
    eq(a.Geom, c.Rect{X = 10, Y = 10, W = 1900, H = 1060}, "maximized tiled client fills usable area")
    ok(m.ByXid[101].Geom.X <= c.HIDE_X, "maximized tiled column displaces its neighbor off-screen")
    ok(c.Scroll_Viewport(m, 1), "neighbor remains reachable by scrolling")
    c.Arrange_All(m)
    eq(a.Geom, c.Rect{X = -946, Y = 10, W = 1900, H = 1060}, "scrolling translates but does not resize the maximized column")
    ok(m.ByXid[101].Geom.X >= 0, "scrolling reveals the displaced neighbor")
    ok(c.Scroll_Viewport(m, -1), "scroll back to maximized column")
    c.Arrange_All(m)
    eq(a.Geom, c.Rect{X = 10, Y = 10, W = 1900, H = 1060}, "layout reflow preserves maximize override")
    ok(c.Toggle_Maximized(a), "restore tiled client")
    c.Arrange_All(m)
    eq(a.Geom, original, "focus changes do not alter restored client geometry")

    c.Focus_Client(m, b)
    ok(c.Set_Maximized(b, true), "maximize right tiled client")
    c.Ensure_Active_Focus_Visible(m)
    c.Arrange_All(m)
    eq(b.Geom, c.Rect{X = 10, Y = 10, W = 1900, H = 1060}, "right maximized column expands left to fill its page")
    ok(c.Scroll_Viewport(m, -1), "scroll left from right maximized column")
    c.Arrange_All(m)
    eq(a.Geom, c.Rect{X = 10, Y = 10, W = 944, H = 1060}, "unfocused left neighbor keeps its reserved border inset")
    eq(b.Geom, c.Rect{X = 966, Y = 10, W = 1900, H = 1060}, "right maximized page stays full-width while partially visible")
    c.Set_Maximized(b, false)
    ws.ViewportX = 0
    c.Focus_Client(m, a)

    c.Set_Floating(m, a, true)
    a.FloatingRect = c.Rect{X = 123, Y = 87, W = 701, H = 509}
    c.Arrange_All(m)
    float_original := a.Geom
    ok(c.Set_Maximized(a, true), "maximize floating client")
    c.Arrange_All(m)
    eq(a.Geom, c.Rect{X = 10, Y = 10, W = 1900, H = 1060}, "maximized floater fills usable area")
    a.FloatingRect = c.Rect{X = 1, Y = 2, W = 3, H = 4}
    ok(c.Set_Maximized(a, false), "restore floating client")
    c.Arrange_All(m)
    eq(a.FloatingRect, c.Rect{X = 123, Y = 87, W = 701, H = 509}, "floating restore preserves exact user rect")
    eq(a.Geom, float_original, "floating client restores exact visible geometry")

    a.Fullscreen = true
    ok(!c.Toggle_Maximized(a), "fullscreen blocks maximize toggle")
    ok(!a.Maximized, "fullscreen remains distinct from maximized")
    a.Fullscreen = false

    dock := add_dock(m, 300, c.Insets{Top = 24, Left = 40}, c.Rect{X = 0, Y = 0, W = 1920, H = 24})
    _ = dock
    ok(c.Set_Maximized(a, true), "maximize with reserved work area")
    c.Arrange_All(m)
    eq(a.Geom, c.Rect{X = 50, Y = 34, W = 1860, H = 1036}, "maximize respects gaps, borders, and dock struts")

    c.Switch_WS_Id(m, 2)
    c.Arrange_All(m)
    ok(a.Geom.X <= c.HIDE_X, "maximized client is hidden with its workspace")
    c.Switch_WS_Id(m, 1)
    c.Arrange_All(m)
    ok(a.Maximized, "maximize state survives workspace switch")
    eq(a.Geom, c.Rect{X = 50, Y = 34, W = 1860, H = 1036}, "maximized geometry returns with workspace")
    eq(a.Ws, ws, "maximize does not change workspace ownership")

    multi := c.New_Manager()
    defer c.Destroy_Manager(multi)
    specs := []c.Output_Spec{
        {Name = "left", Geom = c.Rect{X = 0, Y = 0, W = 1920, H = 1080}, Primary = true},
        {Name = "right", Geom = c.Rect{X = 1920, Y = 0, W = 1280, H = 1024}},
    }
    c.Reconcile_Outputs(multi, specs)
    moved := add_tiled(multi, 400)
    c.Arrange_All(multi)
    c.Set_Maximized(moved, true)
    ok(c.Move_Focused_To_Output_Rel(multi, 1), "move maximized client to another output")
    c.Arrange_All(multi)
    ok(moved.Maximized, "maximize state survives output move")
    eq(moved.Geom, c.Rect{X = 1930, Y = 10, W = 1260, H = 1004}, "maximize recomputes destination output geometry")
}

test_tabbed_layout :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    eq(len(ws.Cols), 2, "tabbed: windows begin in separate columns")
    ok(c.Move_Dir(m, .Left), "tabbed: explicitly group selected windows")
    eq(len(ws.Cols), 1, "tabbed: selected windows share one column")
    col := ws.Cols[0]
    eq(len(col.Wins), 2, "tabbed: every tiled window joins the group")
    ok(c.Set_Column_Layout(m, .Tabbed), "tabbed: toggle only selected column")
    eq(col.Layout, c.Column_Layout.Tabbed, "column records tabbed layout")
    eq(col.Focus, b, "focused window is active tab")
    c.Arrange_All(m)
    eq(b.Geom.X, 10, "active tab uses column x")
    eq(b.Geom.Y, 34, "active tab starts below visible tab bar")
    eq(b.Geom.W, 1900, "active tab uses full column width")
    eq(b.Geom.H, 1036, "active tab uses space below tab bar")
    ok(a.Geom.X <= c.HIDE_X, "inactive tab is parked off-screen")

    ok(c.Focus_Dir(m, .Up), "focus up selects previous tab")
    eq(col.Focus, a, "previous tab becomes active")
    c.Arrange_All(m)
    eq(a.Geom.X, 10, "new active tab is shown")
    ok(b.Geom.X <= c.HIDE_X, "old active tab is hidden")
    ok(c.Focus_Dir(m, .Down), "focus down selects next tab")

    ok(c.Move_Dir(m, .Up), "move up reorders active tab")
    eq(col.Wins[0], b, "active tab moved earlier")
    eq(col.Wins[1], a, "other tab moved later")

    ok(c.Set_Column_Layout(m, .Stacked), "restore stacked layout")
    eq(len(ws.Cols), 1, "leaving tabs keeps the selected group together")
    c.Arrange_All(m)
    ok(a.Geom.X >= 0 && b.Geom.X >= 0, "stacked layout shows every window")
    ok(a.Geom.Y != b.Geom.Y, "stacked group lays windows out vertically")
    ok(c.Toggle_Column_Layout(m), "toggle returns to tabbed")
    eq(ws.Cols[0].Layout, c.Column_Layout.Tabbed, "toggle selects tabbed layout")

    m3 := mk_man()
    defer c.Destroy_Manager(m3)
    ws3 := c.Ensure_WS(m3, 1)
    c.Switch_WS_Id(m3, 1)
    outside := add_tiled(m3, 300)
    grouped_a := add_tiled(m3, 301)
    grouped_b := add_tiled(m3, 302)
    ok(c.Move_Dir(m3, .Left), "per-column tabs: group two chosen windows")
    ok(c.Set_Column_Layout(m3, .Tabbed), "per-column tabs: toggle chosen group")
    c.Arrange_All(m3)
    eq(len(ws3.Cols), 2, "per-column tabs preserve neighboring column")
    eq(ws3.Cols[0].Layout, c.Column_Layout.Stacked, "neighbor stays tiled")
    eq(ws3.Cols[1].Layout, c.Column_Layout.Tabbed, "chosen column becomes tabbed")
    ok(outside.Geom.X >= 0, "neighbor remains visible beside tab group")
    ok(grouped_a.Geom.X <= c.HIDE_X, "inactive chosen tab is hidden")
    ok(grouped_b.Geom.X >= 0, "active chosen tab remains visible")
    spawned_tab := c.New_Client(303)
    c.Add_Managed(m3, ws3, spawned_tab, false, grouped_b)
    eq(len(ws3.Cols), 2, "shift-spawn keeps surrounding tiling intact")
    eq(len(ws3.Cols[1].Wins), 3, "shift-spawn joins requested tab group")
    eq(ws3.Focus, spawned_tab, "shift-spawned tab becomes active")
    ok(c.Toggle_Column_Layout(m3), "per-column tabs: toggle back to default")
    eq(len(ws3.Cols), 4, "toggle back splits tabs into horizontal columns")
    for restored in ws3.Cols {
        eq(len(restored.Wins), 1, "restored horizontal column has one window")
    }

}

test_multi_output :: proc() {
    m := c.New_Manager()
    defer c.Destroy_Manager(m)
    specs := []c.Output_Spec {
        {Name = "eDP-1", Geom = c.Rect{X = 0, Y = 0, W = 1920, H = 1080}, Primary = true},
        {Name = "HDMI-1", Geom = c.Rect{X = 1920, Y = 0, W = 1280, H = 1024}},
    }
    ok(c.Reconcile_Outputs(m, specs), "multi-output discovery changes topology")
    eq(len(m.Outputs), 2, "two outputs discovered")
    eq(c.Active_Output(m).Name, "eDP-1", "primary output starts active")
    eq(c.Current_WS(m).Id, 1, "primary output starts on workspace 1")

    left := add_tiled(m, 100)
    ok(c.Switch_WS_Rel(m, 1), "primary advances to its workspace 2")
    eq(c.Current_WS(m).Id, 2, "primary workspace changes independently")
    ok(c.Focus_Output_Rel(m, 1), "focus next output")
    eq(c.Active_Output(m).Name, "HDMI-1", "secondary output is active")
    eq(c.Current_WS(m).Id, 1, "secondary retained workspace 1")
    right := add_tiled(m, 101)

    c.Arrange_All(m)
    ok(left.Geom.X < 1920, "primary client arranged on primary geometry")
    ok(right.Geom.X >= 1920, "secondary client arranged on secondary geometry")
    eq(right.Out.Name, "HDMI-1", "client records owning output")

    ok(c.Move_Focused_To_Output_Rel(m, -1), "send focused client to previous output")
    eq(right.Out.Name, "eDP-1", "window ownership moved to primary")
    eq(right.Ws.Id, 2, "window lands on target output's visible workspace")
    eq(c.Active_Output(m).Name, "HDMI-1", "sending does not change active output")

    floating := c.New_Client(102)
    c.Add_Managed(m, c.Current_WS(m), floating, true)
    ok(c.Move_Focused_To_Output_Rel(m, -1), "send floating client to previous output")
    eq(floating.Out.Name, "eDP-1", "floating client ownership moved")
    eq(floating.Ws.Focus, floating, "moved floating client is remembered on target")

    reduced := []c.Output_Spec {
        {Name = "eDP-1", Geom = c.Rect{X = 0, Y = 0, W = 2560, H = 1440}, Primary = true},
    }
    ok(c.Reconcile_Outputs(m, reduced), "disconnect reconciles topology")
    eq(len(m.Outputs), 1, "disconnected output removed")
    eq(m.Outputs[0].Geom.W, 2560, "surviving output geometry updated")
    eq(c.Active_Output(m), m.Outputs[0], "surviving output becomes active")
    eq(left.Out, m.Outputs[0], "existing primary client preserved")
    eq(right.Out, m.Outputs[0], "moved client preserved after disconnect")
    eq(floating.Out, m.Outputs[0], "floating client preserved after disconnect")

    outputs := c.ipc_outputs_payload(m)
    defer delete(outputs)
    ok(strings.contains(string(outputs), `"name":"eDP-1"`), "output IPC includes surviving monitor")
    ok(!strings.contains(string(outputs), `"name":"HDMI-1"`), "output IPC drops disconnected monitor")
    event := c.ipc_output_event_payload("disconnected", "HDMI-1")
    defer delete(event)
    eq(string(event), `{"change":"disconnected","output":"HDMI-1"}`, "output IPC event payload")
}

test_multi_output_scrolling :: proc() {
    m := c.New_Manager()
    defer c.Destroy_Manager(m)
    specs := []c.Output_Spec {
        {Name = "LEFT", Geom = c.Rect{X = -1280, Y = 0, W = 1280, H = 1024}},
        {Name = "RIGHT", Geom = c.Rect{X = 0, Y = 0, W = 1920, H = 1080}, Primary = true},
    }
    c.Reconcile_Outputs(m, specs)
    left := m.Outputs[0]
    right := m.Outputs[1]

    eq(c.Output_At_Point(m, -640, 512), left, "negative root coordinate selects left output")
    eq(c.Output_At_Point(m, 960, 540), right, "root coordinate selects right output")
    eq(c.Output_At_Point(m, 3000, 540), right, "point outside outputs falls back to active output")

    c.Focus_Output(m, left)
    left_first := add_tiled(m, 100)
    add_tiled(m, 101)
    left_third := add_tiled(m, 102)
    c.Focus_Output(m, right)
    right_first := add_tiled(m, 200)
    add_tiled(m, 201)
    right_third := add_tiled(m, 202)

    c.Arrange_All(m)
    eq(left_third.Geom.X, -26, "left output preserves its logical right-neighbor geometry")
    eq(right_third.Geom.X, 1894, "right output preserves its logical right-neighbor geometry")
    ok(right_first.Geom.X >= right.Geom.X, "visible right column stays on its own output")

    eq(left.Current.ViewportX, 0, "left viewport starts independently at zero")
    eq(right.Current.ViewportX, 0, "right viewport starts independently at zero")
    ok(c.Scroll_Output_Viewport(m, left, 1), "wheel can scroll non-active left output")
    ok(left.Current.ViewportX > 0, "left output viewport advances")
    eq(right.Current.ViewportX, 0, "right output viewport remains unchanged")
    eq(c.Active_Output(m), right, "pointer scrolling does not steal active output")
    c.Arrange_All(m)
    eq(left_first.Geom.X, -1878, "left output preserves its logical left-neighbor geometry")
    ok(left_third.Geom.X >= left.Geom.X && left_third.Geom.X < left.Geom.X + left.Geom.W,
       "newly visible left column stays within its output")

    left_viewport := left.Current.ViewportX
    ok(c.Scroll_Output_Viewport(m, right, 1), "wheel can scroll the right output independently")
    eq(left.Current.ViewportX, left_viewport, "right-output scroll leaves the left viewport unchanged")
    ok(right.Current.ViewportX > 0, "right output viewport advances")
    c.Arrange_All(m)
    ok(right_first.Geom.X < right.Geom.X,
       "right output keeps the full logical preview beyond its viewport")

    // A custom-width edge preview also keeps its full application geometry;
    // the X output viewport presents only its owning monitor's portion.
    right.Current.ViewportX = 0
    for col in right.Current.Cols { col.Width = 700 }
    c.Arrange_All(m)
    eq(right_third.Geom.W, i32(696), "custom-width preview preserves its full client width")
    ok(right_third.Geom.X >= left.Geom.X + left.Geom.W,
       "custom-width continuation does not enter the adjacent left monitor")
}

// ----------------------------------------------------------------------------
// layout geometry (numbers assume 1920x1080 @ outer 8, inner 8, col 0.7, border 2)
// ----------------------------------------------------------------------------

test_layout_geometry :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    c.Arrange_All(m)
    eq(a.Geom, c.Rect{X = 10, Y = 10, W = 1900, H = 1060}, "single window fills the work width (1904 - 2*2)")
    eq(a.Border, 2, "border width applied")

    // second window pulled into the same column -> equal halves, full-width column
    b := add_tiled(m, 101)
    c.Focus_Client(m, b)
    c.Move_Dir(m, .Left)
    c.Arrange_All(m)
    eq(len(ws.Cols[0].Wins), 2, "two in a column")
    eq(a.Geom.H, b.Geom.H, "stacked client surfaces remain equal across focus")
    eq(a.Geom.H, 524, "each client permanently reserves the border inset")
    eq(a.Geom.W, 1900, "unfocused client keeps the same inset width as focused")
    eq(b.Geom.Y, 546, "b sits below a with inner gap + borders")
    eq(b.Geom.Y, a.Geom.Y + a.Geom.H + 12, "rows retain inner gap plus reserved border space")
}

// ----------------------------------------------------------------------------
// scrolling / viewport
// ----------------------------------------------------------------------------

test_scrolling :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    d := add_tiled(m, 102) // 3 columns: each 948 wide, total = 3*948 + 2*8 = 2860

    eq(ws.ViewportX, 0, "viewport starts at 0")

    ok(c.Scroll_Viewport(m, 1), "wheel scroll pans right")
    eq(ws.ViewportX, 956, "wheel scroll advances by one column step")
    ok(!c.Scroll_Viewport(m, 1), "wheel scroll stops at right edge")
    ok(c.Scroll_Viewport(m, -1), "wheel scroll pans left")
    eq(ws.ViewportX, 0, "wheel scroll returns to left edge")
    ok(!c.Scroll_Viewport(m, -1), "wheel scroll stops at left edge")

    c.Focus_Client(m, d)
    c.Ensure_Active_Focus_Visible(m)
    eq(ws.ViewportX, 956, "viewport pans to max (2860 - 1904)")

    c.Focus_Client(m, a)
    c.Ensure_Active_Focus_Visible(m)
    eq(ws.ViewportX, 0, "viewport returns to 0")

    // hidden workspaces keep their viewport
    c.Switch_WS_Id(m, 2)
    c.Ensure_WS(m, 3)
    c.Switch_WS_Id(m, 1)
    eq(ws.ViewportX, 0, "viewport preserved across workspace switches")

    // a drawn column's screen position accounts for the viewport
    c.Focus_Client(m, d)
    c.Ensure_Active_Focus_Visible(m)
    c.Arrange_All(m)
    eq(d.Geom.X, 980, "right column leaves a normal gap beside the left preview")
    eq(a.Geom.X, -918, "unfocused scrolled-off column leaves a narrow left preview")
    _, first_bar_visible := c.Tab_Bar_Rect(m, c.Active_Output(m), ws, 0)
    ok(!first_bar_visible, "scrolled-off column does not expose a tab decoration")
}

test_scroll_previews :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    d := add_tiled(m, 102)

    c.Arrange_All(m)
    previews := c.Scroll_Previews(m, c.Active_Output(m))
    eq(len(previews), 1, "first strip page has one right preview")
    if len(previews) == 1 {
        eq(previews[0].Side, c.Scroll_Preview_Side.Right, "preview points right")
        eq(previews[0].Client, d, "right preview targets nearest hidden client")
        eq(previews[0].Geom, c.Rect{X = 1892, Y = 8, W = 20, H = 1064}, "right preview uses actual workarea edge")
        eq(d.Geom.W, i32(944), "right neighbor keeps its full window width")
        ok(d.Geom.X + d.Geom.W > 1920, "right neighbor continues naturally beyond the screen")
    }
    delete(previews)

    preview, hit := c.Scroll_Preview_At_Point(m, 1900, 500)
    ok(hit && preview.Client == d, "point on exposed right edge resolves preview target")
    ok(c.Reveal_Scroll_Client(m, d), "reveal focuses and scrolls to right preview target")
    eq(m.Focused, d, "revealed preview target becomes focused")
    eq(ws.ViewportX, 956, "revealed target aligns the next strip page")
    c.Arrange_All(m)
    previews = c.Scroll_Previews(m, c.Active_Output(m))
    eq(len(previews), 1, "last strip page has one left preview")
    if len(previews) == 1 {
        eq(previews[0].Side, c.Scroll_Preview_Side.Left, "preview points left")
        eq(previews[0].Client, a, "left preview targets nearest hidden client")
        eq(previews[0].Geom, c.Rect{X = 8, Y = 8, W = 20, H = 1064}, "left preview uses actual workarea edge")
        eq(a.Geom.W, i32(944), "unfocused left neighbor keeps stable inset width")
        ok(a.Geom.X < 0, "left neighbor continues naturally beyond the screen")
    }
    delete(previews)

    // A page with hidden columns on both sides reserves both preview strips.
    // The visible tiles reflow between them and retain the configured inner
    // gap instead of being covered by either preview.
    e := add_tiled(m, 103)
    c.Arrange_All(m)
    previews = c.Scroll_Previews(m, c.Active_Output(m))
    eq(len(previews), 2, "middle strip page exposes previews on both sides")
    if len(previews) == 2 {
        eq(previews[0].Client, a, "left preview still targets nearest hidden client")
        eq(previews[1].Client, e, "right preview targets nearest hidden client")
        eq(b.Geom.X - m.Cfg.BorderWidth - (previews[0].Geom.X + previews[0].Geom.W), i32(8), "left preview keeps the normal inner gap")
        eq(previews[1].Geom.X - (d.Geom.X + d.Geom.W + m.Cfg.BorderWidth), i32(8), "right preview keeps the normal inner gap")
    }
    delete(previews)

    c.Focus_Client(m, d)
    d.Fullscreen = true
    c.Arrange_All(m)
    previews = c.Scroll_Previews(m, c.Active_Output(m))
    eq(len(previews), 0, "fullscreen suppresses scroll previews")
    delete(previews)
}

// two columns fit on screen exactly, so the viewport never pans
test_two_columns_fit :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    b := add_tiled(m, 101) // 2 columns, page width 948 each: total = 2*948 + 8 = 1904
    eq(ws.ViewportX, 0, "viewport stays 0 with two columns")

    c.Focus_Client(m, b)
    c.Ensure_Active_Focus_Visible(m)
    eq(ws.ViewportX, 0, "no panning when both columns already fit")

    c.Arrange_All(m)
    ok(a.Geom.X >= 0 && b.Geom.X >= 0, "both columns on screen")
    eq(a.Geom.X, 10, "unfocused left column reserves the configured border inset")
    eq(b.Geom.X, 966, "right column at work_x + (948+8) + border, fully visible")
    a_before, b_before := a.Geom, b.Geom
    eq(a.Border, i32(0), "unfocused window does not draw its reserved border")
    eq(b.Border, m.Cfg.BorderWidth, "focused window draws the configured border")
    c.Focus_Client(m, a)
    c.Arrange_All(m)
    eq(a.Geom, a_before, "focusing a window does not resize its client surface")
    eq(b.Geom, b_before, "unfocusing a window does not resize its client surface")
    eq(a.Border, m.Cfg.BorderWidth, "new focus activates its reserved border")
    eq(b.Border, i32(0), "old focus hides its border without changing geometry")
}

// A zero border width removes both the decoration and the normally reserved
// inset. Focus changes must not add either one back.
test_borderless_layout :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    m.Cfg.BorderWidth = 0
    c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)

    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    c.Arrange_All(m)

    eq(a.Geom, c.Rect{X = 8, Y = 8, W = 948, H = 1064}, "borderless left client occupies its complete tile")
    eq(b.Geom, c.Rect{X = 964, Y = 8, W = 948, H = 1064}, "borderless right client occupies its complete tile")
    eq(a.Border, i32(0), "unfocused border remains disabled")
    eq(b.Border, i32(0), "focused border remains disabled")

    a_before, b_before := a.Geom, b.Geom
    c.Focus_Client(m, a)
    c.Arrange_All(m)
    eq(a.Geom, a_before, "borderless focus keeps the new client geometry")
    eq(b.Geom, b_before, "borderless focus keeps the old client geometry")
    eq(a.Border, i32(0), "new focus does not enable a border")
    eq(b.Border, i32(0), "old focus remains borderless")
}

// ----------------------------------------------------------------------------
// inactive workspaces are parked off-screen
// ----------------------------------------------------------------------------

test_arrange_hidden :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws1 := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)

    ws2 := c.Ensure_WS(m, 2)
    c.Switch_WS_Id(m, 2)
    x := add_tiled(m, 200)
    c.Focus_Client(m, x)
    c.Ensure_Active_Focus_Visible(m)
    saved := ws2.ViewportX

    c.Switch_WS_Id(m, 1)
    c.Arrange_All(m)
    ok(a.Geom.X >= 0, "active workspace window on screen")
    ok(x.Geom.X < -10000, "hidden workspace window parked off-screen")
    eq(ws2.ViewportX, saved, "hidden workspace viewport untouched")
}

// ----------------------------------------------------------------------------
// move window to another workspace
// ----------------------------------------------------------------------------

test_move_to_ws :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws1 := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)
    b := add_tiled(m, 101)
    eq(len(ws1.Cols), 2, "two columns on ws1")

    c.Focus_Client(m, a)
    ok(c.Move_Focused_To_WS(m, 2), "moved a to ws 2")

    // move does not switch the visible workspace (dwm-style)
    eq(c.Current_WS(m).Id, 1, "current workspace unchanged")
    ok(c.Current_WS(m).Focus == b, "ws1 focus fell back to b")
    eq(len(ws1.Cols), 1, "ws1 lost a column")

    ws2 := c.Find_WS(m, 2)
    eq(len(ws2.Cols), 1, "ws2 holds one column")
    eq(ws2.Cols[0].Wins[0], a, "a lives on ws2")
    ok(ws2.Focus == a, "ws2 focus is a")
}

test_scratchpads :: proc() {
    m := ipc_mk_man()
    defer c.Destroy_Manager(m)
    ws1 := c.Current_WS(m)
    a := add_tiled(m, 70)
    b := add_tiled(m, 71)

    ok(c.Scratchpad_Toggle_Register(m, 1), "first toggle assigns focused window")
    reg, registered := c.Scratchpad_Register_Of(m, b)
    ok(registered && reg == 1, "focused client is stored in register")
    ok(!b.Stashed && b.Ws == ws1, "registering does not immediately hide the client")

    ok(c.Scratchpad_Toggle_Register(m, 1), "second toggle stashes register")
    ok(b.Stashed && b.Ws == nil, "stashed client is detached from workspace")
    eq(len(ws1.Cols), 1, "stashed client no longer consumes a tile")
    eq(m.Focused, a, "stashing chooses workspace fallback focus")
    c.Arrange_All(m)
    eq(b.Geom.X, c.HIDE_X, "stashed client is parked off-screen")

    c.Switch_WS_Id(m, 2)
    ok(c.Scratchpad_Toggle_Register(m, 1), "hidden register summons on active workspace")
    ok(!b.Stashed && b.Ws == c.Current_WS(m), "summoned client follows active workspace")
    eq(m.Focused, b, "summoned client receives focus")

    ok(c.Scratchpad_Toggle_Register(m, 2, true), "floating register can be assigned")
    ok(b.Floating, "toggle-float changes assigned client to floating")
    scratchpad_json := c.ipc_windows_payload(m)
    ok(strings.contains(string(scratchpad_json), `"scratchpad_registers":[1,2]`),
        "window IPC lists every register in numeric order")
    delete(scratchpad_json)
    ok(c.Scratchpad_Remove_Register(m, 1), "remove forgets register")
    _, registered = c.Scratchpad_Register_Of(m, b)
    ok(registered, "another register for the same client remains")

    b.Class = strings.clone("Term")
    count, changed := c.Scratchpad_Toggle_Target(m, .Class, "Term")
    ok(count == 1 && changed && b.Stashed, "metadata target stashes exact matches")
    count, changed = c.Scratchpad_Toggle_Target(m, .AppId, "Term")
    ok(count == 1 && changed && !b.Stashed, "appid target summons class/instance match")

    c.Unmanage_Client(m, b)
    _, registered = c.Scratchpad_Register_Of(m, b)
    ok(!registered, "unmanage clears every register pointing at the client")
    c.Free_Client(b)
}

// ----------------------------------------------------------------------------
// docks (output-level panels) — model invariants
// ----------------------------------------------------------------------------

test_dock_model :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)
    o := c.Active_Output(m)

    d := add_dock(m, 300, c.Insets { Top = 24 }, c.Rect {})
    ok(d.Dock, "dock flagged")
    ok(d.Ws == nil, "dock belongs to no workspace")
    ok(!d.Floating, "dock is not a workspace floater")
    eq(len(o.Docks), 1, "dock registered on the output")
    ok(m.ByXid[300] == d, "dock in ByXid")
    eq(len(m.Clients), 2, "dock joins the client registry")
    eq(ws.Focus, a, "Add_Dock never steals focus")
    eq(m.Focused, a, "global focus untouched by Add_Dock")

    // docks are unfocusable (Ws == nil guard in Focus_Client)
    c.Focus_Client(m, d)
    eq(ws.Focus, a, "Focus_Client no-op on a dock")
    eq(m.Focused, a, "global focus unchanged after dock focus attempt")

    // a dock alone does not make its workspace non-empty
    ok(!c.Ws_Is_Empty(ws), "workspace with a tiled window is not empty")
    c.Switch_WS_Id(m, 2)
    ws2 := c.Ensure_WS(m, 2)
    ok(c.Ws_Is_Empty(ws2), "fresh workspace empty")
    ok(c.Ws_Is_Empty(nil), "nil workspace reports empty")
    c.Switch_WS_Id(m, 1)
    c.Unmanage_Client(m, a)
    ok(c.Ws_Is_Empty(ws), "workspace empty once its window is gone")
}

// Dock struts shrink the work area; the dock itself keeps its own geometry,
// borderless, wherever the client asked for it.
test_dock_geometry_and_struts :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)
    c.Arrange_All(m)
    eq(a.Geom, c.Rect { X = 10, Y = 10, W = 1900, H = 1060 }, "baseline: full work area")

    // a 24 px top panel: work area drops below it
    dock := add_dock(m, 300, c.Insets { Top = 24 }, c.Rect { X = 0, Y = 0, W = 1920, H = 24 })
    c.Arrange_All(m)
    eq(a.Geom, c.Rect { X = 10, Y = 34, W = 1900, H = 1036 }, "tiled window keeps its outer gap below the top strut")
    eq(dock.Geom, c.Rect { X = 0, Y = 0, W = 1920, H = 24 }, "dock keeps its requested rect")
    eq(dock.Border, 0, "docks are borderless")
    o := c.Active_Output(m)
    eq(o.Reserved, c.Insets { Top = 24 }, "output reserved = dock strut")

    // a second dock claims the bottom 28 px: both insets apply (per-side max)
    bdock := add_dock(m, 301, c.Insets { Bottom = 28 }, c.Rect { X = 0, Y = 1052, W = 1920, H = 28 })
    c.Arrange_All(m)
    eq(a.Geom, c.Rect { X = 10, Y = 34, W = 1900, H = 1008 }, "bottom strut keeps the outer gap too")
    eq(bdock.Geom, c.Rect { X = 0, Y = 1052, W = 1920, H = 28 }, "bottom dock sits at its rect")
    eq(o.Reserved, c.Insets { Top = 24, Bottom = 28 }, "per-side max across docks")
    drop_targets := c.Drop_Targets(m)
    eq(len(drop_targets), 4, "dock workarea still exposes four directional targets")
    for target in drop_targets {
        ok(target.HitGeom.Y >= 32 && target.HitGeom.Y + target.HitGeom.H <= 1044,
           "drop activation remains inside top/bottom struts")
    }
    delete(drop_targets)

    // a dock without client geometry defaults to a 24 px top strip
    naked := add_dock(m, 302, c.Insets {}, c.Rect {})
    c.Arrange_All(m)
    eq(naked.Geom, c.Rect { X = 0, Y = 0, W = 1920, H = 24 }, "empty dock rect -> default top strip")

    // compute_params honours arbitrary reservations (3rd-arg plumbing)
    cfg := c.Default_Config()
    p := c.compute_params(cfg, GEOM, 1, c.Insets { Left = 200 })
    eq(p.WorkX, 208, "left reservation is followed by the outer gap")
    eq(p.WorkW, 1704, "work width loses reservation and both outer gaps")
    p2 := c.compute_params(cfg, GEOM, 1, c.Insets { Right = 40 })
    eq(p2.WorkX, 8, "no left reservation -> outer gap as before")
    eq(p2.WorkW, 1864, "right reservation retains both outer gaps")
    // zero reservation reproduces the plain gap inset exactly
    p3 := c.compute_params(cfg, GEOM, 1)
    eq(p3.WorkX, 8, "zero insets: WorkX = outer gap")
    eq(p3.WorkY, 8, "zero insets: WorkY = outer gap")
    eq(p3.WorkW, 1904, "zero insets: WorkW = plain work width")
}

// Docks are output-level: they outlive workspace switches that park windows.
test_dock_sticky :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws1 := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)
    dock := add_dock(m, 300, c.Insets { Top = 24 }, c.Rect { X = 0, Y = 0, W = 1920, H = 24 })

    c.Switch_WS_Id(m, 2)
    c.Arrange_All(m)
    ok(a.Geom.X < -10000, "window of the inactive workspace parked off-screen")
    eq(dock.Geom, c.Rect { X = 0, Y = 0, W = 1920, H = 24 }, "dock stays on screen on every workspace")
    eq(len(c.Active_Output(m).Docks), 1, "dock still registered")

    c.Switch_WS_Id(m, 1)
    c.Arrange_All(m)
    eq(a.Geom, c.Rect { X = 10, Y = 34, W = 1900, H = 1036 }, "back on ws1 the window retiles below the dock")
    eq(ws1.ViewportX, 0, "dock does not disturb the viewport")
}

// Fullscreen covers the output while the dock retains its geometry underneath.
test_dock_fullscreen_coexists :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)
    dock := add_dock(m, 300, c.Insets { Top = 24 }, c.Rect { X = 0, Y = 0, W = 1920, H = 24 })

    c.Toggle_Fullscreen(m) // a is the workspace focus
    c.Arrange_All(m)
    eq(a.Geom, GEOM, "fullscreen covers the whole output")
    eq(a.Border, 0, "fullscreen borderless")
    eq(dock.Geom, c.Rect { X = 0, Y = 0, W = 1920, H = 24 }, "dock rect untouched by fullscreen")
    eq(ws.Focus, a, "fullscreen window keeps focus")
}

// Unmanaging a dock releases its reservation and the work area snaps back.
test_dock_unmanage_restores :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    a := add_tiled(m, 100)
    dock := add_dock(m, 300, c.Insets { Top = 24 }, c.Rect { X = 0, Y = 0, W = 1920, H = 24 })
    c.Arrange_All(m)
    eq(a.Geom, c.Rect { X = 10, Y = 34, W = 1900, H = 1036 }, "reserved layout before unmanage")

    nxt := c.Unmanage_Client(m, dock)
    ok(nxt == nil, "unmanaging a dock never yields a focus target")
    o := c.Active_Output(m)
    eq(len(o.Docks), 0, "dock list emptied")
    eq(o.Reserved, c.Insets {}, "reservation released")
    ok(m.ByXid[300] == nil, "dock unregistered from ByXid")
    eq(len(m.Clients), 1, "only the window remains registered")
    eq(ws.Focus, a, "window focus untouched by dock removal")

    c.Arrange_All(m)
    eq(a.Geom, c.Rect { X = 10, Y = 10, W = 1900, H = 1060 }, "work area restored to baseline")
}

// Ensure_Active_Focus_Visible (the third compute_params call site) must use
// the reserved inset or panning arithmetic goes wrong with a side dock.
test_dock_reserved_ensure_visible :: proc() {
    m := mk_man()
    defer c.Destroy_Manager(m)
    ws := c.Ensure_WS(m, 1)
    c.Switch_WS_Id(m, 1)
    add_dock(m, 300, c.Insets { Left = 200 }, c.Rect { X = 0, Y = 0, W = 200, H = 1080 })
    add_tiled(m, 100)
    add_tiled(m, 101)
    d := add_tiled(m, 102) // 3 columns over a 1704 px work width -> panning needed

    c.Focus_Client(m, d)
    c.Ensure_Active_Focus_Visible(m)
    // (1704 - 8) / 2 = 848 page width; total 3*848 + 2*8 = 2560; max vp = 856.
    eq(ws.ViewportX, 856, "viewport pan accounts for the side reservation")
    c.Arrange_All(m)
    ok(d.Geom.X + d.Geom.W <= 1920, "focused column fully on screen")
    eq(d.Geom.X, 1080, "drawn after reserving a left preview and its normal gap")
}

// ----------------------------------------------------------------------------
// i3-compatible IPC subset — pure wire code
// ----------------------------------------------------------------------------

// ws1() / ws2() helpers: a manager with workspaces 1 and 2, ws1 current.
ipc_mk_man :: proc() -> (m: ^c.Manager) {
    m = mk_man() // GEOM 1920x1080, output name "eDP-1"
    c.Switch_WS_Id(m, 1)
    c.Ensure_WS(m, 2)
    return m
}

// bytes_of copies a string literal into an owned byte slice. ([]byte on an
// untyped string *constant* is not a valid Odin conversion — only runtime
// values convert — so the tests go through a typed parameter.)
bytes_of :: proc(s: string) -> []byte {
    b := make([]byte, len(s))
    copy(b, s)
    return b
}

// eq_bytes compares a []byte against a string literal.
eq_bytes :: proc(got: []byte, want: string, msg: string, args: ..any) {
    if string(got) == want {
        g_pass += 1
    } else {
        g_fail += 1
        fmt.eprintln("FAIL:", fmt.tprintf(msg, ..args), " got=", string(got))
    }
}

test_ipc_frames :: proc() {
    // round-trip a subscribe frame whole
    pl := bytes_of(`["workspace","output"]`)
    defer delete(pl)
    frame := c.ipc_encode(.Subscribe, pl)
    defer delete(frame)
    eq(len(frame), 14 + len(pl), "frame = header + payload")
    eq(string(frame[0:6]), "i3-ipc", "magic prefix")
    ok(frame[6] == 0x16 && frame[7] == 0 && frame[8] == 0 && frame[9] == 0,
        "payload length u32le (22)")
    typ_bytes := [4]u8{2, 0, 0, 0}
    eq(string(frame[10:14]), string(typ_bytes[:]), "type u32le (subscribe = 2)")
    eq(string(frame[14:]), string(pl), "payload verbatim")

    // byte-by-byte feed reassembles one frame; remainder stays buffered
    r: c.Ipc_Reader
    for i in 0 ..< 7 {
        fr, good := c.ipc_reader_feed(&r, frame[i:i + 1])
        delete(fr)
        ok(good, "feed accepts partial header bytes")
    }
    fr, good := c.ipc_reader_feed(&r, frame[7:])
    ok(good, "feed completes the frame")
    defer delete(fr)
    eq(len(fr), 1, "one frame out")
    if len(fr) == 1 {
        eq(fr[0].typ, u32(c.Ipc_Type.Subscribe), "decoded type")
        eq(string(fr[0].payload), string(pl), "decoded payload")
        delete(fr[0].payload)
    }

    // two concatenated frames in one feed
    gp := bytes_of(`[{"num":1}]`)
    defer delete(gp)
    two := c.ipc_encode(.Get_Workspaces, gp)
    defer delete(two)
    both := make([]byte, len(frame) + len(two))
    copy(both, frame)
    copy(both[len(frame):], two)
    fr2, ok2 := c.ipc_reader_feed(&r, both)
    delete(both)
    ok(ok2, "concatenated frames parse")
    defer delete(fr2)
    eq(len(fr2), 2, "both frames out")
    if len(fr2) == 2 {
        eq(fr2[0].typ, u32(c.Ipc_Type.Subscribe), "first type")
        eq(fr2[1].typ, u32(c.Ipc_Type.Get_Workspaces), "second type")
    }
    for f in fr2 do delete(f.payload)

    // empty payload round-trips (zero-length body is legal)
    e := c.ipc_encode(.Command, nil)
    defer delete(e)
    eq(len(e), 14, "empty payload -> header only")
    fr3, ok3 := c.ipc_reader_feed(&r, e)
    ok(ok3, "empty frame parses")
    eq(len(fr3), 1, "one (empty) frame")
    if len(fr3) == 1 {
        eq(fr3[0].typ, u32(c.Ipc_Type.Command), "type preserved")
        eq(len(fr3[0].payload), 0, "payload empty")
        delete(fr3[0].payload)
    }
    delete(fr3)

    // malformed: bad magic drops the connection (fresh reader — a dropped
    // connection gets a new one in the server)
    r2: c.Ipc_Reader
    bad := bytes_of("XXXXXX" + "\x05\x00\x00\x00" + "\x00\x00\x00\x00" + "hello")
    fr4, ok4 := c.ipc_reader_feed(&r2, bad)
    delete(bad)
    ok(!ok4, "bad magic -> drop")
    delete(fr4)

    // malformed: declared length over the cap drops the connection
    r3: c.Ipc_Reader
    over := make([]byte, 14)
    copy(over, "i3-ipc")
    c.put_le_u32(over[6:10], c.IPC_MAX_PAYLOAD + 1)
    fr5, ok5 := c.ipc_reader_feed(&r3, over)
    delete(over)
    ok(!ok5, "oversized payload -> drop")
    delete(fr5)

    // a header split across feeds stays buffered until the frame completes
    half := c.ipc_encode(.Get_Outputs, nil)
    defer delete(half)
    fr6, ok6 := c.ipc_reader_feed(&r, half[:6])
    ok(ok6, "partial header feed ok")
    eq(len(fr6), 0, "no frame from a partial header")
    delete(fr6)
    fr7, ok7 := c.ipc_reader_feed(&r, half[6:])
    ok(ok7, "second feed completes")
    eq(len(fr7), 1, "frame emerges after the split")
    if len(fr7) == 1 {
        eq(fr7[0].typ, u32(c.Ipc_Type.Get_Outputs), "split-frame type")
        delete(fr7[0].payload)
    }
    delete(fr7)
}

test_ipc_workspaces_payload :: proc() {
    m := ipc_mk_man()
    defer c.Destroy_Manager(m)
    pl := c.ipc_workspaces_payload(m)
    defer delete(pl)
    // fixture output "eDP-1" spans 1920x1080 at (0,0); ws1 current -> focused.
    eq(string(pl), `[{"id":1,"num":1,"name":"1","visible":true,"focused":true,"urgent":false,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},"output":"eDP-1","windows":0},` +
        `{"id":2,"num":2,"name":"2","visible":false,"focused":false,"urgent":false,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},"output":"eDP-1","windows":0}]`,
        "GET_WORKSPACES: id order, ws1 focused")

    // switching to 2 flips the flags; id 3 created on demand joins sorted
    c.Switch_WS_Id(m, 3)
    c.Switch_WS_Id(m, 2)
    pl2 := c.ipc_workspaces_payload(m)
    defer delete(pl2)
    eq(string(pl2), `[{"id":1,"num":1,"name":"1","visible":false,"focused":false,"urgent":false,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},"output":"eDP-1","windows":0},` +
        `{"id":2,"num":2,"name":"2","visible":true,"focused":true,"urgent":false,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},"output":"eDP-1","windows":0},` +
        `{"id":3,"num":3,"name":"3","visible":false,"focused":false,"urgent":false,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},"output":"eDP-1","windows":0}]`,
        "GET_WORKSPACES: ws2 focused, empty ws3 listed")

    // no workspaces yet -> empty array (server-side guard; still valid JSON)
    m2 := mk_man()
    defer c.Destroy_Manager(m2)
    pl3 := c.ipc_workspaces_payload(m2)
    defer delete(pl3)
    eq(string(pl3), "[]", "GET_WORKSPACES with no workspaces")

    multi := c.New_Manager()
    defer c.Destroy_Manager(multi)
    c.Reconcile_Outputs(multi, []c.Output_Spec{
        {Name = "LEFT", Geom = c.Rect{X = 0, Y = 0, W = 1280, H = 800}, Primary = true},
        {Name = "RIGHT", Geom = c.Rect{X = 1280, Y = 0, W = 1280, H = 800}},
    })
    c.Focus_Output(multi, multi.Outputs[0])
    c.Switch_WS_Id(multi, 1)
    c.Focus_Output(multi, multi.Outputs[1])
    c.Switch_WS_Id(multi, 2)
    c.Focus_Output(multi, multi.Outputs[0])
    multi_payload := c.ipc_workspaces_payload(multi)
    defer delete(multi_payload)
    ok(strings.contains(string(multi_payload), `"output":"LEFT"`),
       "GET_WORKSPACES includes the primary output")
    ok(strings.contains(string(multi_payload), `"output":"RIGHT"`),
       "GET_WORKSPACES includes non-active outputs")
    ok(strings.contains(string(multi_payload),
       `"name":"2","visible":true,"focused":false,"urgent":false,"rect":{"x":1280`),
       "non-active output current workspace is visible but not focused")
}

test_ipc_outputs_payload :: proc() {
    m := ipc_mk_man()
    defer c.Destroy_Manager(m)
    pl := c.ipc_outputs_payload(m)
    defer delete(pl)
    eq(string(pl), `[{"name":"eDP-1","active":true,"primary":true,"focused":true,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},` +
        `"current_workspace":"1","power":true,"scale":1}]`,
        "GET_OUTPUTS: one output, ws1 current")

    c.Switch_WS_Id(m, 2)
    pl2 := c.ipc_outputs_payload(m)
    defer delete(pl2)
    ok(string(pl2) == `[{"name":"eDP-1","active":true,"primary":true,"focused":true,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},` +
        `"current_workspace":"2","power":true,"scale":1}]`,
        "GET_OUTPUTS follows the current workspace")

    m2 := mk_man() // no workspace activated yet
    defer c.Destroy_Manager(m2)
    pl3 := c.ipc_outputs_payload(m2)
    defer delete(pl3)
    ok(string(pl3) == `[{"name":"eDP-1","active":true,"primary":true,"focused":true,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},` +
        `"current_workspace":null,"power":true,"scale":1}]`,
        "GET_OUTPUTS: null current workspace before any activation")
}

test_ipc_windows_payload :: proc() {
    m := ipc_mk_man()
    defer c.Destroy_Manager(m)
    cl := add_tiled(m, 42)
    cl.Title = strings.clone("A \"quoted\" title")
    cl.Class = strings.clone("XTerm")
    cl.Instance = strings.clone("xterm")
    cl.Geom = c.Rect{X = 10, Y = 20, W = 800, H = 600}

    pl := c.ipc_windows_payload(m)
    defer delete(pl)
    eq(string(pl), `{"version":1,"windows":[{"id":42,"title":"A \"quoted\" title",` +
        `"class":"XTerm","instance":"xterm","workspace":1,"output":"eDP-1","focused":true,` +
        `"floating":false,"fullscreen":false,"scratchpad":false,"scratchpad_register":null,"scratchpad_registers":[],"urgent":false,"column":0,` +
        `"column_layout":"stacked","tab_index":0,"tab_count":1,"tab_active":false,"dock":false,` +
        `"rect":{"x":10,"y":20,"width":800,"height":600}}]}`,
        "GET_WINDOWS exposes metadata, state and geometry")

    ev := c.ipc_window_event_payload(m, c.IPC_WINDOW_FOCUS, cl)
    defer delete(ev)
    ok(strings.has_prefix(string(ev), `{"change":"focus","container":{"id":42,`),
        "window event wraps a client snapshot")
}

test_ipc_ws_event_payload :: proc() {
    m := ipc_mk_man()
    defer c.Destroy_Manager(m)
    ws1 := c.Find_WS(m, 1)
    ws2 := c.Find_WS(m, 2)

    // focus event: current = ws2, old = ws1
    pl := c.ipc_ws_event_payload(m, c.IPC_CHANGE_FOCUS, ws2, ws1)
    defer delete(pl)
    eq(string(pl), `{"change":"focus",` +
        `"current":{"id":2,"num":2,"name":"2","visible":false,"focused":false,"urgent":false,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},"output":"eDP-1","windows":0},` +
        `"old":{"id":1,"num":1,"name":"1","visible":true,"focused":true,"urgent":false,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},"output":"eDP-1","windows":0}}`,
        "workspace focus event carries current + old objects")

    // init/empty: no old workspace
    pl2 := c.ipc_ws_event_payload(m, c.IPC_CHANGE_INIT, ws2, nil)
    defer delete(pl2)
    eq(string(pl2), `{"change":"init",` +
        `"current":{"id":2,"num":2,"name":"2","visible":false,"focused":false,"urgent":false,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},"output":"eDP-1","windows":0},` +
        `"old":null}`, "workspace init event has no old")
    pl3 := c.ipc_ws_event_payload(m, c.IPC_CHANGE_EMPTY, ws1, nil)
    defer delete(pl3)
    eq(string(pl3), `{"change":"empty",` +
        `"current":{"id":1,"num":1,"name":"1","visible":true,"focused":true,"urgent":false,` +
        `"rect":{"x":0,"y":0,"width":1920,"height":1080},"output":"eDP-1","windows":0},` +
        `"old":null}`, "workspace empty event has no old")
}

test_ipc_command_reply_payload :: proc() {
    pl := c.ipc_command_reply_payload(true, "")
    defer delete(pl)
    eq(string(pl), `[{"success":true}]`, "success reply")

    pl2 := c.ipc_command_reply_payload(false, "unknown command")
    defer delete(pl2)
    eq(string(pl2), `[{"success":false,"error":"unknown command"}]`, "error reply")
}

test_ipc_parse_subscribe :: proc() {
    ws, out, win, shell_ui, fine := c.ipc_parse_subscribe(bytes_of(`["workspace","output"]`))
    ok(ws && out && !win && !shell_ui && fine, "workspace and output event kinds accepted")
    ws, out, win, shell_ui, fine = c.ipc_parse_subscribe(bytes_of(`["workspace","ui"]`))
    ok(ws && !out && !win && shell_ui && fine, "workspace and shell UI events accepted")
    ws, out, win, shell_ui, fine = c.ipc_parse_subscribe(bytes_of(`[]`))
    ok(!ws && !out && !win && !shell_ui && fine, "empty subscription accepted")
    // unknown names are accepted (i3 replies success; events never come)
    ws, out, win, shell_ui, fine = c.ipc_parse_subscribe(bytes_of(`["window","binding","shutdown"]`))
    ok(!ws && !out && win && !shell_ui && fine, "window and unknown event names accepted")

    ws, out, win, shell_ui, fine = c.ipc_parse_subscribe(bytes_of(`"workspace"`))
    ok(!fine, "non-array rejected")
    ws, out, win, shell_ui, fine = c.ipc_parse_subscribe(bytes_of(`[workspace]`))
    ok(!fine, "unquoted names rejected")
    ws, out, win, shell_ui, fine = c.ipc_parse_subscribe(bytes_of(`["workspace",`))
    ok(!fine, "unterminated list rejected")
    ws, out, win, shell_ui, fine = c.ipc_parse_subscribe(bytes_of(`["workspace",]`))
    ok(!fine, "trailing comma rejected")
    ws, out, win, shell_ui, fine = c.ipc_parse_subscribe(bytes_of(`["workspace" "output"]`))
    ok(!fine, "missing comma rejected")
    ws, out, win, shell_ui, fine = c.ipc_parse_subscribe(nil)
    ok(!fine, "empty payload rejected")
}

test_ipc_parse_command :: proc() {
    // err is "" (a literal, never freed) on success; on rejection it is an
    // owned strings.clone/builder string — delete only those.
    cmd, err, fine := c.ipc_parse_command(bytes_of(`workspace number 7`))
    ok(fine && cmd.action == .Workspace && cmd.arg == 7, "workspace number N parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`workspace 3`))
    ok(fine && cmd.action == .Workspace && cmd.arg == 3, "workspace N parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`  workspace   12  `))
    ok(fine && cmd.action == .Workspace && cmd.arg == 12, "surrounding whitespace tolerated")
    if err != "" do delete(err)

    cmd, err, fine = c.ipc_parse_command(bytes_of(`workspace next`))
    ok(fine && cmd.action == .Workspace_Next, "workspace next parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`workspace 4 output HDMI-1`))
    ok(fine && cmd.action == .Workspace_On_Output && cmd.arg == 4 && cmd.text == "HDMI-1",
       "output-qualified workspace command parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`focus left`))
    ok(fine && cmd.action == .Focus_Left, "focus left parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`focus window 4194309`))
    ok(fine && cmd.action == .Focus_Window && cmd.arg == 4194309,
       "focus window parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`focus window nope`))
    ok(!fine, "focus window rejects non-numeric id")
    eq(err, "focus window: expected a positive X11 window id", "focus window error")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`move workspace next`))
    ok(fine && cmd.action == .Move_To_Workspace_Next, "move workspace next parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`move workspace previous`))
    ok(fine && cmd.action == .Move_To_Workspace_Prev, "move workspace previous parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`layout tabbed`))
    ok(fine && cmd.action == .Layout_Tabbed, "layout tabbed parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`layout floating`))
    ok(fine && cmd.action == .Layout_Floating, "layout floating parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`layout tiling`))
    ok(fine && cmd.action == .Layout_Stacked, "layout tiling alias parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`layout stacking`))
    ok(fine && cmd.action == .Layout_Stacked, "layout stacking alias parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`gaps 16`))
    ok(fine && cmd.action == .Set_Gaps && cmd.arg == 16, "runtime gaps parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`gaps 101`))
    ok(!fine, "runtime gaps enforce upper bound")
    eq(err, "gaps: expected a value from 0 to 100", "runtime gaps error")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`toggle-tabbed`))
    ok(fine && cmd.action == .Layout_Toggle, "toggle-tabbed parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`show-bindings`))
    ok(fine && cmd.action == .Show_Bindings, "show-bindings parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`reminder add 15 stretch and drink water`))
    ok(fine && cmd.action == .Reminder_Add && cmd.arg == 15 && cmd.text == "stretch and drink water", "reminder add preserves message")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`scratchpad toggle 7`))
    ok(fine && cmd.action == .Scratchpad_Toggle && cmd.arg == 7, "scratchpad register toggle parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`scratchpad toggle-float 2`))
    ok(fine && cmd.action == .Scratchpad_Toggle_Float && cmd.arg == 2, "floating scratchpad toggle parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`scratchpad remove 2`))
    ok(fine && cmd.action == .Scratchpad_Remove && cmd.arg == 2, "scratchpad remove parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`scratchpad target title Music Player`))
    ok(fine && cmd.action == .Scratchpad_Target_Title && cmd.text == "Music Player", "scratchpad title target preserves spaces")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`scratchpad target title Music Player --spawn kitty --class music`))
    ok(fine && cmd.text == "Music Player" && cmd.spawn == "kitty --class music", "scratchpad target preserves match and spawn command")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`focus output next`))
    ok(fine && cmd.action == .Focus_Output_Next, "focus output next parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`move output previous`))
    ok(fine && cmd.action == .Move_To_Output_Prev, "move output previous parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`workspace`))
    ok(!fine, "bare workspace rejected")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`workspace number`))
    ok(!fine, "workspace number without id rejected")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`workspace 3.5`))
    ok(!fine, "non-integer id rejected")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`workspace 0`))
    ok(!fine, "id 0 rejected")
    eq(err, "workspace: id must be >= 1", "id bound rejection")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`workspace 4097`))
    ok(!fine, "workspace ids beyond the EWMH safety cap are rejected")
    eq(err, "workspace: id must be <= 4096", "workspace upper bound rejection")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`workspace 1; workspace 2`))
    ok(!fine, "command chaining rejected")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(nil)
    ok(!fine, "empty command rejected")
    if err != "" do delete(err)
}
