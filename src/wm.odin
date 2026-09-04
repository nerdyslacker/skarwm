package main

// The WM core glue: connects the pure model (core package) to the X server
// through the xcb layer. Responsibilities here are X-facing only — policy and
// geometry live in src/core. Each keyboard/mouse/ICCCM outcome ends by calling
// reflow() (arrange + push + focus), never by hand-editing rectangles.

import "core:time"
import c "core"

Tab_Decoration :: struct {
    Xid: u32,
    Client: ^c.Client,
    Bg: u32,
    Width: i32,
}

// Border colours come from Config.FocusedBorder / Config.UnfocusedBorder
// (0xRRGGBB), settable from the rc file (norm_outer_border / sel_outer_border).

Wm :: struct {
    conn:     ^Connection,
    root:     u32,
    scr_w:    i32,
    scr_h:    i32,
    m:        ^c.Manager,
    atoms:    map[string]u32,
    ewmh:     Ewmh_State, // EWMH/ICCCM bookkeeping (see ewmh.odin)
    kb:       Kbd_Map,
    mm:       Mod_Map,
    numlock:  u16,
    lock:     u16, // always MOD_MASK_LOCK; kept as field for symmetry
    primary_mod: u16,
    bindings: [dynamic]Binding,
    rules:        [dynamic]Raw_Rule, // applied to newly-managed windows
    ran_startups: [dynamic]string,   // startup commands already launched
    terminal: string,
    running:  bool,
    mouse_client: ^c.Client,
    mouse_resize: bool,
    mouse_root_x, mouse_root_y: i16,
    mouse_start: c.Rect,
    tabs: [dynamic]Tab_Decoration,
    tab_gc, tab_font: u32,
    help_window: u32,
    white_pixel: u32,
    tab_spawn_target: u32,
    tab_spawn_started: time.Tick,
}

g_wm: Wm

// ---------------------------------------------------------------------------
// atoms used by the WM core
// ---------------------------------------------------------------------------

atom :: proc(name: string) -> u32 {
    return intern_atom(g_wm.conn, &g_wm.atoms, name)
}

// ---------------------------------------------------------------------------
// geometry push / focus render
// ---------------------------------------------------------------------------

// reflow_inner recomputes and renders the layout. Most actions keep the
// focused column visible; explicit wheel scrolling disables that snap so the
// viewport can move independently of focus.
reflow_inner :: proc(ensure_focus_visible: bool) {
    if ensure_focus_visible { c.Ensure_Active_Focus_Visible(g_wm.m) }
    c.Arrange_All(g_wm.m)
    push_geoms()
    render_tabs()
    render_focus()
    ewmh_pulse() // reconcile desktop/fullscreen client properties (deduped)
    xcb_flush(g_wm.conn)
}

reflow :: proc() { reflow_inner(true) }
reflow_preserve_viewport :: proc() { reflow_inner(false) }

// push_geoms configures every managed window's position/size/border-width from
// the model (client rects already account for the border ring). Also maps any
// client that has not been mapped yet.
push_geoms :: proc() {
    m := g_wm.m
    for cl in m.Clients {
        geom := cl.Geom
        vals := [5]u32 {
            u32(i16(geom.X)),
            u32(i16(geom.Y)),
            u32(geom.W),
            u32(geom.H),
            u32(cl.Border),
        }
        xcb_configure_window(g_wm.conn, cl.Xid, CW_X | CW_Y | CW_WIDTH | CW_HEIGHT | CW_BORDER_WIDTH, &vals[0])
        if !cl.Mapped {
            xcb_map_window(g_wm.conn, cl.Xid)
            cl.Mapped = true
            ewmh_mark_mapped(cl) // ICCCM: WM_STATE Normal once mapped
        }
    }
}

// render_focus sets each window's border colour and applies X input focus to the
// focused client (or PointerRoot when there is no managed focus). Raising the
// focused window happens on workspace switches / focus changes that need it via
// raise_focused().
render_focus :: proc() {
    m := g_wm.m
    focused := m.Focused
    for cl in m.Clients {
        col := m.Cfg.UnfocusedBorder
        if cl == focused { col = m.Cfg.FocusedBorder }
        xcb_change_window_attributes(g_wm.conn, cl.Xid, CW_BORDER_PIXEL, &col)
    }
    apply_x_focus()
}

apply_x_focus :: proc() {
    focused := g_wm.m.Focused
    if focused != nil && focused.Mapped {
        xcb_set_input_focus(g_wm.conn, INPUT_FOCUS_POINTER_ROOT, focused.Xid, CURRENT_TIME)
        ewmh_announce_take_focus(focused) // courtesy for Xt/Java-style clients
    } else {
        // With no managed client, focus the pointer root (dest == PointerRoot).
        // Focus None would discard every key event, which also disables our
        // passive grabs on the root — on an empty desktop Super+Return and the
        // other bindings would silently die.
        xcb_set_input_focus(g_wm.conn, INPUT_FOCUS_POINTER_ROOT, u32(INPUT_FOCUS_POINTER_ROOT), CURRENT_TIME)
    }
    ewmh_push_active(focused)
}

