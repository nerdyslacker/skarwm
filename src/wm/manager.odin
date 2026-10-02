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
import "core:strings"
import "core:fmt"

Tiled_Resize_State :: struct {
    Active: bool,
    Resize_Width, Resize_Height: bool,
    From_Left, From_Top: bool,
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
    mouse_resize_hit: c.Decoration_Hit,
    mouse_tiled_drag: bool,
    mouse_tabbed_drag: bool,
    mouse_column_drag: bool,
    mouse_decoration_drag: bool,
    mouse_decoration_drag_started: bool,
    mouse_decoration_tile_drag: bool,
    mouse_decoration_event_x: i16,
    tiled_resize: Tiled_Resize_State,
    mouse_root_x, mouse_root_y: i16,
    mouse_start: c.Rect,
    mouse_preview: c.Rect,
    ui: ui.State,
    white_pixel: u32,
    tab_spawn_target: u32,
    tab_spawn_started: time.Tick,
    overview_active: bool,
    reminder_dialog_active: bool,
    reminders: [dynamic]Reminder,
    preview_hover_locked: bool,
    preview_hover_target: u32,
    preview_hover_pending: u32,
    preview_hover_due: time.Tick,
    rendering: rendering.State,
    bar_managed_started: bool,
    bar_blocks: [dynamic]Raw_Bar_Block,
    virtual_screens: [dynamic]Virtual_Screen_Profile,
    workspace_layouts: [dynamic]Workspace_Layout_Rule,
}

g_wm: Wm

TILED_DRAG_PREVIEW_SIZE :: i32(300)
DECORATION_DRAG_THRESHOLD :: i32(6)

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
        if cl.AlwaysOnTop { col = m.Cfg.Decoration.Accent }
        x11.xcb_change_window_attributes(g_wm.conn, cl.Xid, x11.CW_BORDER_PIXEL, &col)
    }
    ui.Draw_All_Decorations(&g_wm.ui, m)
    if focused != nil && focused.Floating {
        raise_focused()
    } else {
        // Reassert the above/dock layers after every redraw. Decoration frames
        // may have been newly mapped even when the focused client is tiled.
        raise_docks()
    }
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
        if f.DecorationFrame != 0 && !f.Fullscreen {
            x11.xcb_configure_window(g_wm.conn, f.DecorationFrame, x11.CW_STACK_MODE, &stack)
        }
        x11.xcb_configure_window(g_wm.conn, f.Xid, x11.CW_STACK_MODE, &stack)
    }
    raise_docks()
}

raise_always_on_top :: proc() {
    focused := g_wm.m.Focused
    // Preserve focus order inside this layer by raising its focused member
    // after the other always-on-top clients.
    for cl in g_wm.m.Clients {
        if cl == focused || !cl.AlwaysOnTop || !cl.Floating || !cl.Mapped ||
           cl.Stashed || cl.Fullscreen || cl.Ws == nil || cl.Out == nil ||
           cl.Ws != cl.Out.Current { continue }
        stack := x11.STACK_MODE_ABOVE
        if cl.DecorationFrame != 0 {
            x11.xcb_configure_window(g_wm.conn, cl.DecorationFrame, x11.CW_STACK_MODE, &stack)
        }
        x11.xcb_configure_window(g_wm.conn, cl.Xid, x11.CW_STACK_MODE, &stack)
    }
    if focused != nil && focused.AlwaysOnTop && focused.Floating && focused.Mapped &&
       !focused.Stashed && !focused.Fullscreen && focused.Ws != nil &&
       focused.Out != nil && focused.Ws == focused.Out.Current {
        stack := x11.STACK_MODE_ABOVE
        if focused.DecorationFrame != 0 {
            x11.xcb_configure_window(g_wm.conn, focused.DecorationFrame, x11.CW_STACK_MODE, &stack)
        }
        x11.xcb_configure_window(g_wm.conn, focused.Xid, x11.CW_STACK_MODE, &stack)
    }
}

// raise_docks restores the normal panel layer, then puts an active fullscreen
// client above it. This is called anywhere a newly mapped or focused window can
// disturb stacking, so docks remain above ordinary windows without covering a
// real fullscreen client.
raise_docks :: proc() {
    raise_always_on_top()
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
    // Preserve the client's requested pre-layout rectangle. If a panel sets
    // its DOCK type just after MapRequest, promotion can restore this geometry
    // instead of retaining the temporary tile assigned by the WM.
    read_dock_geometry(cl)
    cl.InitialRect = cl.FloatingRect
    read_client_meta(cl)
    read_client_urgency(cl)
    read_size_hints(cl)
    cl.TransientFor = read_transient_for(cl.Xid)
    cl.Modal = has_atom_property(cl.Xid, "_NET_WM_STATE", "_NET_WM_STATE_MODAL")
    cl.Dialog = cl.TransientFor != 0 || read_dialog_type(cl) || cl.Modal
    transient_parent := m.ByXid[cl.TransientFor]

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
        output := c.Output_At_Rect(m, cl.FloatingRect)
        read_struts(cl, output)
        c.Add_Dock_To_Output(m, output, cl)
        ewmh_client_managed(cl) // _NET_CLIENT_LIST (no _NET_WM_DESKTOP: Ws == nil)
        reflow() // arranges the dock and maps it (push_geoms)
        raise_docks() // keep the dock below an active fullscreen client
        ipc_broadcast_window_event(c.IPC_WINDOW_NEW, cl)
        return
    }
    // InitialRect owns the pre-management snapshot. Normal clients keep the
    // established empty FloatingRect sentinel so a later float toggle receives
    // skarwm's centered default instead of the application's arbitrary hint.
    cl.FloatingRect = {}

    target_output := requested_output
    if transient_parent != nil && transient_parent.Out != nil {
        target_output = transient_parent.Out
    }
    old_ws := c.Current_WS(m)
    if target_output != nil && c.Focus_Output(m, target_output) {
        ipc_broadcast_output_event("focus", target_output.Name)
        ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, target_output.Current, old_ws)
    }

    ws := c.Current_WS(m)
    if transient_parent != nil && transient_parent.Ws != nil {
        ws = transient_parent.Ws
    }
    if ws == nil {
        ws = c.Ensure_WS(m, 1)
        c.Activate_WS(m, ws)
    }
    floating := float_override || cl.Dialog
    cl.Decorated = decoration_for_client(cl)
    if tgt, fl, hit := rule_for_client(cl); hit {
        if tgt != nil { ws = tgt }
        floating = floating || fl
    }
    c.Add_Managed(m, ws, cl, floating, tab_target)
    ui.Ensure_Decoration(&g_wm.ui, m, cl)
    if cl.Dialog && cl.Floating {
        cl.FloatingRect = initial_dialog_rect(cl, transient_parent)
    }
    adopt_pre_wm_state(cl) // inherit fullscreen/maximize set before mapping
    ewmh_client_managed(cl) // _NET_CLIENT_LIST + _NET_WM_DESKTOP
    reflow()
    raise_docks() // restore normal dock order (or fullscreen above all)
    ipc_broadcast_window_event(c.IPC_WINDOW_NEW, cl)
    ipc_broadcast_focus_change(old_focus, m.Focused)
}

