package core

// Data model. These structs are pure data — no X11 types; an X window id is a
// plain u32. Membership is structural:
//
//   Manager
//     └─ Outputs[]      Output            (one today; arch supports more)
//          └─ Ws[]      Workspace         (dynamic, sorted by id, kept when empty)
//               ├─ Cols[] Column
//               │    └─ Wins[] Client     (vertical stack order: top → bottom)
//               └─ Floaters[] Client      (windows not occupying a column slot)
//
// All Workspace/Column/Client pointers are heap-stable (created with new() and
// freed explicitly) so they may be cached in fields and containers freely.
//
// Names are exported (capitalized) so both the X11 layer (package main) and the
// unit-test runner can read and manipulate the model directly.

Rect :: struct {
    X, Y, W, H: i32,
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

    Ws: ^Workspace, // owning workspace (stable)
    Out: ^Output,   // owning output; also set for output-level docks

    // Current display rectangle, computed by Arrange_All(); the X layer pushes
    // it to the server. (Named Geom, not Rect, so the field does not shadow the
    // Rect type inside the struct declaration.)
    Geom: Rect,

    // User/session geometry: where a floating window lives.
    FloatingRect: Rect,

    Floating:   bool, // participates in floating layout (in ws.Floaters)
    Fullscreen: bool, // covers the whole output while its workspace is current
    Urgent:     bool, // ICCCM WM_HINTS urgency flag
    Mapped:     bool, // the X layer has MapWindow'ed it
    Border:     i32, // border width to apply (0 while fullscreen), set by arrange

    // Dock is an output-level panel window (_NET_WM_WINDOW_TYPE_DOCK). A dock
    // has Ws == nil and lives in Output.Docks: never tiled, never focused,
    // never hidden on a workspace switch, kept above fullscreen windows.
    Dock: bool,
    // Strut is the per-side screen-edge reservation (px) this client claims
    // via _NET_WM_STRUT[_PARTIAL]; the X layer fills it and Output.Reserved
    // unions it with the other docks.
    Strut: Insets,
}

Column_Layout :: enum u8 {
    Stacked, // windows split the column vertically
    Tabbed,  // only the focused window occupies the column
}

// One group of windows on the horizontal strip. A column is either a vertical
// stack or a tabbed container; Focus is also the active tab in tabbed mode.
Column :: struct {
    Wins:  [dynamic]^Client, // top → bottom
    Focus: ^Client, // most recently focused window inside this column
    Layout: Column_Layout,
}

// A horizontal scrolling workspace.
Workspace :: struct {
    Id: int,
    Cols:      [dynamic]^Column,
    Floaters:  [dynamic]^Client,
    Focus:     ^Client, // most recently focused client of this workspace (any kind)
    ViewportX: i32, // px pan of the strip; kept per workspace
}

