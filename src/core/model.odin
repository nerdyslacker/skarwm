package core

// Data model. These structs are pure data — no X11 types; an X window id is a
// plain u32. Membership is structural:
//
//   Manager
//     ├─ PhysicalOutputs[] Physical_Output (RandR-discovered hardware)
//     └─ Outputs[]      Output (logical WM screen)
//          └─ Ws[]      Workspace         (dynamic, sorted by id, kept when empty)
//               ├─ Cols[] Column
//               │    └─ Wins[] Client     (vertical stack order: top → bottom)
//               └─ Floaters[] Client      (windows not occupying a column slot)
//
// Hidden scratchpads remain in Manager.Clients/ByXid but are temporarily
// detached from the output workspace containers shown above.
//
// All Workspace/Column/Client pointers are heap-stable (created with new() and
// freed explicitly) so they may be cached in fields and containers freely.
//
// Names are exported (capitalized) so both the X11 layer (package main) and the
// unit-test runner can read and manipulate the model directly.

Rect :: struct {
    X, Y, W, H: i32,
}

// ICCCM WM_NORMAL_HINTS subset used by interactive resizing. Zero values mean
// that the corresponding constraint was not supplied by the client.
Size_Hints :: struct {
    MinW, MinH: i32,
    MaxW, MaxH: i32,
    BaseW, BaseH: i32,
    IncW, IncH: i32,
}

rect_empty :: proc(r: Rect) -> bool {
    return r.W <= 0 || r.H <= 0
}

// Per-side screen-edge reservation in pixels (0 = none). The zero value means
// "no reservation". Used for the work area a dock's strut claims.
Insets :: struct {
    Left, Right, Top, Bottom: i32,
}

// A single managed X11 window.
Client :: struct {
    Xid: u32,

    // Strings are heap allocated/cloned by the manager and freed on unmanage.
    Title:    string,
    Instance: string, // WM_CLASS[0]
    Class:    string, // WM_CLASS[1]

    Ws: ^Workspace, // owning workspace (stable); nil for docks/scratchpads
    Out: ^Output,   // owning/last output; also set for docks and scratchpads

    // Current display rectangle, computed by Arrange_All(); the X layer pushes
    // it to the server. (Named Geom, not Rect, so the field does not shadow the
    // Rect type inside the struct declaration.)
    Geom: Rect,

    // User/session geometry: where a floating window lives.
    FloatingRect: Rect,
    // Root geometry observed before the WM first arranged the window. Retained
    // so a late DOCK type can undo provisional tiling without guessing.
    InitialRect: Rect,

    Floating:   bool, // participates in floating layout (in ws.Floaters)
    // Set only when workspace-wide Floating mode moved this client out of the
    // tiled structure. It lets a later workspace layout restore those clients
    // without disturbing windows the user floated individually.
    LayoutFloating: bool,
    Fullscreen: bool, // covers the whole output while its workspace is current
    // Maximized is a work-area layout override, distinct from fullscreen and
    // from structural tiled/floating membership.  The restore snapshot lets
    // the pointer action undo the transition without losing session geometry.
    Maximized:          bool,
    MaxRestoreGeom:     Rect,
    MaxRestoreFloatRect: Rect,
    MaxRestoreFloating: bool,
    Urgent:     bool, // ICCCM WM_HINTS urgency flag
    Mapped:     bool, // the X layer has MapWindow'ed it
    Border:     i32, // border width to apply (0 while fullscreen), set by arrange
    SizeHints: Size_Hints,
    TileWeight: f64, // relative height inside a stacked column; 0 means default

    // Dock is an output-level panel window (_NET_WM_WINDOW_TYPE_DOCK). A dock
    // has Ws == nil and lives in Output.Docks: never tiled, never focused, and
    // never hidden on a workspace switch. Active fullscreen clients cover it.
    Dock: bool,
    // Stashed scratchpads remain managed by X but are detached from every
    // workspace and parked off-screen until summoned.
    Stashed: bool,
    // Strut is the per-side screen-edge reservation (px) this client claims
    // via _NET_WM_STRUT[_PARTIAL]; the X layer fills it and Output.Reserved
    // unions it with the other docks.
    Strut: Insets,
    // Stable edge offsets for a full-width/full-height dock. RandR monitor
    // geometry notifications can lag behind interactive split changes, so the
    // WM retains these anchors instead of accepting a stale panel resize.
    DockMargins: Insets,
    DockStretchX, DockStretchY: bool,
    // Resolved once from the global default plus the first matching rule.
    // Rendering remains a wm-layer responsibility.
    Decorated: bool,
    DecorationFrame: u32, // WM-owned override-redirect root child; 0 when absent
    DecorationFrameMapped: bool,
}