raise_focused :: proc() {
    if f := g_wm.m.Focused; f != nil {
        stack := STACK_MODE_ABOVE
        xcb_configure_window(g_wm.conn, f.Xid, CW_STACK_MODE, &stack)
    }
    raise_docks() // docks stay stacked above the focused window (fullscreen included)
}

// raise_docks stacks every dock of the active output on top. This only needs
// to happen
// where a dock can overlap something: after raising/focusing a window (toggled
// fullscreen, ws switches) and after mapping a new window (the server maps it
// on top of the stack).
raise_docks :: proc() {
    for o in g_wm.m.Outputs {
        for d in o.Docks {
            stack := STACK_MODE_ABOVE
            xcb_configure_window(g_wm.conn, d.Xid, CW_STACK_MODE, &stack)
        }
    }
}

// ---------------------------------------------------------------------------
// window metadata
// ---------------------------------------------------------------------------

// manage reads window metadata and adds the window to the model, maps it and
// focuses it. `float_override` forces floating (used for dialog-style windows).
manage :: proc(xid: u32, float_override: bool) {
    m := g_wm.m
    if _, ok := m.ByXid[xid]; ok {
        return // already managed
    }
    old_focus := m.Focused
    tab_target: ^c.Client
    if g_wm.tab_spawn_target != 0 && time.tick_since(g_wm.tab_spawn_started) <= 10 * time.Second {
        tab_target = m.ByXid[g_wm.tab_spawn_target]
    }
    // A shifted spawn applies to one resulting top-level window only. The
    // timeout prevents a failed command from capturing an unrelated window.
    g_wm.tab_spawn_target = 0
    cl := c.New_Client(xid)
    read_client_meta(cl)
    read_client_urgency(cl)

    // select events on the client so we see title changes, strut updates and
    // pointer hovers. (Child unmap/destroy/configure is already reported by the
    // root SUBSTRUCTURE_NOTIFY grab, so STRUCTURE_NOTIFY here is unnecessary.)
    evmask := EVENT_MASK_PROPERTY_CHANGE | EVENT_MASK_ENTER_WINDOW
    xcb_change_window_attributes(g_wm.conn, xid, CW_EVENT_MASK, &evmask)
    grab_client_buttons(xid)

    // Dock windows (_NET_WM_WINDOW_TYPE_DOCK) are output-level panels: never
    // tiled, focused, or hidden. Classify before the fullscreen/rules handling
    // — a dock is a dock even if it carries fullscreen state or matches a rule.
    if read_window_type(cl) {
        cl.Dock = true
        read_struts(cl)
        read_dock_geometry(cl)
        c.Add_Dock_To_Output(m, c.Output_At_Rect(m, cl.FloatingRect), cl)
        ewmh_client_managed(cl) // _NET_CLIENT_LIST (no _NET_WM_DESKTOP: Ws == nil)
        reflow() // arranges the dock and maps it (push_geoms)
        raise_docks() // a fresh map lands on top of the stack — put the dock there
        ipc_broadcast_window_event(c.IPC_WINDOW_NEW, cl)
        return
    }

    adopt_pre_fullscreen(cl) // inherit _NET_WM_STATE_FULLSCREEN set before mapping

    ws := c.Current_WS(m)
    if ws == nil {
        ws = c.Ensure_WS(m, 1)
        c.Activate_WS(m, ws)
    }
    floating := float_override
    if tgt, fl, hit := rule_for_client(cl); hit {
        if tgt != nil { ws = tgt }
        floating = floating || fl
    }
    c.Add_Managed(m, ws, cl, floating, tab_target)
    ewmh_client_managed(cl) // _NET_CLIENT_LIST + _NET_WM_DESKTOP
    reflow()
    raise_docks() // the new window mapped on top of the stack — docks go above
    ipc_broadcast_window_event(c.IPC_WINDOW_NEW, cl)
    ipc_broadcast_focus_change(old_focus, m.Focused)
}

// read_window_type reports whether the client's _NET_WM_WINDOW_TYPE atom list
// names DOCK (a dock/panel window).
read_window_type :: proc(cl: ^c.Client) -> bool {
    data, ok := get_prop(g_wm.conn, cl.Xid, atom("_NET_WM_WINDOW_TYPE"), atom("ATOM"))
    if !ok { return false }
    defer delete(data)
    if len(data) % 4 != 0 { return false }
    dock := atom("_NET_WM_WINDOW_TYPE_DOCK")
    vals := ([^]u32)(raw_data(data))[:len(data) / 4]
    for v in vals {
        if v == dock { return true }
    }
    return false
}