promote_client_to_dock :: proc(cl: ^c.Client) {
    if cl == nil || cl.Dock { return }
    m := g_wm.m
    requested := cl.InitialRect
    if requested.W <= 0 || requested.H <= 0 { read_dock_geometry(cl); requested = cl.FloatingRect }
    old_focus := m.Focused

    c.Unmanage_Client(m, cl)
    ui.Destroy_Decoration(&g_wm.ui, cl)
    rendering.Forget(&g_wm.rendering, cl.Xid)
    cl.Decorated = false
    cl.Fullscreen = false
    if cl.Maximized { c.Set_Maximized(cl, false) }
    cl.FloatingRect = requested

    output := c.Output_At_Rect(m, requested)
    read_struts(cl, output)
    c.Add_Dock_To_Output(m, output, cl)
    ewmh_client_became_dock(cl)
    reflow()
    raise_docks()
    ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
    ipc_broadcast_focus_change(old_focus, m.Focused)
}

// read_window_type reports whether the client's _NET_WM_WINDOW_TYPE atom list
// names DOCK (a dock/panel window).
read_window_type :: proc(cl: ^c.Client) -> bool {
    return has_window_type(cl, atom("_NET_WM_WINDOW_TYPE_DOCK"))
}

read_dialog_type :: proc(cl: ^c.Client) -> bool {
    return has_window_type(cl, atom("_NET_WM_WINDOW_TYPE_DIALOG"))
}

has_window_type :: proc(cl: ^c.Client, wanted: u32) -> bool {
    data, ok := x11.get_prop(g_wm.conn, cl.Xid, atom("_NET_WM_WINDOW_TYPE"), atom("ATOM"))
    if !ok { return false }
    defer delete(data)
    if len(data) % 4 != 0 { return false }
    vals := ([^]u32)(raw_data(data))[:len(data) / 4]
    for v in vals {
        if v == wanted { return true }
    }
    return false
}

has_atom_property :: proc(xid: u32, property_name, wanted_name: string) -> bool {
    data, ok := x11.get_prop(g_wm.conn, xid, atom(property_name), atom("ATOM"))
    if !ok { return false }
    defer delete(data)
    if len(data) % 4 != 0 { return false }
    wanted := atom(wanted_name)
    vals := ([^]u32)(raw_data(data))[:len(data) / 4]
    for v in vals {
        if v == wanted { return true }
    }
    return false
}

read_transient_for :: proc(xid: u32) -> u32 {
    data, ok := x11.get_prop(g_wm.conn, xid, atom("WM_TRANSIENT_FOR"), atom("WINDOW"))
    if !ok { return 0 }
    defer delete(data)
    if len(data) < size_of(u32) { return 0 }
    return (^u32)(raw_data(data))^
}

initial_dialog_rect :: proc(cl, parent: ^c.Client) -> c.Rect {
    if cl == nil { return {} }
    if cl.Out == nil { return cl.FloatingRect }
    bounds := c.Output_Work_Area(g_wm.m, cl.Out)
    requested := cl.InitialRect
    if c.rect_empty(requested) { requested = cl.FloatingRect }
    if cl.Decorated && cl.DecorationFrame != 0 {
        requested = c.Decoration_Frame_Rect(requested, g_wm.m.Cfg.Decoration)
    }
    requested = constrain_floating_rect(cl, requested)
    parent_rect := c.Rect{}
    if parent != nil && parent.Ws == cl.Ws { parent_rect = parent.Geom }
    return c.Centered_Float_Rect(requested, bounds, parent_rect)
}

promote_client_to_dialog :: proc(cl: ^c.Client) {
    if cl == nil || cl.Dock { return }
    parent := g_wm.m.ByXid[cl.TransientFor]
    if !cl.Floating { c.Set_Floating(g_wm.m, cl, true) }
    cl.FloatingRect = initial_dialog_rect(cl, parent)
    reflow()
}