Column_Layout :: enum u8 {
    Stacked, // windows split the column vertically
    Tabbed,  // only the focused window occupies the column
}

// Workspace-wide presentation. Scroller preserves the column strip and its
// per-column stacked/tabbed grouping. Dwindle and Monocle present those tiled
// clients without scrolling; Floating changes workspace-managed windows to
// floating membership until another workspace layout is selected.
Workspace_Layout :: enum u8 {
    Scroller,
    Vertical_Scroller,
    Dwindle,
    Monocle,
    Floating,
}

Workspace_Layout_Name :: proc(layout: Workspace_Layout) -> string {
    switch layout {
    case .Scroller: return "scrolling-tile"
    case .Vertical_Scroller: return "vertical-scrolling-tile"
    case .Dwindle:  return "dwindle"
    case .Monocle:  return "monocle"
    case .Floating: return "floating"
    }
    return "scrolling-tile"
}

// One group of windows on a scrolling strip. It is a vertical column in the
// horizontal scroller and a horizontal row in the vertical scroller. Focus is
// also the active tab in tabbed mode.
Column :: struct {
    Wins:  [dynamic]^Client, // top → bottom
    Focus: ^Client, // most recently focused window inside this column
    Layout: Column_Layout,
    Width: i32, // desired tile width; 0 means the layout-derived default
    Height: i32, // desired vertical-scroller row height; 0 means default
}

// A workspace with independent horizontal and vertical scrolling viewports.
Workspace :: struct {
    Id: int,
    Layout: Workspace_Layout,
    Cols:      [dynamic]^Column,
    Floaters:  [dynamic]^Client,
    Focus:     ^Client, // most recently focused client of this workspace (any kind)
    ViewportX: i32, // px pan of the strip; kept per workspace
    ViewportY: i32, // px pan of the vertical strip; kept per workspace
}

Physical_Output :: struct {
    Geom: Rect, // authoritative RandR/root geometry
    Name: string,
    Primary: bool,
    Screens: [dynamic]^Output, // logical children, left-to-right
    Split: bool,
    SplitRatio: f64,
    SplitOffset: i32,
    SecondaryWorkspace: int,
}

// A logical WM screen. Each screen owns an independent dynamic workspace list
// and remembers its current workspace. With no virtual topology there is one
// Output per Physical_Output and both have the same name and geometry.
Output :: struct {
    Geom: Rect,
    RelativeGeom: Rect, // parent-relative; Geom is always in root coordinates
    Name: string, // stable logical ID (for example DP-1:right)
    Primary: bool,
    Virtual: bool,
    Parent: ^Physical_Output,
    Ws:      [dynamic]^Workspace, // sorted ascending by id; may include empties
    Current: ^Workspace,
    // Docks are output-level, workspace-less panels visible on every
    // workspace. Clients are still registered in Manager.Clients and freed
    // through that bulk list; this slice is only the membership container.
    Docks: [dynamic]^Client,
    // Reserved is the work-area reservation in px per screen edge, the per-side
    // max over the struts of this output's docks (see Update_Reserved).
    Reserved: Insets,
}

Output_Spec :: struct {
    Name: string,
    Geom: Rect,
    Primary: bool,
}

// The whole window manager state (excluding the X connection).
Manager :: struct {
    PhysicalOutputs: [dynamic]^Physical_Output,
    Outputs: [dynamic]^Output, // logical screens
    Active:  int, // index of the focused logical screen
    Clients: [dynamic]^Client, // every managed client, for bulk reconcile
    ByXid:   map[u32]^Client,
    // Session-only numbered scratchpad registers. A registered client may be
    // visible or stashed; closing it clears the corresponding entry.
    Scratchpad_Registers: map[int]^Client,
    Focused: ^Client, // the client holding X input focus (mirror of active ws)
    Cfg:     Config,
}

// ----------------------------------------------------------------------------
// Construction / teardown
// ----------------------------------------------------------------------------