// read_struts fills cl.Strut from _NET_WM_STRUT_PARTIAL (the four per-edge
// widths come first among its 12 CARDINAL values) or, failing that,
// _NET_WM_STRUT (4 CARDINAL). The begin/end edge ranges of the partial form
// are deliberately ignored: a dock reserves the full corresponding edge of
// the RandR monitor containing its geometry.
read_struts :: proc(cl: ^c.Client) {
    cl.Strut = c.Insets {}
    if data, ok := get_prop(g_wm.conn, cl.Xid, atom("_NET_WM_STRUT_PARTIAL"), atom("CARDINAL")); ok {
        defer delete(data)
        if len(data) >= 12 * 4 {
            vals := ([^]u32)(raw_data(data))
            cl.Strut.Left = i32(vals[0])
            cl.Strut.Right = i32(vals[1])
            cl.Strut.Top = i32(vals[2])
            cl.Strut.Bottom = i32(vals[3])
            return
        }
    }
    if data, ok := get_prop(g_wm.conn, cl.Xid, atom("_NET_WM_STRUT"), atom("CARDINAL")); ok {
        defer delete(data)
        if len(data) >= 4 * 4 {
            vals := ([^]u32)(raw_data(data))
            cl.Strut.Left = i32(vals[0])
            cl.Strut.Right = i32(vals[1])
            cl.Strut.Top = i32(vals[2])
            cl.Strut.Bottom = i32(vals[3])
        }
    }
}

// read_dock_geometry snapshots the client's own geometry as its floating rect:
// docks keep what they asked for (arrange only clamps). Fallback when the
// query fails: a strip across the top of the screen.
read_dock_geometry :: proc(cl: ^c.Client) {
    cookie := xcb_get_geometry(g_wm.conn, cl.Xid)
    e: ^Error
    reply := xcb_get_geometry_reply(g_wm.conn, cookie, &e)
    if e != nil {
        free_libc(e)
        reply = nil
    }
    if reply != nil {
        defer free_libc(reply)
        cl.FloatingRect = c.Rect { X = i32(reply.x), Y = i32(reply.y), W = i32(reply.width), H = i32(reply.height) }
        return
    }
    cl.FloatingRect = c.Rect { X = 0, Y = 0, W = g_wm.scr_w, H = 24 }
}

// read_client_meta fills title/class/instance from the X properties.
read_client_meta :: proc(cl: ^c.Client) {
    cl.Title = read_client_title(cl.Xid)
    // WM_CLASS: two NUL-separated strings: instance then class
    data, ok := get_prop(g_wm.conn, cl.Xid, atom("WM_CLASS"), 0)
    if !ok || len(data) == 0 {
        if ok { delete(data) }
        return
    }
    defer delete(data)
    start := 0
    seg := 0
    for i := 0; i <= len(data); i += 1 {
        if i == len(data) || data[i] == 0 {
            s := string(data[start:i])
            if len(s) > 0 {
                switch seg {
                case 0:
                    cl.Instance = clone_bytes(s)
                case 1:
                    cl.Class = clone_bytes(s)
                }
                seg += 1
            }
            start = i + 1
        }
    }
}

read_client_title :: proc(xid: u32) -> string {
    if s, ok := get_text_prop(g_wm.conn, xid, atom("_NET_WM_NAME"), atom("UTF8_STRING")); ok {
        return s
    }
    if s, ok := get_text_prop(g_wm.conn, xid, atom("WM_NAME"), 0); ok {
        return s
    }
    return ""
}

read_client_urgency :: proc(cl: ^c.Client) -> bool {
    data, ok := get_prop(g_wm.conn, cl.Xid, atom("WM_HINTS"), 0)
    urgent := false
    if ok {
        if len(data) >= 4 {
            flags := (^u32)(raw_data(data))^
            urgent = flags & (1 << 8) != 0 // ICCCM XUrgencyHint
        }
        delete(data)
    }
    changed := cl.Urgent != urgent
    cl.Urgent = urgent
    return changed
}

clone_bytes :: proc(s: string) -> string {
    if s == "" { return "" }
    b := make([]byte, len(s))
    copy(b, s)
    return string(b)
}

// get_text_prop fetches an owned string from a window property of a specific
// type (type_id 0 = any).
get_text_prop :: proc(conn: ^Connection, win, prop, type_id: u32) -> (string, bool) {
    if prop == 0 { return "", false }
    data, ok := get_prop(conn, win, prop, type_id)
    if !ok || len(data) == 0 {
        if ok { delete(data) }
        return "", false
    }
    n := len(data)
    if data[n - 1] == 0 { n -= 1 }
    out := make([]byte, n)
    copy(out, data[:n])
    delete(data)
    return string(out), true
}

