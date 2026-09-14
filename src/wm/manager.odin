package wm

import process "../process"
import ui "../ui"
import rendering "../rendering"
import logger "../log"
import input "../input"
import c "../core"
import x11 "../x11"

// The WM core glue: connects the pure model (core package) to the X server
// through the xcb layer. Responsibilities here are X-facing only — policy and
// geometry live in src/core. Each keyboard/mouse/ICCCM outcome ends by calling
// reflow() (arrange + push + focus), never by hand-editing rectangles.

import "core:time"

Tiled_Resize_State :: struct {
    Active: bool,
    Left, Right: ^c.Column,
    Upper, Lower: ^c.Client,
    Left_Start, Right_Start: i32,
    Default_Column_Width: i32,
    Upper_Start, Lower_Start: i32,
    Left_Min, Right_Min, Left_Max, Right_Max: i32,
    Upper_Min, Lower_Min, Upper_Max, Lower_Max: i32,
}

// Border colours come from Config.FocusedBorder / Config.UnfocusedBorder
// (0xRRGGBB), settable from the rc file (norm_outer_border / sel_outer_border).

Wm :: struct {
    conn:     ^x11.Connection,
    root:     u32,
    scr_w:    i32,
    scr_h:    i32,
    m:        ^c.Manager,
    atoms:    map[string]u32,
    ewmh:     Ewmh_State, // EWMH/ICCCM bookkeeping (see ewmh.odin)
    kb:       input.Kbd_Map,
    mm:       input.Mod_Map,
    numlock:  u16,
    lock:     u16, // always x11.MOD_MASK_LOCK; kept as field for symmetry
    primary_mod: u16,
    bindings: [dynamic]input.Binding,
    rules:        [dynamic]Raw_Rule, // applied to newly-managed windows
    ran_startups: [dynamic]string,   // startup commands already launched
    terminal: string,
    running:  bool,
    mouse_client: ^c.Client,
    mouse_resize: bool,
    mouse_tiled_drag: bool,
    tiled_resize: Tiled_Resize_State,
    mouse_root_x, mouse_root_y: i16,
    mouse_start: c.Rect,
    ui: ui.State,
    white_pixel: u32,
    tab_spawn_target: u32,
    tab_spawn_started: time.Tick,
    overview_active: bool,
    preview_hover_locked: bool,
    preview_hover_target: u32,
    rendering: rendering.State,
}

g_wm: Wm

// ---------------------------------------------------------------------------
// atoms used by the WM core
// ---------------------------------------------------------------------------

atom :: proc(name: string) -> u32 {
    return x11.intern_atom(g_wm.conn, &g_wm.atoms, name)
}

// ---------------------------------------------------------------------------
// geometry push / focus render
// ---------------------------------------------------------------------------

// reflow_inner recomputes and renders the layout. Most actions keep the
// focused column visible; explicit wheel scrolling disables that snap so the
// viewport can move independently of focus.
reflow_inner :: proc(ensure_focus_visible, animate: bool) {
    if g_wm.tiled_resize.Active &&
       (g_wm.mouse_client == nil || !on_current_ws(g_wm.mouse_client)) {
        cancel_pointer_operation()
    }
    if ensure_focus_visible { c.Ensure_Active_Focus_Visible(g_wm.m) }
    c.Arrange_All(g_wm.m)
    push_geoms(animate)
    ui.Render_Tabs(&g_wm.ui, g_wm.m)
    render_focus()
    ewmh_pulse() // reconcile desktop/fullscreen client properties (deduped)
    x11.xcb_flush(g_wm.conn)
}

reflow :: proc() { reflow_inner(true, true) }
reflow_preserve_viewport :: proc() { reflow_inner(false, true) }
reflow_immediate :: proc() { reflow_inner(true, false) }

// push_geoms configures every managed window's position/size/border-width from
// the model (client rects already account for the border ring). Also maps any
// client that has not been mapped yet.
push_geoms :: proc(animate: bool) {
    rendering.Commit(&g_wm.rendering, g_wm.conn, g_wm.m, animate, ewmh_mark_mapped)
}

// render_focus sets each window's border colour and applies X input focus to the
// focused client (or PointerRoot when there is no managed focus). A focused
// floating window is always raised above the other clients; keeping that rule
// here covers pointer focus, click focus, newly-floated windows and IPC focus.
render_focus :: proc() {
    m := g_wm.m
    focused := m.Focused
    for cl in m.Clients {
        col := m.Cfg.UnfocusedBorder
        if cl == focused { col = m.Cfg.FocusedBorder }
        x11.xcb_change_window_attributes(g_wm.conn, cl.Xid, x11.CW_BORDER_PIXEL, &col)
    }
    if focused != nil && focused.Floating { raise_focused() }
    apply_x_focus()
}

apply_x_focus :: proc() {
    focused := g_wm.m.Focused
    if focused != nil && focused.Mapped {
        x11.xcb_set_input_focus(g_wm.conn, x11.INPUT_FOCUS_POINTER_ROOT, focused.Xid, x11.CURRENT_TIME)
        ewmh_announce_take_focus(focused) // courtesy for Xt/Java-style clients
    } else {
        // With no managed client, focus the pointer root (dest == PointerRoot).
        // Focus None would discard every key event, which also disables our
        // passive grabs on the root — on an empty desktop Super+Return and the
        // other bindings would silently die.
        x11.xcb_set_input_focus(g_wm.conn, x11.INPUT_FOCUS_POINTER_ROOT, u32(x11.INPUT_FOCUS_POINTER_ROOT), x11.CURRENT_TIME)
    }
    ewmh_push_active(focused)
}