New_Client :: proc(xid: u32) -> ^Client {
    cl := new(Client)
    cl.Xid = xid
    return cl
}

Free_Client :: proc(cl: ^Client) {
    if cl.Title != "" do delete(cl.Title)
    if cl.Instance != "" do delete(cl.Instance)
    if cl.Class != "" do delete(cl.Class)
    free(cl)
}

new_column :: proc() -> ^Column {
    c := new(Column)
    c.Wins = make([dynamic]^Client, 0, 4)
    return c
}

free_column :: proc(col: ^Column) {
    delete(col.Wins)
    free(col)
}

new_workspace :: proc(id: int) -> ^Workspace {
    ws := new(Workspace)
    ws.Id = id
    ws.Cols = make([dynamic]^Column, 0, 8)
    ws.Floaters = make([dynamic]^Client, 0, 2)
    return ws
}

free_workspace :: proc(ws: ^Workspace) {
    for col in ws.Cols do free_column(col)
    delete(ws.Cols)
    delete(ws.Floaters)
    free(ws)
}

free_output :: proc(o: ^Output) {
    for ws in o.Ws do free_workspace(ws)
    delete(o.Ws)
    delete(o.Docks) // slice only — dock clients are freed via Manager.Clients
    if o.Name != "" do delete(o.Name)
    free(o)
}

free_physical_output :: proc(p: ^Physical_Output) {
    if p == nil { return }
    delete(p.Screens) // references only; Manager.Outputs owns logical screens
    if p.Name != "" do delete(p.Name)
    free(p)
}

New_Manager :: proc() -> ^Manager {
    m := new(Manager)
    m.Cfg = Default_Config()
    m.PhysicalOutputs = make([dynamic]^Physical_Output, 0, 1)
    m.Outputs = make([dynamic]^Output, 0, 1)
    m.Clients = make([dynamic]^Client, 0, 32)
    m.ByXid = make(map[u32]^Client)
    m.Scratchpad_Registers = make(map[int]^Client)
    return m
}

Destroy_Manager :: proc(m: ^Manager) {
    // The registry owns every client, including detached scratchpads.
    for cl in m.Clients do Free_Client(cl)
    delete(m.Clients)
    clear(&m.ByXid)
    delete(m.ByXid)
    clear(&m.Scratchpad_Registers)
    delete(m.Scratchpad_Registers)
    for o in m.Outputs do free_output(o)
    delete(m.Outputs)
    for p in m.PhysicalOutputs do free_physical_output(p)
    delete(m.PhysicalOutputs)
    free(m)
}

// Setup_Output installs the screen-sized fallback used before/without a RandR
// 1.5 monitor scan.
Setup_Output :: proc(m: ^Manager, name: string, geom: Rect) -> ^Output {
    for o in m.Outputs do free_output(o)
    clear(&m.Outputs)
    for p in m.PhysicalOutputs do free_physical_output(p)
    clear(&m.PhysicalOutputs)
    p := new(Physical_Output)
    p.Geom = geom
    p.Name = strings_clone(name)
    p.Primary = true
    p.Screens = make([dynamic]^Output, 0, 2)
    p.SplitRatio = 0.5
    p.SecondaryWorkspace = 1
    o := new(Output)
    o.Geom = geom
    o.RelativeGeom = Rect{W = geom.W, H = geom.H}
    o.Name = strings_clone(name)
    o.Primary = true
    o.Parent = p
    o.Ws = make([dynamic]^Workspace, 0, 4)
    o.Docks = make([dynamic]^Client, 0, 2)
    append(&p.Screens, o)
    append(&m.PhysicalOutputs, p)
    append(&m.Outputs, o)
    m.Active = 0
    return o
}

// ----------------------------------------------------------------------------
// Small helpers
// ----------------------------------------------------------------------------

array_insert_at :: proc(arr: ^[dynamic]$T, index: int, value: T) {
    assert(index >= 0 && index <= len(arr))
    append(arr, value)
    for i := len(arr) - 1; i > index; i -= 1 {
        arr[i] = arr[i - 1]
    }
    arr[index] = value
}

column_member :: proc(col: ^Column, cl: ^Client) -> bool {
    if col == nil { return false }
    for w in col.Wins {
        if w == cl { return true }
    }
    return false
}

strings_clone :: proc(s: string) -> string {
    if s == "" { return "" }
    b := make([]byte, len(s))
    copy(b, s)
    return string(b)
}

