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
    test_workspaces()
    test_add_and_focus()
    test_focus_direction()
    test_move_dir()
    test_unmanage()
    test_floating()
    test_fullscreen()
    test_tabbed_layout()
    test_multi_output()
    test_layout_geometry()
    test_scrolling()
    test_two_columns_fit()
    test_arrange_hidden()
    test_move_to_ws()
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
    ok(cfg.FocusFollowsMouse, "default focus-follows-mouse")

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
    ok(a.Geom.H == b.Geom.H, "stacked windows equal height")
    eq(a.Geom.H, 524, "each client height = (1064 - 8) / 2, inset 2")
    eq(a.Geom.W, 1900, "merged single column refills the work width")
    eq(b.Geom.Y, 546, "b sits below a with inner gap + borders")
    eq(b.Geom.Y, a.Geom.Y + a.Geom.H + 2 * a.Border + 8, "client gap = inner + 2*border")
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
    eq(d.Geom.X, 966, "right column drawn at work_x + strip_x - viewport + border")
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
    eq(a.Geom.X, 10, "left column at work_x + border")
    eq(b.Geom.X, 966, "right column at work_x + (948+8) + border, fully visible")
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
    eq(a.Geom, c.Rect { X = 10, Y = 26, W = 1900, H = 1044 }, "tiled window starts below the top strut")
    eq(dock.Geom, c.Rect { X = 0, Y = 0, W = 1920, H = 24 }, "dock keeps its requested rect")
    eq(dock.Border, 0, "docks are borderless")
    o := c.Active_Output(m)
    eq(o.Reserved, c.Insets { Top = 24 }, "output reserved = dock strut")

    // a second dock claims the bottom 28 px: both insets apply (per-side max)
    bdock := add_dock(m, 301, c.Insets { Bottom = 28 }, c.Rect { X = 0, Y = 1052, W = 1920, H = 28 })
    c.Arrange_All(m)
    eq(a.Geom, c.Rect { X = 10, Y = 26, W = 1900, H = 1024 }, "bottom strut shortens the work area too")
    eq(bdock.Geom, c.Rect { X = 0, Y = 1052, W = 1920, H = 28 }, "bottom dock sits at its rect")
    eq(o.Reserved, c.Insets { Top = 24, Bottom = 28 }, "per-side max across docks")

    // a dock without client geometry defaults to a 24 px top strip
    naked := add_dock(m, 302, c.Insets {}, c.Rect {})
    c.Arrange_All(m)
    eq(naked.Geom, c.Rect { X = 0, Y = 0, W = 1920, H = 24 }, "empty dock rect -> default top strip")

    // compute_params honours arbitrary reservations (3rd-arg plumbing)
    cfg := c.Default_Config()
    p := c.compute_params(cfg, GEOM, 1, c.Insets { Left = 200 })
    eq(p.WorkX, 200, "left reservation overrides the outer gap")
    eq(p.WorkW, 1712, "work width loses left reservation + right gap")
    p2 := c.compute_params(cfg, GEOM, 1, c.Insets { Right = 40 })
    eq(p2.WorkX, 8, "no left reservation -> outer gap as before")
    eq(p2.WorkW, 1872, "right reservation trims the right edge")
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
    eq(a.Geom, c.Rect { X = 10, Y = 26, W = 1900, H = 1044 }, "back on ws1 the window retiles below the dock")
    eq(ws1.ViewportX, 0, "dock does not disturb the viewport")
}

// Fullscreen covers the output; docks remain drawn above it.
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
    eq(a.Geom, c.Rect { X = 10, Y = 26, W = 1900, H = 1044 }, "reserved layout before unmanage")

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
    d := add_tiled(m, 102) // 3 columns over a 1712 px work width -> panning needed

    c.Focus_Client(m, d)
    c.Ensure_Active_Focus_Visible(m)
    // (1712 - 8) / 2 = 852 page width; total 3*852 + 2*8 = 2572; max vp = 2572 - 1712.
    eq(ws.ViewportX, 860, "viewport pan accounts for the side reservation")
    c.Arrange_All(m)
    ok(d.Geom.X + d.Geom.W <= 1920, "focused column fully on screen")
    eq(d.Geom.X, 1062, "drawn at work_x 200 + strip 1720 - viewport 860 + border 2")
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
        `"floating":false,"fullscreen":false,"urgent":false,"column":0,` +
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
    ws, out, win, fine := c.ipc_parse_subscribe(bytes_of(`["workspace","output"]`))
    ok(ws && out && !win && fine, "workspace and output event kinds accepted")
    ws, out, win, fine = c.ipc_parse_subscribe(bytes_of(`["workspace"]`))
    ok(ws && !out && !win && fine, "workspace only")
    ws, out, win, fine = c.ipc_parse_subscribe(bytes_of(`[]`))
    ok(!ws && !out && !win && fine, "empty subscription accepted")
    // unknown names are accepted (i3 replies success; events never come)
    ws, out, win, fine = c.ipc_parse_subscribe(bytes_of(`["window","binding","shutdown"]`))
    ok(!ws && !out && win && fine, "window and unknown event names accepted")

    ws, out, win, fine = c.ipc_parse_subscribe(bytes_of(`"workspace"`))
    ok(!fine, "non-array rejected")
    ws, out, win, fine = c.ipc_parse_subscribe(bytes_of(`[workspace]`))
    ok(!fine, "unquoted names rejected")
    ws, out, win, fine = c.ipc_parse_subscribe(bytes_of(`["workspace",`))
    ok(!fine, "unterminated list rejected")
    ws, out, win, fine = c.ipc_parse_subscribe(bytes_of(`["workspace",]`))
    ok(!fine, "trailing comma rejected")
    ws, out, win, fine = c.ipc_parse_subscribe(bytes_of(`["workspace" "output"]`))
    ok(!fine, "missing comma rejected")
    ws, out, win, fine = c.ipc_parse_subscribe(nil)
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
    cmd, err, fine = c.ipc_parse_command(bytes_of(`focus left`))
    ok(fine && cmd.action == .Focus_Left, "focus left parsed")
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
    cmd, err, fine = c.ipc_parse_command(bytes_of(`layout stacking`))
    ok(fine && cmd.action == .Layout_Stacked, "layout stacking alias parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`toggle-tabbed`))
    ok(fine && cmd.action == .Layout_Toggle, "toggle-tabbed parsed")
    if err != "" do delete(err)
    cmd, err, fine = c.ipc_parse_command(bytes_of(`show-bindings`))
    ok(fine && cmd.action == .Show_Bindings, "show-bindings parsed")
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