raise_focused :: proc() {
    if f := g_wm.m.Focused; f != nil {
        stack := x11.STACK_MODE_ABOVE
        x11.xcb_configure_window(g_wm.conn, f.Xid, x11.CW_STACK_MODE, &stack)
    }
    raise_docks()
}

// raise_docks restores the normal panel layer, then puts an active fullscreen
// client above it. This is called anywhere a newly mapped or focused window can
// disturb stacking, so docks remain above ordinary windows without covering a
// real fullscreen client.
raise_docks :: proc() {
    for o in g_wm.m.Outputs {
        for d in o.Docks {
            stack := x11.STACK_MODE_ABOVE
            x11.xcb_configure_window(g_wm.conn, d.Xid, x11.CW_STACK_MODE, &stack)
        }
    }
    if f := g_wm.m.Focused; f != nil && f.Fullscreen {
        stack := x11.STACK_MODE_ABOVE
        x11.xcb_configure_window(g_wm.conn, f.Xid, x11.CW_STACK_MODE, &stack)
    }
}

// ---------------------------------------------------------------------------
// window metadata
// ---------------------------------------------------------------------------

// manage reads window metadata and adds the window to the model, maps it and
// focuses it. `float_override` forces floating (used for dialog-style windows).
manage :: proc(xid: u32, float_override: bool, requested_output: ^c.Output = nil) {
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
    read_size_hints(cl)

    // select events on the client so we see title changes, strut updates and
    // pointer hovers. (Child unmap/destroy/configure is already reported by the
    // root SUBSTRUCTURE_NOTIFY grab, so STRUCTURE_NOTIFY here is unnecessary.)
    evmask := x11.EVENT_MASK_PROPERTY_CHANGE | x11.EVENT_MASK_ENTER_WINDOW | x11.EVENT_MASK_POINTER_MOTION
    x11.xcb_change_window_attributes(g_wm.conn, xid, x11.CW_EVENT_MASK, &evmask)
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
        raise_docks() // keep the dock below an active fullscreen client
        ipc_broadcast_window_event(c.IPC_WINDOW_NEW, cl)
        return
    }

    // A MapRequest has no coordinates of its own. Its caller queries the root
    // pointer and supplies the output so normal clients open where the pointer
    // is. Docks retain their geometry-based placement path above.
    old_ws := c.Current_WS(m)
    if requested_output != nil && c.Focus_Output(m, requested_output) {
        ipc_broadcast_output_event("focus", requested_output.Name)
        ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, requested_output.Current, old_ws)
    }

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
    adopt_pre_wm_state(cl) // inherit fullscreen/maximize set before mapping
    ewmh_client_managed(cl) // _NET_CLIENT_LIST + _NET_WM_DESKTOP
    reflow()
    raise_docks() // restore normal dock order (or fullscreen above all)
    ipc_broadcast_window_event(c.IPC_WINDOW_NEW, cl)
    ipc_broadcast_focus_change(old_focus, m.Focused)
}