// ----------------------------------------------------------------------------
// Lookups
// ----------------------------------------------------------------------------

Active_Output :: proc(m: ^Manager) -> ^Output {
    if m.Active < 0 || m.Active >= len(m.Outputs) { return nil }
    return m.Outputs[m.Active]
}

Output_Index :: proc(m: ^Manager, wanted: ^Output) -> int {
    if wanted == nil { return -1 }
    for o, i in m.Outputs { if o == wanted { return i } }
    return -1
}

Find_Output :: proc(m: ^Manager, name: string) -> ^Output {
    for o in m.Outputs { if o.Name == name { return o } }
    return nil
}

Find_Physical_Output :: proc(m: ^Manager, name: string) -> ^Physical_Output {
    if m == nil { return nil }
    for p in m.PhysicalOutputs { if p.Name == name { return p } }
    return nil
}

Output_Of_WS :: proc(m: ^Manager, wanted: ^Workspace) -> ^Output {
    if wanted == nil { return nil }
    for o in m.Outputs { for ws in o.Ws { if ws == wanted { return o } } }
    return nil
}

Output_At_Rect :: proc(m: ^Manager, r: Rect) -> ^Output {
    best: ^Output
    best_area: i64 = 0
    for o in m.Outputs {
        w := max(i32(0), min(r.X + r.W, o.Geom.X + o.Geom.W) - max(r.X, o.Geom.X))
        h := max(i32(0), min(r.Y + r.H, o.Geom.Y + o.Geom.H) - max(r.Y, o.Geom.Y))
        area := i64(w) * i64(h)
        if area > best_area { best, best_area = o, area }
    }
    if best == nil { return Nearest_Output(m, r.X + r.W / 2, r.Y + r.H / 2) }
    return best
}

// Nearest_Output returns the logical screen whose rectangle is nearest to the
// point. Distance is zero inside a rectangle, so it is also a containment
// lookup. Discovery order breaks exact ties deterministically.
Nearest_Output :: proc(m: ^Manager, x, y: i32) -> ^Output {
    if m == nil || len(m.Outputs) == 0 { return nil }
    best := m.Outputs[0]
    best_distance := i64(0x7fff_ffff_ffff_ffff)
    for o in m.Outputs {
        dx: i64
        dy: i64
        if x < o.Geom.X { dx = i64(o.Geom.X - x) }
        if x >= o.Geom.X + o.Geom.W { dx = i64(x - (o.Geom.X + o.Geom.W - 1)) }
        if y < o.Geom.Y { dy = i64(o.Geom.Y - y) }
        if y >= o.Geom.Y + o.Geom.H { dy = i64(y - (o.Geom.Y + o.Geom.H - 1)) }
        distance := dx * dx + dy * dy
        if distance < best_distance {
            best, best_distance = o, distance
        }
    }
    return best
}

// Output_At_Point returns the containing logical screen, or the geometrically
// nearest logical screen for points in RandR gaps/outside the desktop.
Output_At_Point :: proc(m: ^Manager, x, y: i32) -> ^Output {
    for o in m.Outputs {
        if x >= o.Geom.X && x < o.Geom.X + o.Geom.W &&
           y >= o.Geom.Y && y < o.Geom.Y + o.Geom.H {
            return o
        }
    }
    return Nearest_Output(m, x, y)
}

Current_WS :: proc(m: ^Manager) -> ^Workspace {
    o := Active_Output(m)
    if o == nil { return nil }
    return o.Current
}

// Find_WS returns the workspace with the given 1-based id, or nil.
Find_WS :: proc(m: ^Manager, id: int) -> ^Workspace {
    o := Active_Output(m)
    return Find_WS_On_Output(o, id)
}

Find_WS_On_Output :: proc(o: ^Output, id: int) -> ^Workspace {
    if o == nil { return nil }
    for ws in o.Ws {
        if ws.Id == id { return ws }
    }
    return nil
}

// Ensure_WS returns the workspace with the given id, creating it (in sorted
// position) when it does not exist yet.
Ensure_WS :: proc(m: ^Manager, id: int) -> ^Workspace {
    if id < 1 { return nil }
    o := Active_Output(m)
    return Ensure_WS_On_Output(o, id)
}