// read_struts converts EWMH root-edge distances into local insets for the
// RandR output owning the dock. The partial ranges decide which monitor edge
// is affected; this is essential when one bar window exists per monitor.
read_struts :: proc(cl: ^c.Client, output: ^c.Output) {
    cl.Strut = c.Insets {}
    output_geom := c.Rect{}
    if output != nil {
        output_geom = output.Geom
        if output.Parent != nil { output_geom = output.Parent.Geom }
    }
    if data, ok := x11.get_prop(g_wm.conn, cl.Xid, atom("_NET_WM_STRUT_PARTIAL"), atom("CARDINAL")); ok {
        defer delete(data)
        if len(data) >= 12 * size_of(u32) && output != nil {
            vals := ([^]u32)(raw_data(data))
            ox1, ox2 := output_geom.X, output_geom.X + output_geom.W
            oy1, oy2 := output_geom.Y, output_geom.Y + output_geom.H
            vertical_overlap := i32(vals[5]) >= oy1 && i32(vals[4]) < oy2
            right_vertical_overlap := i32(vals[7]) >= oy1 && i32(vals[6]) < oy2
            horizontal_overlap := i32(vals[9]) >= ox1 && i32(vals[8]) < ox2
            bottom_horizontal_overlap := i32(vals[11]) >= ox1 && i32(vals[10]) < ox2
            if vals[0] > 0 && vertical_overlap {
                cl.Strut.Left = clamp(i32(vals[0]) - ox1, i32(0), output_geom.W)
            }
            if vals[1] > 0 && right_vertical_overlap {
                edge := g_wm.scr_w - i32(vals[1])
                cl.Strut.Right = clamp(ox2 - edge, i32(0), output_geom.W)
            }
            if vals[2] > 0 && horizontal_overlap {
                cl.Strut.Top = clamp(i32(vals[2]) - oy1, i32(0), output_geom.H)
            }
            if vals[3] > 0 && bottom_horizontal_overlap {
                edge := g_wm.scr_h - i32(vals[3])
                cl.Strut.Bottom = clamp(oy2 - edge, i32(0), output_geom.H)
            }
            return
        }
    }
    if data, ok := x11.get_prop(g_wm.conn, cl.Xid, atom("_NET_WM_STRUT"), atom("CARDINAL")); ok {
        defer delete(data)
        if len(data) >= 4 * 4 {
            vals := ([^]u32)(raw_data(data))
            if output == nil {
                cl.Strut.Left = i32(vals[0])
                cl.Strut.Right = i32(vals[1])
                cl.Strut.Top = i32(vals[2])
                cl.Strut.Bottom = i32(vals[3])
            } else {
                ox2 := output_geom.X + output_geom.W
                oy2 := output_geom.Y + output_geom.H
                if vals[0] > 0 do cl.Strut.Left = clamp(i32(vals[0]) - output_geom.X, i32(0), output_geom.W)
                if vals[1] > 0 do cl.Strut.Right = clamp(ox2 - (g_wm.scr_w - i32(vals[1])), i32(0), output_geom.W)
                if vals[2] > 0 do cl.Strut.Top = clamp(i32(vals[2]) - output_geom.Y, i32(0), output_geom.H)
                if vals[3] > 0 do cl.Strut.Bottom = clamp(oy2 - (g_wm.scr_h - i32(vals[3])), i32(0), output_geom.H)
            }
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
    if cl.Decorated && cl.DecorationFrame != 0 && !cl.Fullscreen {
        content := c.Decoration_Client_Rect(r, g_wm.m.Cfg.Decoration)
        content.W, content.H = c.Constrain_Size(cl.SizeHints, content.W, content.H)
        return c.Decoration_Frame_Rect(content, g_wm.m.Cfg.Decoration)
    }
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
    ui.Destroy_Decoration(&g_wm.ui, cl)
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
    if g_wm.reminder_dialog_active {
        reminder_dialog_keypress(ev)
        return
    }
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
                if focused := g_wm.m.Focused; focused != nil && !focused.Floating &&
                   focused.Ws != nil && focused.Ws.Layout == .Scroller {
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
    case .Focus_Left, .Move_Left, .Resize_Left:    return .Left
    case .Focus_Right, .Move_Right, .Resize_Right: return .Right
    case .Focus_Up, .Move_Up, .Resize_Up:          return .Up
    case .Focus_Down, .Move_Down, .Resize_Down:    return .Down
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
    g_wm.preview_hover_pending = 0
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
    case .Focus_Matching_Window:
        focus_matching_window(b)
    case .Move_Left, .Move_Right, .Move_Up, .Move_Down:
        if c.Move_Dir(m, dir_of(b.action)) {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Resize_Left, .Resize_Right, .Resize_Up, .Resize_Down:
        if c.Resize_Focused(m, dir_of(b.action)) {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Toggle_Floating:
        if c.Toggle_Floating(m) { reflow() }
    case .Toggle_Always_On_Top:
        if _, changed := c.Toggle_Always_On_Top(m); changed { reflow() }
    case .Toggle_Fullscreen:
        if _, changed := c.Toggle_Fullscreen(m); changed {
            raise_focused()
            reflow()
        }
    case .Layout_Floating:
        if c.Set_Workspace_Layout(m, .Floating) {
            reflow()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, m.Focused)
        }
    case .Layout_Tabbed:
        changed := false
        if m.Focused != nil && m.Focused.Floating {
            changed = c.Toggle_Floating(m)
        }
        ws := c.Current_WS(m)
        if ws == nil || ws.Layout != .Vertical_Scroller {
            changed = c.Set_Workspace_Layout(m, .Scroller) || changed
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
        ws := c.Current_WS(m)
        if ws == nil || ws.Layout != .Vertical_Scroller {
            changed = c.Set_Workspace_Layout(m, .Scroller) || changed
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
    case .Layout_Scroller, .Layout_Vertical_Scroller, .Layout_Dwindle, .Layout_Monocle, .Layout_Next:
        changed := false
        #partial switch b.action {
        case .Layout_Scroller: changed = c.Set_Workspace_Layout(m, .Scroller)
        case .Layout_Vertical_Scroller: changed = c.Set_Workspace_Layout(m, .Vertical_Scroller)
        case .Layout_Dwindle:  changed = c.Set_Workspace_Layout(m, .Dwindle)
        case .Layout_Monocle:  changed = c.Set_Workspace_Layout(m, .Monocle)
        case .Layout_Next:     changed = c.Cycle_Workspace_Layout(m)
        }
        if changed {
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
        if ipc_bindings_event() {
            ui.Hide_Help(&g_wm.ui)
        } else {
            ui.Toggle_Help(&g_wm.ui, g_wm.m, g_wm.bindings[:], g_wm.scr_w, g_wm.scr_h)
        }
    case .Show_Date_Time:
        show_date_time_notice()
    case .Show_Battery:
        show_battery_notice()
    case .Reminder_New:
        reminder_dialog_begin()
    case .Reminder_Show_All:
        reminder_show_all()
    case .Reminder_Clear_All:
        reminder_clear_all()
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
    case .Screen_Split_Toggle, .Screen_Split_Enable, .Screen_Split_Disable,
         .Screen_Split_Grow, .Screen_Split_Shrink, .Screen_Split_Ratio:
        screen_split_action(b.action, b.arg)
    }
    if b.action != .WS_Next && b.action != .WS_Prev && b.action != .WS_Goto {
        ipc_broadcast_focus_change(old_focus, m.Focused)
    }
}

focus_matching_window :: proc(b: ^input.Binding) -> bool {
    if b == nil { return false }
    m := g_wm.m
    target := c.Next_Matching_Client(m, c.Client_Match{
        Class = b.match_class,
        Instance = b.match_instance,
        Title = b.match_title,
    })
    if target == nil { return false }
    old_output := c.Active_Output(m)
    old_ws := c.Current_WS(m)
    if !c.Jump_To_Client(m, target) { return false }
    if target.Out != old_output { ipc_broadcast_output_event("focus", target.Out.Name) }
    if target.Ws != old_ws { ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, target.Ws, old_ws) }
    raise_focused()
    reflow()
    return true
}

screen_split_action :: proc(action: input.Action_Kind, arg: int) {
    m := g_wm.m
    active := c.Active_Output(m)
    if active == nil || active.Parent == nil { return }
    parent := active.Parent
    was_split := parent.Split
    old_left, old_right := "", ""
    if len(parent.Screens) > 0 { old_left = strings.clone(parent.Screens[0].Name) }
    if len(parent.Screens) > 1 { old_right = strings.clone(parent.Screens[1].Name) }
    defer {
        if old_left != "" do delete(old_left)
        if old_right != "" do delete(old_right)
    }

    changed := false
    #partial switch action {
    case .Screen_Split_Toggle:
        percent := arg
        if percent == 0 { percent = 75 }
        changed = c.Toggle_Output_Split(m, active, f64(percent) / 100.0)
    case .Screen_Split_Enable:
        percent := arg
        if percent == 0 { percent = 75 }
        changed = c.Enable_Output_Split(m, active, f64(percent) / 100.0)
    case .Screen_Split_Disable:
        changed = c.Disable_Output_Split(m, active)
    case .Screen_Split_Grow:
        amount := arg
        if amount <= 0 { amount = 50 }
        changed = c.Resize_Output_Split(m, active, i32(amount))
    case .Screen_Split_Shrink:
        amount := arg
        if amount <= 0 { amount = 50 }
        changed = c.Resize_Output_Split(m, active, -i32(amount))
    case .Screen_Split_Ratio:
        if arg >= 10 && arg <= 90 {
            changed = c.Set_Output_Split_Ratio(m, active, f64(arg) / 100.0)
        }
    }
    if !changed { return }

    reflow()
    randr_sync_virtual_monitors()
    if !was_split && parent.Split {
        ipc_broadcast_output_event("geometry", parent.Screens[0].Name)
        ipc_broadcast_output_event("added", parent.Screens[1].Name)
    } else if was_split && !parent.Split {
        ipc_broadcast_output_event("removed", old_right)
        ipc_broadcast_output_event("geometry", parent.Screens[0].Name)
    } else {
        ipc_broadcast_output_event("geometry", parent.Screens[0].Name)
        ipc_broadcast_output_event("geometry", parent.Screens[1].Name)
    }
    current := c.Active_Output(m)
    if current != nil && current.Name != old_left {
        ipc_broadcast_output_event("focus", current.Name)
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
    if ui.Decoration_Client(&g_wm.ui, ev.event) != nil {
        ui.Update_Decoration_Cursor(&g_wm.ui, g_wm.m, ev.event, i32(ev.event_x), i32(ev.event_y))
    }
    if scroll_preview_hover(i32(ev.root_x), i32(ev.root_y)) { return }
    if !g_wm.m.Cfg.FocusFollowsMouse { return }
    xid := ev.event
    cl := g_wm.m.ByXid[xid]
    if cl == nil { cl = ui.Decoration_Client(&g_wm.ui, xid) }
    if cl != nil {
        // Docks have Ws == nil, so on_current_ws below is false for them and
        // focus-follows-mouse can never land on a panel.
        if !on_current_ws(cl) { return }
        if cl == g_wm.m.Focused { return }
        old := g_wm.m.Focused
        c.Focus_Client(g_wm.m, cl)
        reflow()
        ipc_broadcast_focus_change(old, cl)
    }
}

cancel_preview_hover :: proc(unlock: bool = true) {
    g_wm.preview_hover_pending = 0
    g_wm.preview_hover_due = {}
    if unlock {
        g_wm.preview_hover_locked = false
        g_wm.preview_hover_target = 0
    }
}

preview_hover_poll_timeout_ms :: proc() -> i32 {
    if g_wm.preview_hover_pending == 0 { return -1 }
    remaining := time.tick_diff(time.tick_now(), g_wm.preview_hover_due)
    if remaining <= 0 { return 0 }
    ns := i64(remaining)
    return i32(min(i64(max(i32)), (ns + i64(time.Millisecond) - 1) / i64(time.Millisecond)))
}

preview_hover_run_due :: proc() {
    target := g_wm.preview_hover_pending
    if target == 0 || time.tick_diff(g_wm.preview_hover_due, time.tick_now()) < 0 { return }
    g_wm.preview_hover_pending = 0

    cookie := x11.xcb_query_pointer(g_wm.conn, g_wm.root)
    e: ^x11.Error
    reply := x11.xcb_query_pointer_reply(g_wm.conn, cookie, &e)
    if e != nil { x11.free_libc(e) }
    if reply == nil { return }
    defer x11.free_libc(reply)
    preview, over := c.Scroll_Preview_At_Point(g_wm.m, i32(reply.root_x), i32(reply.root_y))
    if !over || preview.Client == nil || preview.Client.Xid != target {
        return
    }
    old := g_wm.m.Focused
    if !c.Reveal_Scroll_Client(g_wm.m, preview.Client) { return }
    g_wm.preview_hover_locked = true
    g_wm.preview_hover_target = preview.Client.Xid
    reflow_preserve_viewport()
    ipc_broadcast_focus_change(old, preview.Client)
}

// scroll_preview_hover schedules a reveal only after the pointer remains on
// the same preview for the configured delay. Once revealed it stays locked
// until the pointer leaves all preview zones, preventing an immediate bounce.
scroll_preview_hover :: proc(x, y: i32) -> bool {
    preview, over := c.Scroll_Preview_At_Point(g_wm.m, x, y)
    if !over {
        cancel_preview_hover()
        return false
    }
    if g_wm.mouse_client != nil { return true }
    if g_wm.preview_hover_locked { return true }
    if g_wm.preview_hover_pending != preview.Client.Xid {
        g_wm.preview_hover_pending = preview.Client.Xid
        delay := time.Duration(max(i32(0), g_wm.m.Cfg.PreviewHoverDelayMs)) * time.Millisecond
        g_wm.preview_hover_due = time.tick_add(time.tick_now(), delay)
    }
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

begin_tiled_resize :: proc(cl: ^c.Client, root_x, root_y: i32) -> bool {
    if cl == nil || cl.Floating || cl.Fullscreen || cl.Maximized || !on_current_ws(cl) { return false }
    _, col, _ := c.Column_Of(cl)
    if col == nil { return false }

    // Finish any layout transition first so the drag snapshot matches the
    // geometry beneath the pointer exactly.
    reflow_immediate()
    state := Tiled_Resize_State{
        Active = true,
        Resize_Width = true,
        Resize_Height = col.Layout == .Stacked && len(col.Wins) > 1,
        From_Left = root_x < cl.Geom.X + cl.Geom.W / 2,
        From_Top = root_y < cl.Geom.Y + cl.Geom.H / 2,
    }
    g_wm.tiled_resize = state
    g_wm.mouse_client = cl
    g_wm.mouse_root_x = i16(root_x)
    g_wm.mouse_root_y = i16(root_y)
    return true
}

// Temporarily presents a tiled drag as a small window following the pointer.
// Keep the model untouched until drop; the next reflow restores or places
// the real tiled geometry atomically.
show_tiled_drag_preview :: proc(cl: ^c.Client, root_x, root_y: i32, header_height: i32 = 0) -> c.Rect {
    if cl == nil { return {} }
    size := TILED_DRAG_PREVIEW_SIZE
    if cl.SizeHints.MinW > 0 { size = max(size, cl.SizeHints.MinW) }
    if cl.SizeHints.MinH > 0 { size = max(size, cl.SizeHints.MinH) }
    width, height := size, size
    if cl.SizeHints.MaxW > 0 { width = min(width, cl.SizeHints.MaxW) }
    if cl.SizeHints.MaxH > 0 { height = min(height, cl.SizeHints.MaxH) }
    header_h := max(i32(0), header_height)
    preview := c.Rect{
        X = root_x - width / 2,
        Y = root_y - (height + header_h) / 2,
        W = max(i32(1), width),
        H = max(i32(1), height + header_h),
    }
    rendering.Preview_Client(
        &g_wm.rendering, g_wm.conn, g_wm.m, cl,
        c.Rect{
            X = preview.X,
            Y = preview.Y + header_h,
            W = preview.W,
            H = max(i32(1), preview.H - header_h),
        },
    )
    g_wm.mouse_preview = preview
    return preview
}

tiled_resize_motion :: proc(root_x, root_y: i32) {
    state := &g_wm.tiled_resize
    cl := g_wm.mouse_client
    if !state.Active || cl == nil { return }
    dx := root_x - i32(g_wm.mouse_root_x)
    dy := root_y - i32(g_wm.mouse_root_y)
    if state.From_Left { dx = -dx }
    if state.From_Top { dy = -dy }
    if !state.Resize_Width { dx = 0 }
    if !state.Resize_Height { dy = 0 }
    resize_edge := c.Resize_Edge.Left if state.From_Left else .Right
    if c.Resize_Tiled_Client(g_wm.m, cl, dx, dy, resize_edge) { reflow_immediate() }
    g_wm.mouse_root_x = i16(root_x)
    g_wm.mouse_root_y = i16(root_y)
}

decoration_stash_client :: proc(cl: ^c.Client) {
    if cl == nil { return }
    old_focus := g_wm.m.Focused
    title := cl.Title
    if title == "" { title = cl.Class }
    if title == "" { title = "Window" }
    register, ok := c.Scratchpad_Stash_Client(g_wm.m, cl)
    if !ok { return }
    reflow()
    ipc_broadcast_focus_change(old_focus, g_wm.m.Focused)
    ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
    notice := fmt.aprintf("%s moved to scratchpad %d", title, register)
    defer delete(notice)
    ui.Show_Notice(&g_wm.ui, g_wm.m, notice)
}

decoration_begin_drag :: proc(cl: ^c.Client, ev: ^x11.Button_Press_Event) {
    if cl == nil || cl.Fullscreen || !on_current_ws(cl) { return }
    g_wm.mouse_client = cl
    g_wm.mouse_decoration_drag = true
    g_wm.mouse_decoration_drag_started = false
    clean := ev.state & ~(g_wm.lock | g_wm.numlock)
    g_wm.mouse_decoration_tile_drag = clean & x11.MOD_MASK_MOD1 != 0
    g_wm.mouse_decoration_event_x = ev.event_x
    g_wm.mouse_root_x = ev.root_x
    g_wm.mouse_root_y = ev.root_y
    g_wm.mouse_start = cl.FloatingRect
}

decoration_activate_drag :: proc(cl: ^c.Client, root_x, root_y: i32) {
    if cl == nil || !g_wm.mouse_decoration_drag || g_wm.mouse_decoration_drag_started { return }
    was_maximized := cl.Maximized
    if cl.Maximized {
        maximized_frame := c.Decoration_Layout_Frame_Rect(cl.Geom, g_wm.m.Cfg.BorderWidth)
        c.Set_Maximized(cl, false)
        reflow_immediate()
        if cl.Floating {
            r := cl.FloatingRect
            anchor := clamp(i32(g_wm.mouse_decoration_event_x), i32(0), max(i32(1), maximized_frame.W))
            r.X = root_x - r.W*anchor/max(i32(1), maximized_frame.W)
            r.Y = root_y - g_wm.m.Cfg.Decoration.TitlebarHeight/2
            cl.FloatingRect = r
            reflow_immediate()
        }
        ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
    }
    g_wm.mouse_decoration_drag_started = true
    if was_maximized && cl.Floating {
        // The restored floating rect was anchored at this motion event, so it
        // has already absorbed the distance travelled past the threshold.
        g_wm.mouse_root_x = i16(root_x)
        g_wm.mouse_root_y = i16(root_y)
    }
    g_wm.mouse_start = cl.FloatingRect
    if cl.Floating {
        if g_wm.mouse_decoration_tile_drag {
            ui.Update_Drop(&g_wm.ui, g_wm.m, cl, root_x, root_y)
        }
        return
    }
    g_wm.mouse_tiled_drag = true
    // The decoration renderer adds its own titlebar around this preview.
    show_tiled_drag_preview(cl, root_x, root_y)
    raise_focused()
    if g_wm.mouse_decoration_tile_drag {
        ui.Update_Drop(&g_wm.ui, g_wm.m, cl, root_x, root_y)
    }
}

decoration_button_press :: proc(cl: ^c.Client, ev: ^x11.Button_Press_Event) {
    if cl == nil || ev.detail != 1 || !on_current_ws(cl) { return }
    old := g_wm.m.Focused
    if old != cl {
        c.Focus_Client(g_wm.m, cl)
        reflow_immediate()
        ipc_broadcast_focus_change(old, cl)
    }
    frame := c.Decoration_Layout_Frame_Rect(cl.Geom, g_wm.m.Cfg.BorderWidth)
    hit := c.Decoration_Hit_Test(frame.W, frame.H, i32(ev.event_x), i32(ev.event_y), g_wm.m.Cfg.Decoration)
    switch hit {
    case .Close:
        close_client(cl)
    case .Maximize:
        toggle_client_maximized(cl)
    case .Minimize:
        decoration_stash_client(cl)
    case .Title:
        decoration_begin_drag(cl, ev)
    case .Resize_Top, .Resize_Bottom, .Resize_Left, .Resize_Right,
         .Resize_Top_Left, .Resize_Top_Right, .Resize_Bottom_Left, .Resize_Bottom_Right:
        if cl.Floating && !cl.Maximized {
            g_wm.mouse_client = cl
            g_wm.mouse_resize = true
            g_wm.mouse_resize_hit = hit
            g_wm.mouse_root_x = ev.root_x
            g_wm.mouse_root_y = ev.root_y
            g_wm.mouse_start = cl.FloatingRect
        } else if !cl.Floating {
            begin_tiled_resize(cl, i32(ev.root_x), i32(ev.root_y))
        }
    case .None:
    }
}

on_button_press :: proc(ev: ^x11.Button_Press_Event) {
    // A click is an explicit action; it must cancel any delayed passive reveal
    // that was armed while the pointer approached this window.
    cancel_preview_hover(false)
    g_wm.preview_hover_locked = true
    g_wm.preview_hover_target = 0
    if field, ok := ui.Reminder_Input_At_Window(&g_wm.ui, ev.event); ok {
        ui.Set_Reminder_Field(&g_wm.ui, g_wm.m, field)
        return
    }
    if ev.event == g_wm.ui.ReminderWindow {
        if g_wm.ui.ReminderListMode { ui.Hide_Reminder_Panel(&g_wm.ui) }
        return
    }
    if ev.event == g_wm.ui.HelpWindow {
        ui.Hide_Help(&g_wm.ui)
        return
    }
    if ev.event == g_wm.ui.NoticeWindow {
        ui.Hide_Notice(&g_wm.ui)
        return
    }
    if cl := ui.Decoration_Client(&g_wm.ui, ev.event); cl != nil {
        decoration_button_press(cl, ev)
        return
    }
    clean := ev.state & ~(g_wm.lock | g_wm.numlock)
    modified := g_wm.primary_mod != 0 && clean & g_wm.primary_mod == g_wm.primary_mod
    if tab := ui.Tab_Client(&g_wm.ui, ev.event); tab != nil {
        if modified && ev.detail == 1 {
            _, col, _ := c.Column_Of(tab)
            if col != nil && col.Layout == .Tabbed && col.Focus != nil {
                g_wm.mouse_client = col.Focus
                g_wm.mouse_tiled_drag = true
                g_wm.mouse_column_drag = true
                g_wm.mouse_root_x = ev.root_x
                g_wm.mouse_root_y = ev.root_y
                preview := show_tiled_drag_preview(
                    col.Focus, i32(ev.root_x), i32(ev.root_y), c.TAB_BAR_HEIGHT,
                )
                stack := x11.STACK_MODE_ABOVE
                x11.xcb_configure_window(g_wm.conn, col.Focus.Xid, x11.CW_STACK_MODE, &stack)
                ui.Preview_Tab_Group(&g_wm.ui, col.Focus, preview)
                ui.Update_Column_Drop(&g_wm.ui, g_wm.m, col.Focus, i32(ev.root_x), i32(ev.root_y))
                x11.xcb_flush(g_wm.conn)
                return
            }
        }
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

    if g_wm.primary_mod != 0 && clean == g_wm.primary_mod && (ev.detail == 4 || ev.detail == 5) {
        // Do not let geometry moving beneath this explicit wheel action turn
        // the same stationary pointer into a second, implicit scroll.
        g_wm.preview_hover_locked = true
        g_wm.preview_hover_target = 0
        g_wm.preview_hover_pending = 0
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
        reflow_immediate()
        ipc_broadcast_focus_change(old, cl)
    }
    floating_drag := modified && cl.Floating && !cl.Maximized && (ev.detail == 1 || ev.detail == 3)
    tiled_drag := modified && !cl.Floating && ev.detail == 1
    tabbed_drag := tiled_drag && clean & x11.MOD_MASK_MOD1 != 0 &&
        g_wm.primary_mod & x11.MOD_MASK_MOD1 == 0
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
        if g_wm.mouse_resize { g_wm.mouse_resize_hit = .Resize_Bottom_Right }
        g_wm.mouse_tiled_drag = tiled_drag
        g_wm.mouse_tabbed_drag = tabbed_drag
        g_wm.mouse_root_x = ev.root_x
        g_wm.mouse_root_y = ev.root_y
        g_wm.mouse_start = cl.FloatingRect
        if tiled_drag {
            show_tiled_drag_preview(cl, i32(ev.root_x), i32(ev.root_y))
            raise_focused()
            if tabbed_drag {
                ui.Update_Tabbed_Drop(&g_wm.ui, g_wm.m, g_wm.mouse_client, i32(ev.root_x), i32(ev.root_y))
            } else if g_wm.mouse_decoration_drag {
                if g_wm.mouse_decoration_tile_drag {
                    ui.Update_Drop(&g_wm.ui, g_wm.m, g_wm.mouse_client, i32(ev.root_x), i32(ev.root_y))
                }
            } else {
                ui.Update_Drop(&g_wm.ui, g_wm.m, g_wm.mouse_client, i32(ev.root_x), i32(ev.root_y))
            }
        }
        x11.xcb_allow_events(g_wm.conn, x11.ALLOW_ASYNC_POINTER, ev.time)
    } else {
        x11.xcb_allow_events(g_wm.conn, x11.ALLOW_REPLAY_POINTER, ev.time)
    }
    x11.xcb_flush(g_wm.conn)
}

on_motion :: proc(ev: ^x11.Motion_Notify_Event) {
    cl := g_wm.mouse_client
    if cl == nil {
        if ui.Decoration_Client(&g_wm.ui, ev.event) != nil {
            ui.Update_Decoration_Cursor(&g_wm.ui, g_wm.m, ev.event, i32(ev.event_x), i32(ev.event_y))
            return
        }
        scroll_preview_hover(i32(ev.root_x), i32(ev.root_y))
        return
    }
    if g_wm.mouse_decoration_drag && !g_wm.mouse_decoration_drag_started {
        dx := abs(i32(ev.root_x) - i32(g_wm.mouse_root_x))
        dy := abs(i32(ev.root_y) - i32(g_wm.mouse_root_y))
        if max(dx, dy) < DECORATION_DRAG_THRESHOLD { return }
        decoration_activate_drag(cl, i32(ev.root_x), i32(ev.root_y))
    }
    if g_wm.mouse_tiled_drag {
        if g_wm.mouse_column_drag {
            preview := show_tiled_drag_preview(
                cl, i32(ev.root_x), i32(ev.root_y), c.TAB_BAR_HEIGHT,
            )
            stack := x11.STACK_MODE_ABOVE
            x11.xcb_configure_window(g_wm.conn, cl.Xid, x11.CW_STACK_MODE, &stack)
            ui.Preview_Tab_Group(&g_wm.ui, cl, preview)
            ui.Update_Column_Drop(&g_wm.ui, g_wm.m, g_wm.mouse_client, i32(ev.root_x), i32(ev.root_y))
        } else {
            show_tiled_drag_preview(cl, i32(ev.root_x), i32(ev.root_y))
            if g_wm.mouse_tabbed_drag {
                ui.Update_Tabbed_Drop(&g_wm.ui, g_wm.m, g_wm.mouse_client, i32(ev.root_x), i32(ev.root_y))
            } else if g_wm.mouse_decoration_drag {
                if g_wm.mouse_decoration_tile_drag {
                    ui.Update_Drop(&g_wm.ui, g_wm.m, g_wm.mouse_client, i32(ev.root_x), i32(ev.root_y))
                }
            } else {
                ui.Update_Drop(&g_wm.ui, g_wm.m, g_wm.mouse_client, i32(ev.root_x), i32(ev.root_y))
            }
        }
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
        hit := g_wm.mouse_resize_hit
        left := hit == .Resize_Left || hit == .Resize_Top_Left || hit == .Resize_Bottom_Left
        right := hit == .Resize_Right || hit == .Resize_Top_Right || hit == .Resize_Bottom_Right
        top := hit == .Resize_Top || hit == .Resize_Top_Left || hit == .Resize_Top_Right
        bottom := hit == .Resize_Bottom || hit == .Resize_Bottom_Left || hit == .Resize_Bottom_Right
        old_right, old_bottom := r.X+r.W, r.Y+r.H
        if left { r.X += dx; r.W -= dx }
        if right { r.W += dx }
        if top { r.Y += dy; r.H -= dy }
        if bottom { r.H += dy }
        r.W = max(i32(80), r.W)
        r.H = max(i32(60), r.H)
        r = constrain_floating_rect(cl, r)
        if left { r.X = old_right-r.W }
        if top { r.Y = old_bottom-r.H }
    } else {
        r.X += dx
        r.Y += dy
    }
    if g_wm.mouse_resize && g_wm.mouse_resize_hit == .None { r = constrain_floating_rect(cl, r) }
    cl.FloatingRect = r
    reflow_immediate()
    if g_wm.mouse_decoration_drag && g_wm.mouse_decoration_tile_drag && !g_wm.mouse_resize {
        ui.Update_Drop(&g_wm.ui, g_wm.m, cl, i32(ev.root_x), i32(ev.root_y))
    }
}

decoration_float_tiled_drag :: proc(cl: ^c.Client, root_x, root_y: i32) {
    if cl == nil || cl.Floating { return }
    old_output, old_ws := cl.Out, cl.Ws
    c.Set_Floating(g_wm.m, cl, true)
    output := c.Output_At_Point(g_wm.m, root_x, root_y)
    c.Move_Floating_To_Output(g_wm.m, cl, output)
    // The 300px tiled-drag preview is only a gesture affordance. Undocking
    // uses the client's remembered floating size, or Set_Floating's normal
    // ~60% default, and places that useful-sized window under the pointer.
    r := cl.FloatingRect
    r.X = root_x - r.W / 2
    r.Y = root_y - g_wm.m.Cfg.Decoration.TitlebarHeight / 2
    cl.FloatingRect = constrain_floating_rect(cl, r)
    reflow()
    raise_focused()
    if cl.Out != old_output {
        ipc_broadcast_output_event("focus", cl.Out.Name)
        ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, cl.Ws, old_ws)
    }
    ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
}

decoration_tile_floating_drag :: proc(cl: ^c.Client, target: c.Drop_Target) -> bool {
    if cl == nil || !cl.Floating || target.Kind == .None { return false }
    saved := cl.FloatingRect
    old_output, old_ws := cl.Out, cl.Ws
    c.Set_Floating(g_wm.m, cl, false)
    if !c.Move_Client_To_Drop(g_wm.m, cl, target) {
        c.Set_Floating(g_wm.m, cl, true)
        cl.FloatingRect = saved
        return false
    }
    reflow()
    raise_focused()
    if cl.Out != old_output {
        ipc_broadcast_output_event("focus", cl.Out.Name)
        ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, cl.Ws, old_ws)
    }
    ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
    return true
}

on_button_release :: proc(ev: ^x11.Button_Press_Event) {
    cl := g_wm.mouse_client
    if cl != nil && g_wm.mouse_tiled_drag {
        old_output := cl.Out
        old_ws := cl.Ws
        target := g_wm.ui.DropTarget
        ui.Hide_Drop(&g_wm.ui)
        moved := false
        if g_wm.mouse_column_drag {
            moved = c.Move_Tabbed_Column_To_Drop(g_wm.m, cl, target)
        } else if g_wm.mouse_tabbed_drag {
            moved = c.Move_Client_To_Tabbed_Drop(g_wm.m, cl, target)
        } else if !g_wm.mouse_decoration_drag || g_wm.mouse_decoration_tile_drag {
            // Re-resolve the destination at release in case the final motion
            // event arrived just before the button event.
            target = c.Drop_Target_At_Point(
                g_wm.m, i32(ev.root_x), i32(ev.root_y), cl, target,
            )
            moved = c.Move_Client_To_Drop(g_wm.m, cl, target)
        }
        if moved {
            if target.Out != old_output {
                ipc_broadcast_output_event("focus", target.Out.Name)
                ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, target.Ws, old_ws)
            }
            reflow()
            raise_focused()
            ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
        } else if g_wm.mouse_decoration_drag && !g_wm.mouse_decoration_tile_drag &&
                  !g_wm.mouse_column_drag && !g_wm.mouse_tabbed_drag {
            decoration_float_tiled_drag(cl, i32(ev.root_x), i32(ev.root_y))
        } else if g_wm.mouse_decoration_drag && g_wm.mouse_decoration_tile_drag {
            // An Alt decoration drag with no valid destination is cancelled,
            // matching the normal modified tiled-drag behavior.
            reflow()
        } else if g_wm.mouse_column_drag {
            // Restore both the client and its WM-owned header strip when the
            // group was released without a valid destination.
            reflow()
        }
    } else if g_wm.mouse_tiled_drag {
        ui.Hide_Drop(&g_wm.ui)
    } else if cl != nil && g_wm.mouse_decoration_drag &&
              g_wm.mouse_decoration_drag_started && cl.Floating && !g_wm.mouse_resize {
        target := g_wm.ui.DropTarget
        ui.Hide_Drop(&g_wm.ui)
        if g_wm.mouse_decoration_tile_drag {
            target = c.Drop_Target_At_Point(
                g_wm.m, i32(ev.root_x), i32(ev.root_y), cl, target,
            )
            decoration_tile_floating_drag(cl, target)
        }
    } else if cl != nil && g_wm.tiled_resize.Active {
        ipc_broadcast_window_event(c.IPC_WINDOW_LAYOUT, cl)
    }
    cancel_pointer_operation()
}

cancel_pointer_operation :: proc() {
    x11.xcb_ungrab_pointer(g_wm.conn, x11.CURRENT_TIME)
    if g_wm.mouse_tiled_drag || g_wm.mouse_decoration_drag { ui.Hide_Drop(&g_wm.ui) }
    g_wm.mouse_client = nil
    g_wm.mouse_resize = false
    g_wm.mouse_resize_hit = .None
    g_wm.mouse_tiled_drag = false
    g_wm.mouse_tabbed_drag = false
    g_wm.mouse_column_drag = false
    g_wm.mouse_decoration_drag = false
    g_wm.mouse_decoration_drag_started = false
    g_wm.mouse_decoration_tile_drag = false
    g_wm.mouse_decoration_event_x = 0
    g_wm.mouse_preview = {}
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
    x11.xcb_configure_window(g_wm.conn, xid, ev.value_mask, &vals[0])
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
    decorated := cl.Decorated && cl.DecorationFrame != 0 && !cl.Fullscreen && !cl.Dock
    if decorated { r = c.Decoration_Client_Rect(r, g_wm.m.Cfg.Decoration) }
    mask := ev.value_mask
    if mask & x11.CW_X != 0 { r.X = i32(ev.x) }
    if mask & x11.CW_Y != 0 { r.Y = i32(ev.y) }
    if mask & x11.CW_WIDTH != 0 { r.W = i32(ev.width) }
    if mask & x11.CW_HEIGHT != 0 { r.H = i32(ev.height) }
    if decorated { r = c.Decoration_Frame_Rect(r, g_wm.m.Cfg.Decoration) }
    if !cl.Dock { r = constrain_floating_rect(cl, r) }
    cl.FloatingRect = r
    if cl.Dock && cl.Out != nil {
        // Accept genuine margin changes, but keep the stable full-edge anchors
        // when a panel sends a delayed configure based on the previous RandR
        // monitor rectangle. This prevents rapid split resizes from restoring
        // an obsolete bar width one event later.
        c.Capture_Dock_Anchors(cl, cl.Out)
        c.Remap_Dock_To_Output(cl, cl.Out)
    }
}

// on_property_notify reacts to title changes (refresh metadata + IPC event)
// and dock strut changes (reflow the work area live).
on_property_notify :: proc(ev: ^x11.Property_Notify_Event) {
    cl := g_wm.m.ByXid[ev.window]
    if cl == nil { return }
    if ev.atom == atom("_NET_WM_WINDOW_TYPE") {
        if !cl.Dock && read_window_type(cl) {
            promote_client_to_dock(cl)
        } else if !cl.Dialog && read_dialog_type(cl) {
            cl.Dialog = true
            promote_client_to_dialog(cl)
        }
        return
    }
    if ev.atom == atom("WM_TRANSIENT_FOR") {
        parent := read_transient_for(cl.Xid)
        if parent != cl.TransientFor {
            cl.TransientFor = parent
            if parent != 0 && !cl.Dialog {
                cl.Dialog = true
                promote_client_to_dialog(cl)
            }
        }
        return
    }
    if ev.atom == atom("_NET_WM_STATE") {
        modal := has_atom_property(cl.Xid, "_NET_WM_STATE", "_NET_WM_STATE_MODAL")
        if modal != cl.Modal {
            cl.Modal = modal
            if modal && !cl.Dialog {
                cl.Dialog = true
                promote_client_to_dialog(cl)
            } else {
                reflow()
            }
        }
        return
    }
    if ev.atom == atom("_NET_WM_NAME") || ev.atom == atom("WM_NAME") {
        old := cl.Title
        fresh := read_client_title(cl.Xid)
        if fresh != old {
            cl.Title = fresh
            ipc_broadcast_window_event(c.IPC_WINDOW_TITLE, cl)
            if old != "" { delete(old) }
            ui.Render_Tabs(&g_wm.ui, g_wm.m)
            if cl.DecorationFrame != 0 { ui.Draw_Decoration(&g_wm.ui, g_wm.m, cl.DecorationFrame) }
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
        was_horizontal := cl.Strut.Top > 0 || cl.Strut.Bottom > 0
        was_vertical := cl.Strut.Left > 0 || cl.Strut.Right > 0
        read_struts(cl, cl.Out)
        is_horizontal := cl.Strut.Top > 0 || cl.Strut.Bottom > 0
        is_vertical := cl.Strut.Left > 0 || cl.Strut.Right > 0
        c.Capture_Dock_Anchors(cl, cl.Out,
            was_horizontal != is_horizontal || was_vertical != is_vertical)
        c.Remap_Dock_To_Output(cl, cl.Out)
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
    next_w, next_h := i32(ev.width), i32(ev.height)
    // RandR 1.5 SetMonitor/DeleteMonitor can send a root ConfigureNotify even
    // when the framebuffer dimensions stay unchanged.  Treat it as a rescreen
    // signal unless it came from our currently published split projection.
    size_changed := next_w != g_wm.scr_w || next_h != g_wm.scr_h
    if size_changed { g_wm.scr_w, g_wm.scr_h = next_w, next_h }
    if g_randr.available {
        if size_changed || len(g_randr.published) == 0 { randr_schedule_rescan() }
    } else {
        if !size_changed { return }
        _ = c.Reconcile_Outputs(g_wm.m, []c.Output_Spec{{
            Name = "screen",
            Geom = c.Rect{X = 0, Y = 0, W = g_wm.scr_w, H = g_wm.scr_h},
            Primary = true,
        }})
        reflow()
    }
}