// A physical/logical RandR monitor. Each output owns an independent dynamic
// workspace list and remembers its current workspace.
Output :: struct {
    Geom: Rect,
    Name: string,
    Primary: bool,
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
    Outputs: [dynamic]^Output,
    Active:  int, // index of the focused output
    Clients: [dynamic]^Client, // every managed client, for bulk reconcile
    ByXid:   map[u32]^Client,
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

New_Manager :: proc() -> ^Manager {
    m := new(Manager)
    m.Cfg = Default_Config()
    m.Outputs = make([dynamic]^Output, 0, 1)
    m.Clients = make([dynamic]^Client, 0, 32)
    m.ByXid = make(map[u32]^Client)
    return m
}

Destroy_Manager :: proc(m: ^Manager) {
    // Every client lives in exactly one container; bulk-free via Clients list.
    for cl in m.Clients do Free_Client(cl)
    delete(m.Clients)
    clear(&m.ByXid)
    delete(m.ByXid)
    for o in m.Outputs do free_output(o)
    delete(m.Outputs)
    free(m)
}

// Setup_Output installs the screen-sized fallback used before/without a RandR
// 1.5 monitor scan.
Setup_Output :: proc(m: ^Manager, name: string, geom: Rect) -> ^Output {
    for o in m.Outputs do free_output(o)
    clear(&m.Outputs)
    o := new(Output)
    o.Geom = geom
    o.Name = strings_clone(name)
    o.Primary = true
    o.Ws = make([dynamic]^Workspace, 0, 4)
    o.Docks = make([dynamic]^Client, 0, 2)
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

Output_Of_WS :: proc(m: ^Manager, wanted: ^Workspace) -> ^Output {
    if wanted == nil { return nil }
    for o in m.Outputs { for ws in o.Ws { if ws == wanted { return o } } }
    return nil
}

Output_At_Rect :: proc(m: ^Manager, r: Rect) -> ^Output {
    best := Active_Output(m)
    best_area: i64 = 0
    for o in m.Outputs {
        w := max(i32(0), min(r.X + r.W, o.Geom.X + o.Geom.W) - max(r.X, o.Geom.X))
        h := max(i32(0), min(r.Y + r.H, o.Geom.Y + o.Geom.H) - max(r.Y, o.Geom.Y))
        area := i64(w) * i64(h)
        if area > best_area { best, best_area = o, area }
    }
    return best
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

// Reconcile_Outputs preserves output/workspace state by monitor name, updates
// geometry, creates newly connected outputs, and migrates all state from a
// disconnected output to the selected surviving output. At least one spec is
// required; callers keep their screen-sized fallback when RandR returns none.
Reconcile_Outputs :: proc(m: ^Manager, specs: []Output_Spec) -> bool {
    if len(specs) == 0 { return false }
    old := m.Outputs
    old_active := Active_Output(m)
    used := make([]bool, len(old))
    defer delete(used)
    next := make([dynamic]^Output, 0, len(specs))
    changed := len(old) != len(specs)

    for spec in specs {
        found := -1
        for o, i in old {
            if !used[i] && o.Name == spec.Name { found = i; break }
        }
        o: ^Output
        if found >= 0 {
            if found != len(next) { changed = true }
            used[found] = true
            o = old[found]
            if o.Geom != spec.Geom || o.Primary != spec.Primary { changed = true }
            o.Geom = spec.Geom
            o.Primary = spec.Primary
        } else {
            changed = true
            o = new(Output)
            o.Name = strings_clone(spec.Name)
            o.Geom = spec.Geom
            o.Primary = spec.Primary
            o.Ws = make([dynamic]^Workspace, 0, 4)
            o.Docks = make([dynamic]^Client, 0, 2)
            o.Current = Ensure_WS_On_Output(o, 1)
        }
        append(&next, o)
    }

    target := next[0]
    for o in next { if o.Primary { target = o; break } }
    if Output_Index(m, old_active) >= 0 {
        for o in next { if o == old_active { target = o; break } }
    }

    for old_o, oi in old {
        if used[oi] { continue }
        for ws in old_o.Ws {
            dst := Ensure_WS_On_Output(target, ws.Id)
            for col in ws.Cols {
                for cl in col.Wins { cl.Ws = dst; cl.Out = target }
                append(&dst.Cols, col)
            }
            clear(&ws.Cols)
            for cl in ws.Floaters {
                cl.Ws = dst
                cl.Out = target
                append(&dst.Floaters, cl)
            }
            clear(&ws.Floaters)
            if dst.Focus == nil { dst.Focus = ws.Focus }
        }
        for d in old_o.Docks { d.Out = target; append(&target.Docks, d) }
        clear(&old_o.Docks)
        free_output(old_o)
    }

    delete(old)
    m.Outputs = next
    m.Active = 0
    for o, i in m.Outputs {
        if o == target { m.Active = i }
        if o.Current == nil { o.Current = Ensure_WS_On_Output(o, 1) }
    }
    m.Focused = target.Current.Focus
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