Ensure_WS_On_Output :: proc(o: ^Output, id: int) -> ^Workspace {
    if id < 1 || o == nil { return nil }
    if ws := Find_WS_On_Output(o, id); ws != nil { return ws }
    if o == nil { return nil }
    ws := new_workspace(id)
    i := 0
    for i < len(o.Ws) && o.Ws[i].Id < id { i += 1 }
    array_insert_at(&o.Ws, i, ws)
    return ws
}

logical_child_name :: proc(parent, suffix: string) -> string {
    if suffix == "" { return strings_clone(parent) }
    data := make([]byte, len(parent) + 1 + len(suffix))
    copy(data[:len(parent)], transmute([]u8)parent)
    data[len(parent)] = ':'
    copy(data[len(parent) + 1:], transmute([]u8)suffix)
    return string(data)
}

new_logical_output :: proc(p: ^Physical_Output, name: string, geom, relative: Rect, virtual: bool) -> ^Output {
    o := new(Output)
    o.Name = strings_clone(name)
    o.Geom = geom
    o.RelativeGeom = relative
    o.Primary = p != nil && p.Primary && relative.X == 0 && relative.Y == 0
    o.Virtual = virtual
    o.Parent = p
    o.Ws = make([dynamic]^Workspace, 0, 4)
    o.Docks = make([dynamic]^Client, 0, 2)
    o.Current = Ensure_WS_On_Output(o, 1)
    return o
}

rename_logical_output :: proc(o: ^Output, name: string) {
    if o == nil || o.Name == name { return }
    if o.Name != "" do delete(o.Name)
    o.Name = strings_clone(name)
}

set_unsplit_geometry :: proc(p: ^Physical_Output, o: ^Output) {
    if p == nil || o == nil { return }
    old_geom := o.Geom
    o.Geom = p.Geom
    o.RelativeGeom = Rect{W = p.Geom.W, H = p.Geom.H}
    o.Primary = p.Primary
    o.Virtual = false
    o.Parent = p
    rename_logical_output(o, p.Name)
    if old_geom != o.Geom {
        for d in o.Docks { Remap_Dock_To_Output(d, o) }
    }
}

MIN_LOGICAL_SCREEN_WIDTH :: i32(160)

split_rects :: proc(parent: Rect, ratio: f64, offset: i32) -> (left, right: Rect, ok: bool) {
    if parent.W < 2 * MIN_LOGICAL_SCREEN_WIDTH || parent.H <= 0 || ratio <= 0 || ratio >= 1 {
        return {}, {}, false
    }
    left_w := i32(f64(parent.W) * ratio + 0.5) + offset
    if left_w < MIN_LOGICAL_SCREEN_WIDTH ||
       left_w > parent.W - MIN_LOGICAL_SCREEN_WIDTH {
        return {}, {}, false
    }
    left = Rect{X = parent.X, Y = parent.Y, W = left_w, H = parent.H}
    right = Rect{X = parent.X + left_w, Y = parent.Y, W = parent.W - left_w, H = parent.H}
    return left, right, true
}

apply_split_geometry :: proc(p: ^Physical_Output) -> bool {
    if p == nil || len(p.Screens) != 2 { return false }
    left_rect, right_rect, ok := split_rects(p.Geom, p.SplitRatio, p.SplitOffset)
    if !ok { return false }
    left, right := p.Screens[0], p.Screens[1]
    old_left, old_right := left.Geom, right.Geom
    left.Geom = left_rect
    left.RelativeGeom = Rect{W = left_rect.W, H = left_rect.H}
    left.Primary = p.Primary
    left.Virtual = true
    left.Parent = p
    left_name := logical_child_name(p.Name, "left")
    rename_logical_output(left, left_name)
    delete(left_name)
    right.Geom = right_rect
    right.RelativeGeom = Rect{X = left_rect.W, W = right_rect.W, H = right_rect.H}
    right.Primary = false
    right.Virtual = true
    right.Parent = p
    right_name := logical_child_name(p.Name, "right")
    rename_logical_output(right, right_name)
    delete(right_name)
    if old_left != left.Geom {
        for d in left.Docks { Remap_Dock_To_Output(d, left) }
    }
    if old_right != right.Geom {
        for d in right.Docks { Remap_Dock_To_Output(d, right) }
    }
    return true
}