// read_window_type reports whether the client's _NET_WM_WINDOW_TYPE atom list
// names DOCK (a dock/panel window).
read_window_type :: proc(cl: ^c.Client) -> bool {
    data, ok := x11.get_prop(g_wm.conn, cl.Xid, atom("_NET_WM_WINDOW_TYPE"), atom("ATOM"))
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
    if data, ok := x11.get_prop(g_wm.conn, cl.Xid, atom("_NET_WM_STRUT_PARTIAL"), atom("CARDINAL")); ok {
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
    if data, ok := x11.get_prop(g_wm.conn, cl.Xid, atom("_NET_WM_STRUT"), atom("CARDINAL")); ok {
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
    cookie := x11.xcb_get_geometry(g_wm.conn, cl.Xid)
    e: ^x11.Error
    reply := x11.xcb_get_geometry_reply(g_wm.conn, cookie, &e)
    if e != nil {
        x11.free_libc(e)
        reply = nil
    }
    if reply != nil {
        defer x11.free_libc(reply)
        cl.FloatingRect = c.Rect { X = i32(reply.x), Y = i32(reply.y), W = i32(reply.width), H = i32(reply.height) }
        return
    }
    cl.FloatingRect = c.Rect { X = 0, Y = 0, W = g_wm.scr_w, H = 24 }
}

// read_client_meta fills title/class/instance from the X properties.
read_client_meta :: proc(cl: ^c.Client) {
    cl.Title = read_client_title(cl.Xid)
    // WM_CLASS: two NUL-separated strings: instance then class
    data, ok := x11.get_prop(g_wm.conn, cl.Xid, atom("WM_CLASS"), 0)
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
    data, ok := x11.get_prop(g_wm.conn, cl.Xid, atom("WM_HINTS"), 0)
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

P_MIN_SIZE   :: u32(1 << 4)
P_MAX_SIZE   :: u32(1 << 5)
P_RESIZE_INC :: u32(1 << 6)
P_BASE_SIZE  :: u32(1 << 8)

read_size_hints :: proc(cl: ^c.Client) {
    cl.SizeHints = {}
    data, ok := x11.get_prop(g_wm.conn, cl.Xid, atom("WM_NORMAL_HINTS"), 0)
    if !ok { return }
    defer delete(data)
    if len(data) < 4 { return }
    vals := ([^]u32)(raw_data(data))[:len(data) / 4]
    flags := vals[0]
    if flags & P_MIN_SIZE != 0 && len(vals) >= 7 {
        cl.SizeHints.MinW, cl.SizeHints.MinH = i32(vals[5]), i32(vals[6])
    }
    if flags & P_MAX_SIZE != 0 && len(vals) >= 9 {
        cl.SizeHints.MaxW, cl.SizeHints.MaxH = i32(vals[7]), i32(vals[8])
    }
    if flags & P_RESIZE_INC != 0 && len(vals) >= 11 {
        cl.SizeHints.IncW, cl.SizeHints.IncH = i32(vals[9]), i32(vals[10])
    }
    if flags & P_BASE_SIZE != 0 && len(vals) >= 17 {
        cl.SizeHints.BaseW, cl.SizeHints.BaseH = i32(vals[15]), i32(vals[16])
    }
}

constrain_floating_rect :: proc(cl: ^c.Client, r: c.Rect) -> c.Rect {
    result := r
    b := max(i32(0), cl.Border)
    content_w := max(i32(1), r.W - 2 * b)
    content_h := max(i32(1), r.H - 2 * b)
    content_w, content_h = c.Constrain_Size(cl.SizeHints, content_w, content_h)
    result.W = content_w + 2 * b
    result.H = content_h + 2 * b
    return result
}

clone_bytes :: proc(s: string) -> string {
    if s == "" { return "" }
    b := make([]byte, len(s))
    copy(b, s)
    return string(b)
}

// get_text_prop fetches an owned string from a window property of a specific
// type (type_id 0 = any).
get_text_prop :: proc(conn: ^x11.Connection, win, prop, type_id: u32) -> (string, bool) {
    if prop == 0 { return "", false }
    data, ok := x11.get_prop(conn, win, prop, type_id)
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
    if g_wm.mouse_client == cl || g_wm.tiled_resize.Active { cancel_pointer_operation() }
    dock := cl.Dock
    ws := cl.Ws // captured for the empty-workspace announcement below
    was_focused := g_wm.m.Focused == cl
    ipc_broadcast_window_event(c.IPC_WINDOW_CLOSE, cl)
    c.Unmanage_Client(g_wm.m, cl) // docks: removed from Output.Docks, reservation released
    new_focus := g_wm.m.Focused
    ewmh_client_unmanaged(cl) // WM_STATE Withdrawn + _NET_CLIENT_LIST refresh
    rendering.Forget(&g_wm.rendering, cl.Xid)
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
        ui.Render_Tabs(&g_wm.ui, g_wm.m) // an inactive tab may have been the removed client
        x11.xcb_flush(g_wm.conn)
    }
}

// ---------------------------------------------------------------------------
// key handling
// ---------------------------------------------------------------------------

// grab_all_keys (re)installs the root grabs for every binding.
grab_all_keys :: proc() {
    x11.xcb_ungrab_key(g_wm.conn, 0, g_wm.root, x11.MOD_MASK_ANY) // keycode 0 == AnyKey
    // Resolve first so explicit combinations can take precedence over the
    // automatically derived Shift+spawn layer below.
    for i in 0 ..< len(g_wm.bindings) {
        b := &g_wm.bindings[i]
        kc, level := input.keysym_to_keycode(&g_wm.kb, b.keysym)
        if kc == 0 {
            logger.Warn("cannot bind keysym", b.keysym, "(not in keymap)")
            continue
        }
        mods := b.mods
        if level & 1 == 1 { mods |= x11.MOD_MASK_SHIFT }
        b.effective_mods = mods
        b.keycode = kc
    }
    combos := [4]u16{0, g_wm.lock, g_wm.numlock, g_wm.lock | g_wm.numlock}
    for i in 0 ..< len(g_wm.bindings) {
        b := &g_wm.bindings[i]
        if b.keycode == 0 { continue }
        for combo in combos {
            x11.xcb_grab_key(g_wm.conn, 0, g_wm.root, b.effective_mods | combo, b.keycode, x11.GRAB_MODE_ASYNC, x11.GRAB_MODE_ASYNC)
        }
    }
    for i in 0 ..< len(g_wm.bindings) {
        b := &g_wm.bindings[i]
        if b.action != .Spawn || b.keycode == 0 || b.effective_mods & x11.MOD_MASK_SHIFT != 0 { continue }
        derived := b.effective_mods | x11.MOD_MASK_SHIFT
        claimed := false
        for other in g_wm.bindings {
            if other.keycode == b.keycode && other.effective_mods == derived { claimed = true; break }
        }
        if claimed { continue }
        for combo in combos {
            x11.xcb_grab_key(g_wm.conn, 0, g_wm.root, derived | combo, b.keycode, x11.GRAB_MODE_ASYNC, x11.GRAB_MODE_ASYNC)
        }
    }
}

// key press dispatch: match by exact (mods,keycode) after stripping Lock/NumLock.
on_keypress :: proc(ev: ^x11.Key_Press_Event) {
    if g_wm.overview_active {
        overview_keypress(ev)
        return
    }
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
    if clean & x11.MOD_MASK_SHIFT != 0 {
        base_mods := clean & ~x11.MOD_MASK_SHIFT
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

keycode_is :: proc(keycode: u8, name: string) -> bool {
    wanted, _ := input.keysym_to_keycode(&g_wm.kb, input.keysym_from_name(name))
    return wanted != 0 && keycode == wanted
}

overview_emit :: proc(change: string) {
    ipc_broadcast_window_event(change, nil)
}

overview_begin :: proc(direction: int) {
    if !g_wm.overview_active {
        // Convert the passive Alt+Tab grab into an explicit keyboard grab.
        // Releasing the active passive grab first is required: attempting
        // XGrabKeyboard while it is active returns AlreadyGrabbed on Xorg.
        x11.xcb_ungrab_keyboard(g_wm.conn, x11.CURRENT_TIME)
        cookie := x11.xcb_grab_keyboard(g_wm.conn, 0, g_wm.root, x11.CURRENT_TIME,
                                    x11.GRAB_MODE_ASYNC, x11.GRAB_MODE_ASYNC)
        err: ^x11.Error
        reply := x11.xcb_grab_keyboard_reply(g_wm.conn, cookie, &err)
        if err != nil {
            x11.free_libc(err)
            return
        }
        if reply == nil { return }
        success := reply.status == 0
        x11.free_libc(reply)
        if !success { return }
        g_wm.overview_active = true
    }
    overview_emit(direction < 0 ? "overview-previous" : "overview-next")
}

overview_end :: proc(commit: bool) {
    if !g_wm.overview_active { return }
    overview_emit(commit ? "overview-commit" : "overview-cancel")
    g_wm.overview_active = false
    x11.xcb_ungrab_keyboard(g_wm.conn, x11.CURRENT_TIME)
    x11.xcb_flush(g_wm.conn)
}

overview_keypress :: proc(ev: ^x11.Key_Press_Event) {
    if keycode_is(ev.detail, "Tab") {
        if ev.state & x11.MOD_MASK_SHIFT != 0 {
            overview_emit("overview-previous")
        } else {
            overview_emit("overview-next")
        }
    } else if keycode_is(ev.detail, "Left") {
        overview_emit("overview-workspace-previous")
    } else if keycode_is(ev.detail, "Right") {
        overview_emit("overview-workspace-next")
    } else if keycode_is(ev.detail, "Up") {
        overview_emit("overview-window-previous")
    } else if keycode_is(ev.detail, "Down") {
        overview_emit("overview-window-next")
    } else if keycode_is(ev.detail, "Return") ||
              keycode_is(ev.detail, "KP_Enter") ||
              keycode_is(ev.detail, "space") {
        overview_end(true)
    } else if keycode_is(ev.detail, "Escape") {
        overview_end(false)
    }
}

on_keyrelease :: proc(ev: ^x11.Key_Press_Event) {
    if !g_wm.overview_active { return }
    if keycode_is(ev.detail, "Alt_L") || keycode_is(ev.detail, "Alt_R") {
        overview_end(true)
    }
}

dir_of :: proc(k: input.Action_Kind) -> c.Dir {
    #partial switch k {
    case .Focus_Left, .Move_Left:   return .Left
    case .Focus_Right, .Move_Right: return .Right
    case .Focus_Up, .Move_Up:       return .Up
    case .Focus_Down, .Move_Down:   return .Down
    }
    return .Left
}

dispatch_action :: proc(b: ^input.Binding) {
    m := g_wm.m
    old_focus := m.Focused
    // A keyboard action aborts an in-progress pointer operation. In
    // particular, workspace/layout changes must never leave a stale overlay.
    if g_wm.mouse_client != nil { cancel_pointer_operation() }
    // Explicit keyboard input takes precedence and suppresses a hover retarget
    // until pointer motion confirms it has left all preview zones.
    g_wm.preview_hover_locked = true
    g_wm.preview_hover_target = 0
    switch b.action {
    case .None:
        return
    case .Spawn:
        if b.cmd != "" { process.Spawn(b.cmd) }
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
    case .Layout_Floating:
        if m.Focused != nil && !m.Focused.Floating && c.Toggle_Floating(m) {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Layout_Tabbed:
        changed := false
        if m.Focused != nil && m.Focused.Floating {
            changed = c.Toggle_Floating(m)
        }
        changed = c.Set_Column_Layout(m, .Tabbed) || changed
        if changed {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Layout_Stacked:
        changed := false
        if m.Focused != nil && m.Focused.Floating {
            changed = c.Toggle_Floating(m)
        }
        changed = c.Set_Column_Layout(m, .Stacked) || changed
        if changed {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Layout_Toggle:
        if c.Toggle_Column_Layout(m) {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Overview_Next:
        overview_begin(1)
    case .Overview_Prev:
        overview_begin(-1)
    case .Scratchpad_Toggle, .Scratchpad_Toggle_Float:
        if c.Scratchpad_Toggle_Register(m, b.arg, b.action == .Scratchpad_Toggle_Float) {
            raise_focused()
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Scratchpad_Remove:
        if c.Scratchpad_Remove_Register(m, b.arg) {
            raise_focused()
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Show_Bindings:
        ui.Toggle_Help(&g_wm.ui, g_wm.m, g_wm.bindings[:], g_wm.scr_w, g_wm.scr_h)
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
        send_client_message(cl.Xid, atom("WM_PROTOCOLS"), atom("WM_DELETE_WINDOW"), x11.CURRENT_TIME)
    } else {
        x11.xcb_kill_client(g_wm.conn, cl.Xid)
        x11.xcb_flush(g_wm.conn)
    }
}

close_focused :: proc() {
    close_client(g_wm.m.Focused)
}

// client_has_protocol checks WM_PROTOCOLS for a specific ICCCM protocol atom
// (WM_DELETE_WINDOW, WM_TAKE_FOCUS, …).
client_has_protocol :: proc(xid: u32, target: u32) -> bool {
    if target == 0 { return false }
    data, ok := x11.get_prop(g_wm.conn, xid, atom("WM_PROTOCOLS"), atom("ATOM"))
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
    ev := x11.Client_Message_Event {
        response_type = u8(x11.EVENT_CLIENT_MESSAGE),
        format        = 32,
        window        = win,
        type_         = msg_type,
        data          = {data32 = [5]u32{data0, time, 0, 0, 0}},
    }
    x11.xcb_send_event(g_wm.conn, 0, win, 0, rawptr(&ev))
}

// ---------------------------------------------------------------------------
// pointer/enter (focus-follows-mouse)
// ---------------------------------------------------------------------------

// output_at_pointer resolves the current root pointer position to a RandR
// output. MapRequest carries no coordinates, so new-window placement needs
// this small synchronous query.
output_at_pointer :: proc() -> ^c.Output {
    cookie := x11.xcb_query_pointer(g_wm.conn, g_wm.root)
    e: ^x11.Error
    reply := x11.xcb_query_pointer_reply(g_wm.conn, cookie, &e)
    if e != nil {
        x11.free_libc(e)
        return c.Active_Output(g_wm.m)
    }
    if reply == nil { return c.Active_Output(g_wm.m) }
    defer x11.free_libc(reply)
    if reply.same_screen == 0 { return c.Active_Output(g_wm.m) }
    return c.Output_At_Point(g_wm.m, i32(reply.root_x), i32(reply.root_y))
}

on_enter :: proc(ev: ^x11.Enter_Notify_Event) {
    if ev.mode != NOTIFY_MODE_NORMAL { return } // ignore grabs / synthetic
    if scroll_preview_hover(i32(ev.root_x), i32(ev.root_y)) { return }
    if !g_wm.m.Cfg.FocusFollowsMouse { return }
    xid := ev.event
    if cl := g_wm.m.ByXid[xid]; cl != nil {
        // Docks have Ws == nil, so on_current_ws below is false for them and
        // focus-follows-mouse can never land on a panel.
        if !on_current_ws(cl) { return }
        if cl == g_wm.m.Focused { return }
        old := g_wm.m.Focused
        c.Focus_Client(g_wm.m, cl)
        render_focus()
        x11.xcb_flush(g_wm.conn)
        ipc_broadcast_focus_change(old, cl)
    }
}

// scroll_preview_hover is shared by EnterNotify and MotionNotify. Once a
// preview triggers it remains locked while the pointer is over any preview;
// this prevents the opposite edge created by the reveal from immediately
// navigating back underneath a stationary pointer.
scroll_preview_hover :: proc(x, y: i32) -> bool {
    preview, over := c.Scroll_Preview_At_Point(g_wm.m, x, y)
    if !over {
        g_wm.preview_hover_locked = false
        g_wm.preview_hover_target = 0
        return false
    }
    if g_wm.mouse_client != nil { return true }
    if g_wm.preview_hover_locked { return true }

    old := g_wm.m.Focused
    if !c.Reveal_Scroll_Client(g_wm.m, preview.Client) { return true }
    g_wm.preview_hover_locked = true
    g_wm.preview_hover_target = preview.Client.Xid
    reflow_preserve_viewport()
    ipc_broadcast_focus_change(old, preview.Client)
    return true
}

grab_client_buttons :: proc(xid: u32) {
    mask := u16(x11.EVENT_MASK_BUTTON_PRESS | x11.EVENT_MASK_BUTTON_RELEASE | x11.EVENT_MASK_POINTER_MOTION)
    x11.xcb_ungrab_button(g_wm.conn, 0, xid, x11.MOD_MASK_ANY)
    x11.xcb_grab_button(g_wm.conn, 0, xid, mask, x11.GRAB_MODE_SYNC, x11.GRAB_MODE_ASYNC, 0, 0, 1, x11.MOD_MASK_ANY)
    x11.xcb_grab_button(g_wm.conn, 0, xid, mask, x11.GRAB_MODE_SYNC, x11.GRAB_MODE_ASYNC, 0, 0, 2, x11.MOD_MASK_ANY)
    x11.xcb_grab_button(g_wm.conn, 0, xid, mask, x11.GRAB_MODE_SYNC, x11.GRAB_MODE_ASYNC, 0, 0, 3, x11.MOD_MASK_ANY)
}

toggle_client_maximized :: proc(cl: ^c.Client) -> bool {
    if cl == nil || cl.Dock || cl.Fullscreen || !on_current_ws(cl) { return false }
    old := g_wm.m.Focused
    if old != cl { c.Focus_Client(g_wm.m, cl) }
    if !c.Toggle_Maximized(cl) { return false }
    reflow()
    raise_focused()
    ipc_broadcast_focus_change(old, cl)
    ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
    return true
}

regrab_client_buttons :: proc() {
    // Wheel buttons are grabbed on the root so Mod+wheel works over empty
    // space and client windows alike. Lock/NumLock variants mirror key grabs.
    x11.xcb_ungrab_button(g_wm.conn, 4, g_wm.root, x11.MOD_MASK_ANY)
    x11.xcb_ungrab_button(g_wm.conn, 5, g_wm.root, x11.MOD_MASK_ANY)
    if g_wm.primary_mod != 0 {
        mask := u16(x11.EVENT_MASK_BUTTON_PRESS)
        combos := [4]u16{0, g_wm.lock, g_wm.numlock, g_wm.lock | g_wm.numlock}
        for combo in combos {
            mods := g_wm.primary_mod | combo
            x11.xcb_grab_button(g_wm.conn, 0, g_wm.root, mask, x11.GRAB_MODE_ASYNC, x11.GRAB_MODE_ASYNC, 0, 0, 4, mods)
            x11.xcb_grab_button(g_wm.conn, 0, g_wm.root, mask, x11.GRAB_MODE_ASYNC, x11.GRAB_MODE_ASYNC, 0, 0, 5, mods)
        }
    }
    for cl in g_wm.m.Clients { if !cl.Dock { grab_client_buttons(cl.Xid) } }
}

column_resize_limits :: proc(col: ^c.Column) -> (minimum, maximum: i32) {
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

row_resize_limits :: proc(cl: ^c.Client) -> (minimum, maximum: i32) {
    minimum = 40
    if cl == nil { return }
    b := 2 * max(i32(0), cl.Border)
    minimum = max(minimum, cl.SizeHints.MinH + b)
    if cl.SizeHints.MaxH > 0 { maximum = cl.SizeHints.MaxH + b }
    return
}

column_is_maximized :: proc(col: ^c.Column) -> bool {
    if col == nil { return false }
    for cl in col.Wins { if cl.Maximized { return true } }
    return false
}

begin_tiled_resize :: proc(cl: ^c.Client, root_x, root_y: i32) -> bool {
    if cl == nil || cl.Floating || cl.Fullscreen || cl.Maximized || !on_current_ws(cl) { return false }
    ci, col, row := c.Column_Of(cl)
    if col == nil { return false }

    // Finish any layout transition first so the drag snapshot matches the
    // geometry beneath the pointer exactly.
    reflow_immediate()
    state := Tiled_Resize_State{}

    if len(cl.Ws.Cols) > 1 {
        left_index, right_index := -1, -1
        midpoint := cl.Geom.X + cl.Geom.W / 2
        if root_x < midpoint && ci > 0 {
            left_index, right_index = ci - 1, ci
        } else if root_x >= midpoint && ci + 1 < len(cl.Ws.Cols) {
            left_index, right_index = ci, ci + 1
        }
        if left_index >= 0 {
            left, right := cl.Ws.Cols[left_index], cl.Ws.Cols[right_index]
            if !column_is_maximized(left) && !column_is_maximized(right) {
                state.Left, state.Right = left, right
                state.Left_Start = c.Column_Width_At(g_wm.m, cl.Out, cl.Ws, left_index)
                state.Right_Start = c.Column_Width_At(g_wm.m, cl.Out, cl.Ws, right_index)
                state.Default_Column_Width = c.Default_Column_Width(g_wm.m, cl.Out, cl.Ws)
                state.Left_Min, state.Left_Max = column_resize_limits(left)
                state.Right_Min, state.Right_Max = column_resize_limits(right)
            }
        }
    }

    if col.Layout == .Stacked && len(col.Wins) > 1 {
        upper_index, lower_index := -1, -1
        midpoint := cl.Geom.Y + cl.Geom.H / 2
        if root_y < midpoint && row > 0 {
            upper_index, lower_index = row - 1, row
        } else if root_y >= midpoint && row + 1 < len(col.Wins) {
            upper_index, lower_index = row, row + 1
        }
        if upper_index >= 0 {
            // Preserve every row's current share; only the selected boundary
            // changes while the rest of the stack remains stable.
            for win in col.Wins {
                win.TileWeight = f64(win.Geom.H + 2 * max(i32(0), win.Border))
            }
            state.Upper, state.Lower = col.Wins[upper_index], col.Wins[lower_index]
            state.Upper_Start = i32(state.Upper.TileWeight)
            state.Lower_Start = i32(state.Lower.TileWeight)
            state.Upper_Min, state.Upper_Max = row_resize_limits(state.Upper)
            state.Lower_Min, state.Lower_Max = row_resize_limits(state.Lower)
        }
    }

    state.Active = state.Left != nil || state.Upper != nil
    if !state.Active { return false }
    g_wm.tiled_resize = state
    g_wm.mouse_client = cl
    g_wm.mouse_root_x = i16(root_x)
    g_wm.mouse_root_y = i16(root_y)
    return true
}

tiled_resize_motion :: proc(root_x, root_y: i32) {
    state := &g_wm.tiled_resize
    if !state.Active { return }
    if state.Left != nil && state.Right != nil {
        left, right := c.Resize_Pair(
            state.Left_Start, state.Right_Start,
            root_x - i32(g_wm.mouse_root_x),
            state.Left_Min, state.Right_Min, state.Left_Max, state.Right_Max,
        )
        // Returning a boundary to the layout's natural split clears the
        // override. Such a column can expand normally if it later stands
        // alone, while a genuinely resized column keeps its explicit width.
        state.Left.Width = left if left != state.Default_Column_Width else 0
        state.Right.Width = right if right != state.Default_Column_Width else 0
    }
    if state.Upper != nil && state.Lower != nil {
        upper, lower := c.Resize_Pair(
            state.Upper_Start, state.Lower_Start,
            root_y - i32(g_wm.mouse_root_y),
            state.Upper_Min, state.Lower_Min, state.Upper_Max, state.Lower_Max,
        )
        state.Upper.TileWeight, state.Lower.TileWeight = f64(upper), f64(lower)
    }
    reflow_immediate()
}

on_button_press :: proc(ev: ^x11.Button_Press_Event) {
    if ev.event == g_wm.ui.HelpWindow {
        ui.Hide_Help(&g_wm.ui)
        return
    }
    if tab := ui.Tab_Client(&g_wm.ui, ev.event); tab != nil {
        if ev.detail == 2 {
            toggle_client_maximized(tab)
            return
        }
        old := g_wm.m.Focused
        c.Focus_Client(g_wm.m, tab)
        raise_focused()
        reflow()
        ipc_broadcast_focus_change(old, tab)
        return
    }

    clean := ev.state & ~(g_wm.lock | g_wm.numlock)
    if g_wm.primary_mod != 0 && clean == g_wm.primary_mod && (ev.detail == 4 || ev.detail == 5) {
        // Do not let geometry moving beneath this explicit wheel action turn
        // the same stationary pointer into a second, implicit scroll.
        g_wm.preview_hover_locked = true
        g_wm.preview_hover_target = 0
        dir := -1
        if ev.detail == 5 { dir = 1 }
        output := c.Output_At_Point(g_wm.m, i32(ev.root_x), i32(ev.root_y))
        if c.Scroll_Output_Viewport(g_wm.m, output, dir) { reflow_preserve_viewport() }
        return
    }

    cl := g_wm.m.ByXid[ev.event]
    if cl == nil || cl.Dock {
        x11.xcb_allow_events(g_wm.conn, x11.ALLOW_REPLAY_POINTER, ev.time)
        return
    }
    if ev.detail == 2 {
        if toggle_client_maximized(cl) {
            x11.xcb_allow_events(g_wm.conn, x11.ALLOW_ASYNC_POINTER, ev.time)
        } else {
            x11.xcb_allow_events(g_wm.conn, x11.ALLOW_REPLAY_POINTER, ev.time)
        }
        x11.xcb_flush(g_wm.conn)
        return
    }
    old := g_wm.m.Focused
    if on_current_ws(cl) && old != cl {
        c.Focus_Client(g_wm.m, cl)
        render_focus()
        ipc_broadcast_focus_change(old, cl)
    }
    modified := g_wm.primary_mod != 0 && clean & g_wm.primary_mod == g_wm.primary_mod
    floating_drag := modified && cl.Floating && !cl.Maximized && (ev.detail == 1 || ev.detail == 3)
    tiled_drag := modified && !cl.Floating && ev.detail == 1
    tiled_resize := modified && !cl.Floating && !cl.Maximized && ev.detail == 3
    if tiled_resize {
        if begin_tiled_resize(cl, i32(ev.root_x), i32(ev.root_y)) {
            x11.xcb_allow_events(g_wm.conn, x11.ALLOW_ASYNC_POINTER, ev.time)
        } else {
            x11.xcb_allow_events(g_wm.conn, x11.ALLOW_REPLAY_POINTER, ev.time)
        }
        x11.xcb_flush(g_wm.conn)
        return
    }
    if floating_drag || tiled_drag {
        g_wm.mouse_client = cl
        g_wm.mouse_resize = floating_drag && ev.detail == 3
        g_wm.mouse_tiled_drag = tiled_drag
        g_wm.mouse_root_x = ev.root_x
        g_wm.mouse_root_y = ev.root_y
        g_wm.mouse_start = cl.FloatingRect
        if tiled_drag { ui.Update_Drop(&g_wm.ui, g_wm.m, g_wm.mouse_client, i32(ev.root_x), i32(ev.root_y)) }
        x11.xcb_allow_events(g_wm.conn, x11.ALLOW_ASYNC_POINTER, ev.time)
    } else {
        x11.xcb_allow_events(g_wm.conn, x11.ALLOW_REPLAY_POINTER, ev.time)
    }
    x11.xcb_flush(g_wm.conn)
}

on_motion :: proc(ev: ^x11.Motion_Notify_Event) {
    cl := g_wm.mouse_client
    if cl == nil {
        scroll_preview_hover(i32(ev.root_x), i32(ev.root_y))
        return
    }
    if g_wm.mouse_tiled_drag {
        ui.Update_Drop(&g_wm.ui, g_wm.m, g_wm.mouse_client, i32(ev.root_x), i32(ev.root_y))
        return
    }
    if g_wm.tiled_resize.Active {
        tiled_resize_motion(i32(ev.root_x), i32(ev.root_y))
        return
    }
    if !g_wm.mouse_resize {
        old_ws := cl.Ws
        output := c.Output_At_Point(g_wm.m, i32(ev.root_x), i32(ev.root_y))
        if c.Move_Floating_To_Output(g_wm.m, cl, output) {
            ipc_broadcast_output_event("focus", output.Name)
            ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, output.Current, old_ws)
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
        }
    }
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
    if g_wm.mouse_resize { r = constrain_floating_rect(cl, r) }
    cl.FloatingRect = r
    reflow_immediate()
}

on_button_release :: proc(ev: ^x11.Button_Press_Event) {
    cl := g_wm.mouse_client
    if cl != nil && g_wm.mouse_tiled_drag {
        old_output := cl.Out
        old_ws := cl.Ws
        target := c.Drop_Target_At_Point(
            g_wm.m, i32(ev.root_x), i32(ev.root_y), cl, g_wm.ui.DropTarget,
        )
        ui.Hide_Drop(&g_wm.ui)
        if c.Move_Client_To_Drop(g_wm.m, cl, target) {
            if target.Out != old_output {
                ipc_broadcast_output_event("focus", target.Out.Name)
                ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, target.Ws, old_ws)
            }
            reflow()
            raise_focused()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
        }
    } else if g_wm.mouse_tiled_drag {
        ui.Hide_Drop(&g_wm.ui)
    } else if cl != nil && g_wm.tiled_resize.Active {
        if g_wm.tiled_resize.Upper != nil {
            c.Normalize_Stack_For_Client(g_wm.tiled_resize.Upper)
        }
        ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
    }
    cancel_pointer_operation()
}

cancel_pointer_operation :: proc() {
    if g_wm.mouse_client != nil { x11.xcb_ungrab_pointer(g_wm.conn, x11.CURRENT_TIME) }
    if g_wm.mouse_tiled_drag { ui.Hide_Drop(&g_wm.ui) }
    g_wm.mouse_client = nil
    g_wm.mouse_resize = false
    g_wm.mouse_tiled_drag = false
    g_wm.tiled_resize = {}
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
on_configure_request :: proc(ev: ^x11.Configure_Request_Event) {
    xid := ev.window
    if cl := g_wm.m.ByXid[xid]; cl != nil {
        if g_wm.tiled_resize.Active && g_wm.mouse_client == cl {
            reflow_immediate()
            return
        }
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
    x11.xcb_configure_window(g_wm.conn, xid, u32(ev.value_mask), &vals[0])
    x11.xcb_flush(g_wm.conn)
}

apply_float_configure :: proc(cl: ^c.Client, ev: ^x11.Configure_Request_Event) {
    // A zero-size configure is a request to collapse. Panel shells emit a
    // zero-size step while re-asserting geometry after a WM fight (Quickshell
    // does this against WMs that tile panels); honouring it would hide the
    // window, so drop those requests — a visible bar never legitimately
    // configures itself to 0x0.
    if ev.width == 0 || ev.height == 0 { return }
    r := cl.FloatingRect
    mask := u32(ev.value_mask)
    if mask & x11.CW_X != 0 { r.X = i32(ev.x) }
    if mask & x11.CW_Y != 0 { r.Y = i32(ev.y) }
    if mask & x11.CW_WIDTH != 0 { r.W = i32(ev.width) }
    if mask & x11.CW_HEIGHT != 0 { r.H = i32(ev.height) }
    if !cl.Dock { r = constrain_floating_rect(cl, r) }
    cl.FloatingRect = r
}

// on_property_notify reacts to title changes (refresh metadata + IPC event)
// and dock strut changes (reflow the work area live).
on_property_notify :: proc(ev: ^x11.Property_Notify_Event) {
    cl := g_wm.m.ByXid[ev.window]
    if cl == nil { return }
    if ev.atom == atom("_NET_WM_NAME") || ev.atom == atom("WM_NAME") {
        old := cl.Title
        fresh := read_client_title(cl.Xid)
        if fresh != old {
            cl.Title = fresh
            ipc_broadcast_window_event(c.IPC_WINDOW_TITLE, cl)
            if old != "" { delete(old) }
            ui.Render_Tabs(&g_wm.ui, g_wm.m)
            x11.xcb_flush(g_wm.conn)
        } else if fresh != "" {
            delete(fresh)
        }
        return
    }
    if ev.atom == atom("WM_HINTS") {
        if read_client_urgency(cl) { ipc_broadcast_window_event(c.IPC_WINDOW_URGENT, cl) }
        return
    }
    if ev.atom == atom("WM_NORMAL_HINTS") {
        read_size_hints(cl)
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
on_configure_notify :: proc(ev: ^x11.Configure_Notify_Event) {
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