// ---------------------------------------------------------------------------
// unmanage
// ---------------------------------------------------------------------------

// unmanage removes the window from the model and frees it, returning the
// replacement focus (already applied to X) — or nil if none.
unmanage :: proc(cl: ^c.Client) {
    dock := cl.Dock
    ws := cl.Ws // captured for the empty-workspace announcement below
    was_focused := g_wm.m.Focused == cl
    ipc_broadcast_window_event(c.IPC_WINDOW_CLOSE, cl)
    c.Unmanage_Client(g_wm.m, cl) // docks: removed from Output.Docks, reservation released
    new_focus := g_wm.m.Focused
    ewmh_client_unmanaged(cl) // WM_STATE Withdrawn + _NET_CLIENT_LIST refresh
    // drop events so the X server stops notifying us about this window
    c.Free_Client(cl)
    if dock {
        reflow() // tiled windows regain the released reservation
        return
    }
    // The workspace the window lived on stays alive (skarwm keeps empty
    // workspaces); its last window leaving is what i3 reports as "empty".
    if ws != nil && c.Ws_Is_Empty(ws) {
        ipc_broadcast_ws_event(c.IPC_CHANGE_EMPTY, ws, nil)
    }
    if was_focused {
        reflow()
        ipc_broadcast_focus_change(cl, new_focus)
    } else {
        // still redraw borders/focus in case of focus juggling
        render_focus()
        render_tabs() // an inactive tab may have been the removed client
        xcb_flush(g_wm.conn)
    }
}

// ---------------------------------------------------------------------------
// key handling
// ---------------------------------------------------------------------------

// grab_all_keys (re)installs the root grabs for every binding. The four
// lock/numlock variants follow the recipe in docs/REFERENCE_NOTES.md §2/§3.
grab_all_keys :: proc() {
    xcb_ungrab_key(g_wm.conn, 0, g_wm.root, MOD_MASK_ANY) // keycode 0 == AnyKey
    // Resolve first so explicit combinations can take precedence over the
    // automatically derived Shift+spawn layer below.
    for i in 0 ..< len(g_wm.bindings) {
        b := &g_wm.bindings[i]
        kc, level := keysym_to_keycode(&g_wm.kb, b.keysym)
        if kc == 0 {
            log_warn("cannot bind keysym", b.keysym, "(not in keymap)")
            continue
        }
        mods := b.mods
        if level & 1 == 1 { mods |= MOD_MASK_SHIFT }
        b.effective_mods = mods
        b.keycode = kc
    }
    combos := [4]u16{0, g_wm.lock, g_wm.numlock, g_wm.lock | g_wm.numlock}
    for i in 0 ..< len(g_wm.bindings) {
        b := &g_wm.bindings[i]
        if b.keycode == 0 { continue }
        for combo in combos {
            xcb_grab_key(g_wm.conn, 0, g_wm.root, b.effective_mods | combo, b.keycode, GRAB_MODE_ASYNC, GRAB_MODE_ASYNC)
        }
    }
    for i in 0 ..< len(g_wm.bindings) {
        b := &g_wm.bindings[i]
        if b.action != .Spawn || b.keycode == 0 || b.effective_mods & MOD_MASK_SHIFT != 0 { continue }
        derived := b.effective_mods | MOD_MASK_SHIFT
        claimed := false
        for other in g_wm.bindings {
            if other.keycode == b.keycode && other.effective_mods == derived { claimed = true; break }
        }
        if claimed { continue }
        for combo in combos {
            xcb_grab_key(g_wm.conn, 0, g_wm.root, derived | combo, b.keycode, GRAB_MODE_ASYNC, GRAB_MODE_ASYNC)
        }
    }
}

// key press dispatch: match by exact (mods,keycode) after stripping Lock/NumLock.
on_keypress :: proc(ev: ^Key_Press_Event) {
    clean := ev.state & ~(g_wm.lock | g_wm.numlock)
    for i in 0 ..< len(g_wm.bindings) {
        b := &g_wm.bindings[i]
        if b.keycode != 0 && clean == b.effective_mods && ev.detail == b.keycode {
            dispatch_action(b)
            return
        }
    }
    // An otherwise-unbound Shift variant of any spawn binding reuses the same
    // command and requests that its next window join the active tab group.
    if clean & MOD_MASK_SHIFT != 0 {
        base_mods := clean & ~MOD_MASK_SHIFT
        for i in 0 ..< len(g_wm.bindings) {
            b := &g_wm.bindings[i]
            if b.action != .Spawn || b.keycode == 0 { continue }
            if b.effective_mods == base_mods && ev.detail == b.keycode {
                g_wm.tab_spawn_target = 0
                if focused := g_wm.m.Focused; focused != nil && !focused.Floating {
                    if _, col, _ := c.Column_Of(focused); col != nil && col.Layout == .Tabbed {
                        g_wm.tab_spawn_target = focused.Xid
                        g_wm.tab_spawn_started = time.tick_now()
                    }
                }
                dispatch_action(b)
                return
            }
        }
    }
}