translate_floating_rect :: proc(r: Rect, from, to: Rect) -> Rect {
    moved := r
    moved.X = to.X + r.X - from.X
    moved.Y = to.Y + r.Y - from.Y
    moved.W = clamp(moved.W, i32(1), max(i32(1), to.W))
    moved.H = clamp(moved.H, i32(1), max(i32(1), to.H))
    moved.X = clamp(moved.X, to.X, to.X + to.W - moved.W)
    moved.Y = clamp(moved.Y, to.Y, to.Y + to.H - moved.H)
    return moved
}

migrate_output_state :: proc(m: ^Manager, src, dst: ^Output) {
    if m == nil || src == nil || dst == nil || src == dst { return }
    for cl in m.Clients {
        if cl.Stashed && cl.Out == src { cl.Out = dst }
    }
    for ws in src.Ws {
        target := Ensure_WS_On_Output(dst, ws.Id)
        for col in ws.Cols {
            for cl in col.Wins { cl.Ws = target; cl.Out = dst }
            append(&target.Cols, col)
        }
        clear(&ws.Cols)
        for cl in ws.Floaters {
            destination := Output_Work_Area(m, dst)
            if destination.W <= 0 || destination.H <= 0 { destination = dst.Geom }
            cl.FloatingRect = translate_floating_rect(cl.FloatingRect, src.Geom, destination)
            cl.Ws = target
            cl.Out = dst
            append(&target.Floaters, cl)
        }
        clear(&ws.Floaters)
        if target.Focus == nil { target.Focus = ws.Focus }
    }
    for d in src.Docks {
        d.Out = dst
        if d.Strut != (Insets{}) {
            Remap_Dock_To_Output(d, dst)
        } else {
            d.FloatingRect.X = HIDE_X
            d.Geom.X = HIDE_X
        }
        append(&dst.Docks, d)
    }
    clear(&src.Docks)
}

logical_list_from_physical :: proc(m: ^Manager) -> [dynamic]^Output {
    count := 0
    for p in m.PhysicalOutputs { count += len(p.Screens) }
    result := make([dynamic]^Output, 0, count)
    for p in m.PhysicalOutputs {
        for o in p.Screens { append(&result, o) }
    }
    return result
}

reset_active_output :: proc(m: ^Manager, wanted: ^Output) {
    m.Active = 0
    for o, i in m.Outputs {
        if o.Current == nil { o.Current = Ensure_WS_On_Output(o, 1) }
        if o == wanted { m.Active = i }
    }
    active := Active_Output(m)
    m.Focused = nil
    if active != nil && active.Current != nil { m.Focused = active.Current.Focus }
}