Action_Kind :: enum u8 {
    None,
    Spawn, // b.cmd — a shell command line to launch (no arg)
    Focus_Left, Focus_Right, Focus_Up, Focus_Down,
    Move_Left, Move_Right, Move_Up, Move_Down,
    Toggle_Floating,
    Toggle_Fullscreen,
    Layout_Tabbed, Layout_Stacked, Layout_Toggle,
    Show_Bindings,
    Close,
    Reload, // re-run the configuration loader
    Quit,   // exit the WM (cleanup_all runs via main's defer)
    WS_Next, WS_Prev,
    WS_Goto,   // arg = workspace id (>=1)
    Move_To_WS, // arg = workspace id (>=1)
    Move_To_WS_Next, Move_To_WS_Prev,
    Focus_Output_Next, Focus_Output_Prev,
    Move_To_Output_Next, Move_To_Output_Prev,
}

Binding :: struct {
    mods:    u16,
    effective_mods: u16, // declared mods plus any Shift required by the keysym level
    keysym:  u32,
    keycode: u8,
    action:  Action_Kind,
    arg:     int,
    cmd:     string, // owned; only meaningful for .Spawn
    combo:   string, // owned; original configuration spelling for help output
}

dir_of :: proc(k: Action_Kind) -> c.Dir {
    #partial switch k {
    case .Focus_Left, .Move_Left:   return .Left
    case .Focus_Right, .Move_Right: return .Right
    case .Focus_Up, .Move_Up:       return .Up
    case .Focus_Down, .Move_Down:   return .Down
    }
    return .Left
}

dispatch_action :: proc(b: ^Binding) {
    m := g_wm.m
    old_focus := m.Focused
    switch b.action {
    case .None:
        return
    case .Spawn:
        if b.cmd != "" { spawn_sh(b.cmd) }
    case .Reload:
        cfg_reload()
    case .Quit:
        g_wm.running = false
    case .Focus_Left, .Focus_Right, .Focus_Up, .Focus_Down:
        if c.Focus_Dir(m, dir_of(b.action)) {
            reflow()
        }
    case .Move_Left, .Move_Right, .Move_Up, .Move_Down:
        if c.Move_Dir(m, dir_of(b.action)) {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Toggle_Floating:
        if c.Toggle_Floating(m) { reflow() }
    case .Toggle_Fullscreen:
        if _, changed := c.Toggle_Fullscreen(m); changed {
            raise_focused()
            reflow()
        }
    case .Layout_Tabbed:
        if c.Set_Column_Layout(m, .Tabbed) {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Layout_Stacked:
        if c.Set_Column_Layout(m, .Stacked) {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Layout_Toggle:
        if c.Toggle_Column_Layout(m) {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Show_Bindings:
        help_toggle()
    case .Close:
        close_focused()
    case .WS_Next:
        ws_rel(1)
    case .WS_Prev:
        ws_rel(-1)
    case .WS_Goto:
        ws_switch_to(b.arg)
    case .Move_To_WS:
        move_focused_to_ws(b.arg)
    case .Move_To_WS_Next:
        move_focused_to_ws_rel(1)
    case .Move_To_WS_Prev:
        move_focused_to_ws_rel(-1)
    case .Focus_Output_Next:
        focus_output_rel(1)
    case .Focus_Output_Prev:
        focus_output_rel(-1)
    case .Move_To_Output_Next:
        move_focused_to_output_rel(1)
    case .Move_To_Output_Prev:
        move_focused_to_output_rel(-1)
    }
    if b.action != .WS_Next && b.action != .WS_Prev && b.action != .WS_Goto {
        ipc_broadcast_focus_change(old_focus, m.Focused)
    }
}

focus_output_rel :: proc(dir: int) {
    m := g_wm.m
    old_focus := m.Focused
    old_ws := c.Current_WS(m)
    if !c.Focus_Output_Rel(m, dir) { return }
    ipc_broadcast_output_event("focus", c.Active_Output(m).Name)
    ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, c.Current_WS(m), old_ws)
    raise_focused()
    reflow()
}

move_focused_to_output_rel :: proc(dir: int) {
    m := g_wm.m
    src := c.Current_WS(m)
    moved := m.Focused
    if !c.Move_Focused_To_Output_Rel(m, dir) { return }
    if src != nil && c.Ws_Is_Empty(src) {
        ipc_broadcast_ws_event(c.IPC_CHANGE_EMPTY, src, nil)
    }
    reflow()
    ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, moved)
}

move_focused_to_ws_rel :: proc(dir: int) {
    ws := c.Current_WS(g_wm.m)
    if ws == nil { return }
    target := ws.Id + dir
    if target >= 1 { move_focused_to_ws(target) }
}

// ws_switch_to activates workspace id (creating it when missing — dynamic
// workspaces), announces the change to IPC subscribers and runs the
// post-switch housekeeping. Subscribers see "init" for a freshly created
// workspace — emitted before it is focused — then "focus" with the old and
// new workspace. Switching to the current workspace is a no-op for events
// but still reflows (the pre-IPC behaviour).
ws_switch_to :: proc(id: int) -> bool {
    m := g_wm.m
    old_focus := m.Focused
    if id < 1 { return false }
    old := c.Current_WS(m)
    if old != nil && old.Id == id {
        raise_focused()
        reflow()
        return true
    }
    new := c.Find_WS(m, id)
    if new == nil {
        new = c.Ensure_WS(m, id)
        if new == nil { return false }
        ipc_broadcast_ws_event(c.IPC_CHANGE_INIT, new, nil)
    }
    c.Activate_WS(m, new)
    ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, new, old)
    raise_focused()
    reflow()
    ipc_broadcast_focus_change(old_focus, m.Focused)
    return true
}

// ws_rel switches one workspace step by id: +1 past the highest existing
// workspace creates the next one (dynamic workspaces); −1 stops at workspace
// 1. Mirrors the old Switch_WS_Rel semantics exactly.
ws_rel :: proc(dir: int) {
    m := g_wm.m
    cur := c.Current_WS(m)
    if cur == nil {
        ws_switch_to(1)
        return
    }
    ws_switch_to(cur.Id + dir)
}

// move_focused_to_ws moves the focused window to workspace id (created on
// demand) and announces what changed for IPC subscribers: "init" when the
// target workspace was just created, "empty" when the source workspace lost
// its last window. The current workspace does not change.
move_focused_to_ws :: proc(id: int) {
    m := g_wm.m
    src := c.Current_WS(m)
    if src == nil || src.Focus == nil { return }
    created := id >= 1 && c.Find_WS(m, id) == nil
    if c.Move_Focused_To_WS(m, id) {
        if created { ipc_broadcast_ws_event(c.IPC_CHANGE_INIT, c.Find_WS(m, id), nil) }
        if c.Ws_Is_Empty(src) { ipc_broadcast_ws_event(c.IPC_CHANGE_EMPTY, src, nil) }
        reflow()
    }
}

// ---------------------------------------------------------------------------
// process spawn + close
// ---------------------------------------------------------------------------

// close_client politely asks any managed client to exit: WM_DELETE_WINDOW when
// advertised, an X kill otherwise (ICCCM §4.2.4). Used by the close binding
// and by EWMH _NET_CLOSE_WINDOW requests for arbitrary clients.
close_client :: proc(cl: ^c.Client) {
    if cl == nil { return }
    if client_has_protocol(cl.Xid, atom("WM_DELETE_WINDOW")) {
        send_client_message(cl.Xid, atom("WM_PROTOCOLS"), atom("WM_DELETE_WINDOW"), CURRENT_TIME)
    } else {
        xcb_kill_client(g_wm.conn, cl.Xid)
        xcb_flush(g_wm.conn)
    }
}

close_focused :: proc() {
    close_client(g_wm.m.Focused)
}

// client_has_protocol checks WM_PROTOCOLS for a specific ICCCM protocol atom
// (WM_DELETE_WINDOW, WM_TAKE_FOCUS, …).
client_has_protocol :: proc(xid: u32, target: u32) -> bool {
    if target == 0 { return false }
    data, ok := get_prop(g_wm.conn, xid, atom("WM_PROTOCOLS"), atom("ATOM"))
    if !ok { return false }
    defer delete(data)
    if len(data) % 4 != 0 { return false }
    vals := ([^]u32)(raw_data(data))[:len(data) / 4]
    for v in vals {
        if v == target { return true }
    }
    return false
}

// send_client_message writes a 32-bit ClientMessage to the window.
//
// For ICCCM/EWMH client-message delivery the event mask is zero: the server
// delivers the message to the client that owns the destination window (it does
// not need a matching event selection). Using Substructure* here would only
// reach clients that select those masks on their own window — i.e. nobody.
send_client_message :: proc(win, msg_type, data0, time: u32) {
    ev := Client_Message_Event {
        response_type = u8(EVENT_CLIENT_MESSAGE),
        format        = 32,
        window        = win,
        type_         = msg_type,
        data          = {data32 = [5]u32{data0, time, 0, 0, 0}},
    }
    xcb_send_event(g_wm.conn, 0, win, 0, rawptr(&ev))
}

// ---------------------------------------------------------------------------
// pointer/enter (focus-follows-mouse)
// ---------------------------------------------------------------------------

on_enter :: proc(ev: ^Enter_Notify_Event) {
    if !g_wm.m.Cfg.FocusFollowsMouse { return }
    if ev.mode != NOTIFY_MODE_NORMAL { return } // ignore grabs / synthetic
    xid := ev.event
    if cl := g_wm.m.ByXid[xid]; cl != nil {
        // Docks have Ws == nil, so on_current_ws below is false for them and
        // focus-follows-mouse can never land on a panel.
        if !on_current_ws(cl) { return }
        if cl == g_wm.m.Focused { return }
        old := g_wm.m.Focused
        c.Focus_Client(g_wm.m, cl)
        render_focus()
        xcb_flush(g_wm.conn)
        ipc_broadcast_focus_change(old, cl)
    }
}

grab_client_buttons :: proc(xid: u32) {
    mask := u16(EVENT_MASK_BUTTON_PRESS | EVENT_MASK_BUTTON_RELEASE | EVENT_MASK_POINTER_MOTION)
    xcb_ungrab_button(g_wm.conn, 0, xid, MOD_MASK_ANY)
    xcb_grab_button(g_wm.conn, 0, xid, mask, GRAB_MODE_SYNC, GRAB_MODE_ASYNC, 0, 0, 1, MOD_MASK_ANY)
    xcb_grab_button(g_wm.conn, 0, xid, mask, GRAB_MODE_SYNC, GRAB_MODE_ASYNC, 0, 0, 3, MOD_MASK_ANY)
}

regrab_client_buttons :: proc() {
    // Wheel buttons are grabbed on the root so Mod+wheel works over empty
    // space and client windows alike. Lock/NumLock variants mirror key grabs.
    xcb_ungrab_button(g_wm.conn, 4, g_wm.root, MOD_MASK_ANY)
    xcb_ungrab_button(g_wm.conn, 5, g_wm.root, MOD_MASK_ANY)
    if g_wm.primary_mod != 0 {
        mask := u16(EVENT_MASK_BUTTON_PRESS)
        combos := [4]u16{0, g_wm.lock, g_wm.numlock, g_wm.lock | g_wm.numlock}
        for combo in combos {
            mods := g_wm.primary_mod | combo
            xcb_grab_button(g_wm.conn, 0, g_wm.root, mask, GRAB_MODE_ASYNC, GRAB_MODE_ASYNC, 0, 0, 4, mods)
            xcb_grab_button(g_wm.conn, 0, g_wm.root, mask, GRAB_MODE_ASYNC, GRAB_MODE_ASYNC, 0, 0, 5, mods)
        }
    }
    for cl in g_wm.m.Clients { if !cl.Dock { grab_client_buttons(cl.Xid) } }
}

on_button_press :: proc(ev: ^Button_Press_Event) {
    if ev.event == g_wm.help_window {
        help_hide()
        return
    }
    if tab := tab_client(ev.event); tab != nil {
        old := g_wm.m.Focused
        c.Focus_Client(g_wm.m, tab)
        raise_focused()
        reflow()
        ipc_broadcast_focus_change(old, tab)
        return
    }

    clean := ev.state & ~(g_wm.lock | g_wm.numlock)
    if g_wm.primary_mod != 0 && clean == g_wm.primary_mod && (ev.detail == 4 || ev.detail == 5) {
        dir := -1
        if ev.detail == 5 { dir = 1 }
        if c.Scroll_Viewport(g_wm.m, dir) { reflow_preserve_viewport() }
        return
    }

    cl := g_wm.m.ByXid[ev.event]
    if cl == nil || cl.Dock {
        xcb_allow_events(g_wm.conn, ALLOW_REPLAY_POINTER, ev.time)
        return
    }
    old := g_wm.m.Focused
    if on_current_ws(cl) && old != cl {
        c.Focus_Client(g_wm.m, cl)
        render_focus()
        ipc_broadcast_focus_change(old, cl)
    }
    drag := g_wm.primary_mod != 0 && clean & g_wm.primary_mod == g_wm.primary_mod && cl.Floating
    if drag && (ev.detail == 1 || ev.detail == 3) {
        g_wm.mouse_client = cl
        g_wm.mouse_resize = ev.detail == 3
        g_wm.mouse_root_x = ev.root_x
        g_wm.mouse_root_y = ev.root_y
        g_wm.mouse_start = cl.FloatingRect
        xcb_allow_events(g_wm.conn, ALLOW_ASYNC_POINTER, ev.time)
    } else {
        xcb_allow_events(g_wm.conn, ALLOW_REPLAY_POINTER, ev.time)
    }
    xcb_flush(g_wm.conn)
}

on_motion :: proc(ev: ^Motion_Notify_Event) {
    cl := g_wm.mouse_client
    if cl == nil { return }
    dx := i32(ev.root_x - g_wm.mouse_root_x)
    dy := i32(ev.root_y - g_wm.mouse_root_y)
    r := g_wm.mouse_start
    if g_wm.mouse_resize {
        r.W = max(i32(80), r.W + dx)
        r.H = max(i32(60), r.H + dy)
    } else {
        r.X += dx
        r.Y += dy
    }
    cl.FloatingRect = r
    reflow()
}

on_button_release :: proc(ev: ^Button_Press_Event) {
    g_wm.mouse_client = nil
    g_wm.mouse_resize = false
}

NOTIFY_MODE_NORMAL :: u8(0)

on_current_ws :: proc(cl: ^c.Client) -> bool {
    return cl.Out != nil && cl.Ws == cl.Out.Current
}

// ---------------------------------------------------------------------------
// configure handling
// ---------------------------------------------------------------------------

// on_configure_request is called for managed windows trying to resize/move
// themselves (tiled: rejected by re-applying layout) and for unmanaged windows
// (passed through verbatim).
on_configure_request :: proc(ev: ^Configure_Request_Event) {
    xid := ev.window
    if cl := g_wm.m.ByXid[xid]; cl != nil {
        if cl.Floating || cl.Dock {
            // honour floating/dock move/resize requests (a dock keeps the
            // geometry it asks for; tiled windows do not choose theirs)
            apply_float_configure(cl, ev)
            reflow()
        } else {
            // tiled windows do not choose their geometry; re-asserting the
            // layout delivers a ConfigureNotify back to the client.
            reflow()
        }
        return
    }
    // unmanaged (e.g. override-redirect) window: satisfy the request directly
    vals := [7]u32 {
        u32(i16(ev.x)), u32(i16(ev.y)),
        u32(ev.width), u32(ev.height), u32(ev.border_width),
        0, 0,
    }
    xcb_configure_window(g_wm.conn, xid, u32(ev.value_mask), &vals[0])
    xcb_flush(g_wm.conn)
}

apply_float_configure :: proc(cl: ^c.Client, ev: ^Configure_Request_Event) {
    // A zero-size configure is a request to collapse. Panel shells emit a
    // zero-size step while re-asserting geometry after a WM fight (Quickshell
    // does this against WMs that tile panels); honouring it would hide the
    // window, so drop those requests — a visible bar never legitimately
    // configures itself to 0x0.
    if ev.width == 0 || ev.height == 0 { return }
    r := cl.FloatingRect
    mask := u32(ev.value_mask)
    if mask & CW_X != 0 { r.X = i32(ev.x) }
    if mask & CW_Y != 0 { r.Y = i32(ev.y) }
    if mask & CW_WIDTH != 0 { r.W = i32(ev.width) }
    if mask & CW_HEIGHT != 0 { r.H = i32(ev.height) }
    cl.FloatingRect = r
}

// on_property_notify reacts to title changes (refresh metadata + IPC event)
// and dock strut changes (reflow the work area live).
on_property_notify :: proc(ev: ^Property_Notify_Event) {
    cl := g_wm.m.ByXid[ev.window]
    if cl == nil { return }
    if ev.atom == atom("_NET_WM_NAME") || ev.atom == atom("WM_NAME") {
        old := cl.Title
        fresh := read_client_title(cl.Xid)
        if fresh != old {
            cl.Title = fresh
            ipc_broadcast_window_event(c.IPC_WINDOW_TITLE, cl)
            if old != "" { delete(old) }
            render_tabs()
            xcb_flush(g_wm.conn)
        } else if fresh != "" {
            delete(fresh)
        }
        return
    }
    if ev.atom == atom("WM_HINTS") {
        if read_client_urgency(cl) { ipc_broadcast_window_event(c.IPC_WINDOW_URGENT, cl) }
        return
    }
    if cl.Dock && (ev.atom == atom("_NET_WM_STRUT_PARTIAL") || ev.atom == atom("_NET_WM_STRUT")) {
        read_struts(cl)
        c.Update_Reserved(g_wm.m)
        reflow() // ewmh_pulse inside reflow republishes _NET_WORKAREA
    }
}

// on_configure_notify tracks root (screen) resizes.
//
// NB: because the root carries a SUBSTRUCTURE_NOTIFY selection, the server also
// reports every *child* reconfigure to us with event == root. Only a real screen
// resize has window == root too, so both fields must match — otherwise every
// geometry push we send a client would be mistaken for a screen resize and feed
// back into the layout.
on_configure_notify :: proc(ev: ^Configure_Notify_Event) {
    if ev.event != g_wm.root || ev.window != g_wm.root { return }
    g_wm.scr_w = i32(ev.width)
    g_wm.scr_h = i32(ev.height)
    if g_randr.available {
        randr_scan(true)
    } else if o := c.Active_Output(g_wm.m); o != nil {
        o.Geom = c.Rect{X = 0, Y = 0, W = g_wm.scr_w, H = g_wm.scr_h}
        reflow()
    }
}