// Reconcile_Outputs treats specs as physical RandR outputs. Physical identity
// and full geometry are retained separately while Manager.Outputs is rebuilt
// as the ordered list of logical WM screens.
Reconcile_Outputs :: proc(m: ^Manager, specs: []Output_Spec) -> bool {
    if m == nil || len(specs) == 0 { return false }
    // Reject the complete candidate before mutating any live object. Negative
    // coordinates and overlaps/mirrors are valid RandR arrangements.
    for spec, i in specs {
        if spec.Name == "" || spec.Geom.W <= 0 || spec.Geom.H <= 0 { return false }
        for prior in specs[:i] { if prior.Name == spec.Name { return false } }
    }
    old_physical := m.PhysicalOutputs
    old_outputs := m.Outputs
    old_active := Active_Output(m)
    used := make([]bool, len(old_physical))
    defer delete(used)
    next_physical := make([dynamic]^Physical_Output, 0, len(specs))
    changed := len(old_physical) != len(specs)
    replacement_active := old_active

    for spec in specs {
        found := -1
        for p, i in old_physical {
            if !used[i] && p.Name == spec.Name { found = i; break }
        }
        p: ^Physical_Output
        if found >= 0 {
            used[found] = true
            p = old_physical[found]
            if found != len(next_physical) || p.Geom != spec.Geom || p.Primary != spec.Primary {
                changed = true
            }
            p.Geom = spec.Geom
            p.Primary = spec.Primary
            if p.Split {
                if !apply_split_geometry(p) {
                    // The current physical size cannot hold the configured
                    // split. Collapse safely using the current parent geometry.
                    if len(p.Screens) > 1 {
                        if replacement_active == p.Screens[1] { replacement_active = p.Screens[0] }
                        migrate_output_state(m, p.Screens[1], p.Screens[0])
                        free_output(p.Screens[1])
                        resize(&p.Screens, 1)
                    }
                    p.Split = false
                    set_unsplit_geometry(p, p.Screens[0])
                }
            } else if len(p.Screens) > 0 {
                set_unsplit_geometry(p, p.Screens[0])
            }
        } else {
            changed = true
            p = new(Physical_Output)
            p.Name = strings_clone(spec.Name)
            p.Geom = spec.Geom
            p.Primary = spec.Primary
            p.SplitRatio = 0.5
            p.SecondaryWorkspace = 1
            p.Screens = make([dynamic]^Output, 0, 2)
            o := new_logical_output(p, spec.Name, spec.Geom, Rect{W = spec.Geom.W, H = spec.Geom.H}, false)
            append(&p.Screens, o)
        }
        append(&next_physical, p)
    }

    target_physical := next_physical[0]
    for p in next_physical { if p.Primary { target_physical = p; break } }
    target := target_physical.Screens[0]
    if old_active != nil {
        for p in next_physical {
            for o in p.Screens { if o == old_active { target = old_active } }
        }
    }

    nearest_survivor :: proc(removed: ^Output, physical: []^Physical_Output, fallback: ^Output) -> ^Output {
        if removed == nil { return fallback }
        cx, cy := removed.Geom.X + removed.Geom.W / 2, removed.Geom.Y + removed.Geom.H / 2
        best := fallback
        best_distance := i64(0x7fff_ffff_ffff_ffff)
        for p in physical {
            for screen in p.Screens {
                dx, dy: i64
                if cx < screen.Geom.X { dx = i64(screen.Geom.X - cx) }
                if cx >= screen.Geom.X + screen.Geom.W { dx = i64(cx - (screen.Geom.X + screen.Geom.W - 1)) }
                if cy < screen.Geom.Y { dy = i64(screen.Geom.Y - cy) }
                if cy >= screen.Geom.Y + screen.Geom.H { dy = i64(cy - (screen.Geom.Y + screen.Geom.H - 1)) }
                distance := dx * dx + dy * dy
                if distance < best_distance { best, best_distance = screen, distance }
            }
        }
        return best
    }

    for p, i in old_physical {
        if used[i] { continue }
        for o in p.Screens {
            destination := nearest_survivor(o, next_physical[:], target)
            // Setup_Output installs a synthetic full-root "screen" before
            // RandR initialization. It has no user state whose geometric
            // affinity should override the real primary monitor.
            if len(old_physical) == 1 && p.Name == "screen" && len(m.Clients) == 0 {
                destination = target
            }
            removed_was_active := replacement_active == o
            removed_current_id := 0
            if removed_was_active && o.Current != nil { removed_current_id = o.Current.Id }
            if removed_was_active { replacement_active = destination }
            migrate_output_state(m, o, destination)
            if removed_was_active && removed_current_id > 0 {
                destination.Current = Ensure_WS_On_Output(destination, removed_current_id)
            }
            free_output(o)
        }
        clear(&p.Screens)
        free_physical_output(p)
    }

    delete(old_physical)
    m.PhysicalOutputs = next_physical
    delete(old_outputs)
    m.Outputs = logical_list_from_physical(m)
    Update_Reserved(m)
    if replacement_active == nil || Output_Index(m, replacement_active) < 0 {
        replacement_active = target
    }
    reset_active_output(m, replacement_active)
    return changed
}

// find_client_in_ws scans columns + floaters of a workspace for an xid.
find_client_in_ws :: proc(ws: ^Workspace, xid: u32) -> ^Client {
    if ws == nil { return nil }
    for col in ws.Cols {
        for w in col.Wins {
            if w.Xid == xid { return w }
        }
    }
    for w in ws.Floaters {
        if w.Xid == xid { return w }
    }
    return nil
}

// column_of returns the index (into ws.Cols), the column, and the row index of
// cl inside that column. Returns -1 / nil / -1 when cl is not a tiled window of
// ws (e.g. floating or foreign).
column_of :: proc(ws: ^Workspace, cl: ^Client) -> (col_idx: int, col: ^Column, row: int) {
    if ws == nil || cl == nil { return -1, nil, -1 }
    for i in 0 ..< len(ws.Cols) {
        c := ws.Cols[i]
        for j in 0 ..< len(c.Wins) {
            if c.Wins[j] == cl { return i, c, j }
        }
    }
    return -1, nil, -1
}
