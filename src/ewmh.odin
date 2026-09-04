package main

// EWMH/ICCCM compatibility for common X11 applications and external tools.
//
// Scope: the small subset common X11 applications and external tools actually
// rely on. Everything is written through the property helpers in atoms.odin.
//
//   Root properties (maintained by the WM):
//     _NET_SUPPORTED              what we claim to support (nothing more)
//     _NET_SUPPORTING_WM_CHECK    a 1x1 child window naming this WM
//     _NET_WM_NAME                "skarwm"
//     _NET_CLIENT_LIST            every managed client, refreshed on manage/unmanage
//     _NET_ACTIVE_WINDOW          focused client (None when nothing is focused)
//     _NET_CURRENT_DESKTOP        current workspace, 0-based
//     _NET_NUMBER_OF_DESKTOPS     highest created workspace id (>= 1)
//     _NET_WORKAREA               work rect per desktop, from dock strut reservations
//
//   Client properties (written by the WM):
//     _NET_WM_DESKTOP             owning workspace, 0-based
//     _NET_WM_STATE               FULLSCREEN while the client is fullscreen
//     WM_STATE                    Normal once mapped, Withdrawn on unmanage
//
//   Client messages accepted (sent to the root, EWMH convention; the target
//   window travels in the message's window field):
//     _NET_ACTIVE_WINDOW          focus request from pagers/launchers/tools
//     _NET_WM_STATE               fullscreen add/remove/toggle (mpv, browsers…)
//     _NET_CURRENT_DESKTOP        workspace switch from pagers/wmctrl
//     _NET_CLOSE_WINDOW           polite close request
//
//   ICCCM: WM_DELETE_WINDOW was already handled (M1); here WM_TAKE_FOCUS is
//   announced to clients that advertise it.
//
// Not implemented (deliberately): _NET_CLIENT_LIST_STACKING (we do not track a
// global z-order), desktop names, icon geometry, property-change driven state
// flips (EWMH mandates the ClientMessage).
// Struts and the dock window type ARE read (see docs/REFERENCE_NOTES.md §10):
// only _NET_WM_WINDOW_TYPE_DOCK windows contribute, only their struts
// (_NET_WM_STRUT_PARTIAL preferred) shrink the work area, and the partial
// form's begin/end edge ranges are ignored on our single full-screen output.
// Fullscreen requests for windows on an inactive workspace are ignored:
// fullscreen in this WM belongs to the focused window of the visible
// workspace, so there is no sensible geometry to give them.
//
// Property writes are deduplicated through Ewmh_State caches so reflows with
// unchanged state do not spam the server (each write is a round trip).

import c "core"

// EWMH bookkeeping for deduplicated writes. Owned by g_wm.ewmh.
Ewmh_State :: struct {
    check_win:   u32, // _NET_SUPPORTING_WM_CHECK child window
    last_active: u32, // xid advertised via _NET_ACTIVE_WINDOW (0 = None)
    last_desktop: i32, // current desktop index advertised (-1 = unset)
    last_count:   i32, // _NET_NUMBER_OF_DESKTOPS advertised (-1 = unset)
    win_desktop: map[u32]u32, // xid -> last _NET_WM_DESKTOP written
    win_fs:       map[u32]bool, // xid -> fullscreen state last written
    win_mapped:   map[u32]bool, // xid -> WM_STATE Normal has been written
    workarea:   []u32, // last _NET_WORKAREA written (nil = never)
}

WM_STATE_WITHDRAWN :: i32(0) // ICCCM state values; the WM sets Normal when a
WM_STATE_NORMAL     :: i32(1) // client is mapped and Withdrawn when it leaves.

// Max workspace id addressable through a _NET_CURRENT_DESKTOP/_NET_WM_DESKTOP
// client message (desktop index + 1). Guards against garbage input creating an
// absurd workspace; real pagers never exceed a few dozen.
EWMH_MAX_WS_ID :: 4096

// ---------------------------------------------------------------------------
// Initialisation / teardown
// ---------------------------------------------------------------------------

// ewmh_init publishes the root EWMH state and readies the dedupe caches. Call
// after the atom cache exists and before adopting existing windows, so that
// every manage() hook sees a live Ewmh_State.
ewmh_init :: proc() {
    st := &g_wm.ewmh
    st.last_desktop = -1
    st.last_count = -1
    st.win_desktop = make(map[u32]u32)
    st.win_fs = make(map[u32]bool)
    st.win_mapped = make(map[u32]bool)

    // _NET_SUPPORTING_WM_CHECK child: a tiny, unmapped InputOutput window that
    // names the WM. Both root and child point at the child; the child carries
    // the human-readable name (this is what `wmctrl -m` prints).
    wid := xcb_generate_id(g_wm.conn)
    xcb_create_window(
        g_wm.conn,
        0, // depth 0 == copy from parent
        wid,
        g_wm.root,
        0, 0, 1, 1,
        0, // border width
        WINDOW_CLASS_INPUT_OUTPUT,
        0, // visual 0 == copy from parent
        0, // no attributes
        nil,
    )
    st.check_win = wid
    set_prop_atom(g_wm.conn, wid, atom("_NET_SUPPORTING_WM_CHECK"), atom("WINDOW"), wid)
    set_prop_text(g_wm.conn, wid, atom("_NET_WM_NAME"), atom("UTF8_STRING"), "skarwm")
    set_prop_atom(g_wm.conn, g_wm.root, atom("_NET_SUPPORTING_WM_CHECK"), atom("WINDOW"), wid)
    set_prop_text(g_wm.conn, g_wm.root, atom("_NET_WM_NAME"), atom("UTF8_STRING"), "skarwm")

    // _NET_SUPPORTED: claim exactly what this file implements.
    supported := []u32 {
        atom("_NET_SUPPORTING_WM_CHECK"),
        atom("_NET_WM_NAME"),
        atom("_NET_CLIENT_LIST"),
        atom("_NET_ACTIVE_WINDOW"),
        atom("_NET_CLOSE_WINDOW"),
        atom("_NET_CURRENT_DESKTOP"),
        atom("_NET_NUMBER_OF_DESKTOPS"),
        atom("_NET_WORKAREA"),
        atom("_NET_WM_DESKTOP"),
        atom("_NET_WM_STATE"),
        atom("_NET_WM_STATE_FULLSCREEN"),
        atom("_NET_WM_WINDOW_TYPE"),
        atom("_NET_WM_WINDOW_TYPE_DOCK"),
        atom("_NET_WM_STRUT"),
        atom("_NET_WM_STRUT_PARTIAL"),
        atom("WM_PROTOCOLS"),
        atom("WM_DELETE_WINDOW"),
        atom("WM_TAKE_FOCUS"),
    }
    set_prop32(g_wm.conn, g_wm.root, atom("_NET_SUPPORTED"), atom("ATOM"), supported)

    // _NET_CLIENT_LIST stays absent until the first manage() publishes it.
    // _NET_ACTIVE_WINDOW
    // is advertised as None up front, and the desktop properties default to
    // workspace 1 current / count 1; ewmh_pulse reconciles them as workspaces
    // appear.
    ewmh_push_desktops()
    st.last_active = 0
    set_prop_atom(g_wm.conn, g_wm.root, atom("_NET_ACTIVE_WINDOW"), atom("WINDOW"), 0)
    xcb_flush(g_wm.conn)
}

ewmh_free :: proc() {
    st := &g_wm.ewmh
    if st.check_win != 0 {
        xcb_destroy_window(g_wm.conn, st.check_win)
        st.check_win = 0
    }
    if st.win_desktop != nil do delete(st.win_desktop)
    if st.win_fs != nil do delete(st.win_fs)
    if st.win_mapped != nil do delete(st.win_mapped)
    if st.workarea != nil do delete(st.workarea)
    st.last_active = 0
    st.last_desktop = -1
    st.last_count = -1
}

// ---------------------------------------------------------------------------
// Root property pushes (deduplicated)
// ---------------------------------------------------------------------------

// ewmh_push_client_list rewrites _NET_CLIENT_LIST from the manager registry.
// Called on every manage/unmanage (windows change membership rarely; a full
// rebuild is one property write and is simpler than incremental updates).
ewmh_push_client_list :: proc() {
    m := g_wm.m
    xids := make([]u32, len(m.Clients))
    defer delete(xids)
    for cl, i in m.Clients {
        xids[i] = cl.Xid
    }
    set_prop32(g_wm.conn, g_wm.root, atom("_NET_CLIENT_LIST"), atom("WINDOW"), xids)
}

// desktop_count returns the number of desktops to advertise: the highest
// existing workspace id (>= 1). Because dynamic workspaces are never
// implicitly created, _NET_NUMBER_OF_DESKTOPS is the highest workspace id that
// exists, not the number of occupied workspaces. Jumping to workspace 7
// therefore exposes desktops 0..6, and pager clicks on the gaps create the
// workspace on demand (dynamic ws).
desktop_count :: proc(m: ^c.Manager) -> i32 {
    count := i32(1)
    o := c.Active_Output(m)
    if o != nil {
        for ws in o.Ws {
            if i32(ws.Id) > count { count = i32(ws.Id) }
        }
    }
    return count
}

// ewmh_push_desktops publishes current-desktop and desktop-count. Desktop
// numbering is 0-based workspace id: desktop N is workspace N+1.
ewmh_push_desktops :: proc() {
    st := &g_wm.ewmh
    cur := c.Current_WS(g_wm.m)
    idx := i32(0)
    if cur != nil {
        idx = i32(cur.Id - 1)
    }
    count := desktop_count(g_wm.m)
    if idx != st.last_desktop {
        st.last_desktop = idx
        set_prop32(g_wm.conn, g_wm.root, atom("_NET_CURRENT_DESKTOP"), atom("CARDINAL"), []u32{u32(idx)})
    }
    if count != st.last_count {
        st.last_count = count
        set_prop32(g_wm.conn, g_wm.root, atom("_NET_NUMBER_OF_DESKTOPS"), atom("CARDINAL"), []u32{u32(count)})
    }
}

// ewmh_push_workarea publishes _NET_WORKAREA: the active output's work rect
// (x, y, w, h) repeated once per desktop, in desktop order — the EWMH shape
// (each desktop shares the screen). The work rect already accounts for dock
// strut reservations (compute_params with the output's Reserved), so clients
// learn about a bar the moment its strut lands. Deduplicated like the other
// root pushes.
ewmh_push_workarea :: proc() {
    st := &g_wm.ewmh
    m := g_wm.m
    o := c.Active_Output(m)
    if o == nil { return }
    p := c.compute_params(m.Cfg, o.Geom, 0, o.Reserved)
    n := int(desktop_count(m))
    vals := make([]u32, 4 * n)
    defer delete(vals)
    for i in 0 ..< n {
        vals[4 * i + 0] = u32(p.WorkX)
        vals[4 * i + 1] = u32(p.WorkY)
        vals[4 * i + 2] = u32(p.WorkW)
        vals[4 * i + 3] = u32(p.WorkH)
    }
    if st.workarea != nil && len(st.workarea) == len(vals) {
        same := true
        for v, i in vals {
            if st.workarea[i] != v { same = false; break }
        }
        if same { return }
    }
    set_prop32(g_wm.conn, g_wm.root, atom("_NET_WORKAREA"), atom("CARDINAL"), vals)
    if st.workarea != nil do delete(st.workarea)
    st.workarea = make([]u32, len(vals))
    copy(st.workarea, vals)
}

// ---------------------------------------------------------------------------
// Client property pushes (deduplicated)
// ---------------------------------------------------------------------------

// ewmh_push_client writes the client's _NET_WM_DESKTOP (its workspace id - 1).
ewmh_push_client :: proc(cl: ^c.Client) {
    st := &g_wm.ewmh
    if cl == nil || cl.Ws == nil { return }
    idx := u32(cl.Ws.Id - 1)
    if cached, ok := st.win_desktop[cl.Xid]; ok && cached == idx { return }
    st.win_desktop[cl.Xid] = idx
    set_prop32(g_wm.conn, cl.Xid, atom("_NET_WM_DESKTOP"), atom("CARDINAL"), []u32{idx})
}

// ewmh_push_fs mirrors the model's fullscreen flag into the client's
// _NET_WM_STATE (an empty replace removes the property, per EWMH).
ewmh_push_fs :: proc(cl: ^c.Client) {
    st := &g_wm.ewmh
    if cl == nil { return }
    if cached, ok := st.win_fs[cl.Xid]; ok && cached == cl.Fullscreen { return }
    st.win_fs[cl.Xid] = cl.Fullscreen
    if cl.Fullscreen {
        fs := [1]u32{atom("_NET_WM_STATE_FULLSCREEN")}
        set_prop32(g_wm.conn, cl.Xid, atom("_NET_WM_STATE"), atom("ATOM"), fs[:])
    } else {
        // remove: an empty slice makes set_prop32 delete the property
        set_prop32(g_wm.conn, cl.Xid, atom("_NET_WM_STATE"), atom("ATOM"), []u32{})
    }
}

// ewmh_set_wm_state writes ICCCM WM_STATE (Normal/Withdrawn + no icon window).
// The property uses format 32 with state and icon-window values.
ewmh_set_wm_state :: proc(cl: ^c.Client, state: i32) {
    vals := [2]u32{u32(state), 0}
    xcb_change_property(g_wm.conn, PROP_MODE_REPLACE, cl.Xid, atom("WM_STATE"), atom("WM_STATE"), ATOM_FORMAT_32, 2, &vals[0])
}

// ---------------------------------------------------------------------------
// Structural hooks (called from wm.odin / main.odin)
// ---------------------------------------------------------------------------

// ewmh_client_managed runs after a client joined the model: advertise it and
// publish its desktop. WM_STATE Normal is written when the window is first
// mapped (push_geoms), not here.
ewmh_client_managed :: proc(cl: ^c.Client) {
    ewmh_push_client(cl)
    ewmh_push_client_list()
}

// ewmh_client_unmanaged runs before the client is freed: withdraw it (while
// the X window may still exist), drop it from _NET_CLIENT_LIST and forget the
// dedupe caches so a later re-manage of the same xid starts clean.
ewmh_client_unmanaged :: proc(cl: ^c.Client) {
    st := &g_wm.ewmh
    if was_mapped, ok := st.win_mapped[cl.Xid]; ok && was_mapped {
        ewmh_set_wm_state(cl, WM_STATE_WITHDRAWN)
    }
    delete_key(&st.win_desktop, cl.Xid)
    delete_key(&st.win_fs, cl.Xid)
    delete_key(&st.win_mapped, cl.Xid)
    ewmh_push_client_list()
}

// ewmh_mark_mapped records that the window was mapped (WM_STATE Normal) — call
// exactly when the map request is issued for a not-yet-mapped client.
ewmh_mark_mapped :: proc(cl: ^c.Client) {
    if _, ok := g_wm.ewmh.win_mapped[cl.Xid]; ok { return }
    g_wm.ewmh.win_mapped[cl.Xid] = true
    ewmh_set_wm_state(cl, WM_STATE_NORMAL)
}

// ewmh_pulse reconciles everything that can drift between structural events.
// Called at the end of every reflow: the writes are deduplicated, so an
// unchanged layout costs only map lookups.
ewmh_pulse :: proc() {
    m := g_wm.m
    ewmh_push_desktops()
    ewmh_push_workarea()
    for cl in m.Clients {
        ewmh_push_client(cl)
        ewmh_push_fs(cl)
    }
}

// ewmh_push_active advertises the focused client (or None) on the root. Called
// from apply_x_focus, which runs on every focus change.
ewmh_push_active :: proc(focused: ^c.Client) {
    st := &g_wm.ewmh
    xid := u32(0)
    if focused != nil && focused.Mapped {
        xid = focused.Xid
    }
    if xid == st.last_active { return }
    st.last_active = xid
    set_prop_atom(g_wm.conn, g_wm.root, atom("_NET_ACTIVE_WINDOW"), atom("WINDOW"), xid)
}

// ---------------------------------------------------------------------------
// Client message handling (the EWMH/ICCCM entry point)
// ---------------------------------------------------------------------------

// ewmh_on_client_message dispatches EWMH requests. Senders follow the EWMH
// convention of targeting the *root* with the destination window in the
// message's window field (wmctrl, xdotool, mpv, browsers, GTK); the client
// message reaches us through our root Substructure selection. A few legacy
// senders put the window in data[0] instead — accepted for _NET_ACTIVE_WINDOW.
ewmh_on_client_message :: proc(ev: ^Client_Message_Event) {
    m := g_wm.m
    msg := ev.type_

    switch msg {
    case atom("_NET_ACTIVE_WINDOW"):
        cl := m.ByXid[ev.window]
        if cl == nil {
            // EWMH 1.2-era senders: target in data.l[0], message to root.
            legacy := u32(ev.data.data32[0])
            if ev.window == g_wm.root {
                cl = m.ByXid[legacy]
            }
        }
        if cl != nil { ewmh_activate(cl) }

    case atom("_NET_WM_STATE"):
        ewmh_state_request(ev)

    case atom("_NET_CURRENT_DESKTOP"):
        // Desktop index N == workspace N+1. Unknown workspaces are created
        // dynamically (they may exist empty afterwards — the documented
        // keep-empty-workspaces policy).
        idx := int(ev.data.data32[0])
        if idx < EWMH_MAX_WS_ID {
            ws_switch_to(idx + 1) // announces the switch over IPC
        }

    case atom("_NET_CLOSE_WINDOW"):
        // data.l[0] names the window per EWMH; some senders leave it 0 and set
        // the message's window field instead.
        target := ev.data.data32[0]
        cl := m.ByXid[target]
        if cl == nil && target == 0 {
            cl = m.ByXid[ev.window]
        }
        if cl != nil {
            close_client(cl)
        }
    case:
        // WM_CHANGE_STATE (iconify), _NET_MOVERESIZE_WINDOW and friends have no
        // skarwm equivalent; ignoring them is the compatible behaviour.
    }
}

// ewmh_state_request applies a _NET_WM_STATE add/remove/toggle for fullscreen.
// Other state atoms (maximized, hidden, …) are ignored — claiming them in
// _NET_SUPPORTED would only set expectations we do not keep.
ewmh_state_request :: proc(ev: ^Client_Message_Event) {
    m := g_wm.m
    cl := m.ByXid[ev.window]
    if cl == nil { return }
    if cl.Out == nil || cl.Ws != cl.Out.Current {
        // Fullscreen geometry only exists for the visible workspace's focus;
        // a request for a hidden window has no meaning here.
        return
    }

    action := ev.data.data32[0]
    prop1 := ev.data.data32[1]
    prop2 := ev.data.data32[2]
    fs := atom("_NET_WM_STATE_FULLSCREEN")
    if prop1 != fs && prop2 != fs { return }

    want: bool
    switch action {
    case 0: // _NET_WM_STATE_REMOVE
        want = false
    case 1: // _NET_WM_STATE_ADD
        want = true
    case 2: // _NET_WM_STATE_TOGGLE
        want = !cl.Fullscreen
    case:
        return
    }
    if want == cl.Fullscreen { return }

    // Invariant: while shown, the fullscreen window is the workspace focus.
    old_focus := m.Focused
    if want && m.Focused != cl {
        c.Focus_Client(m, cl)
    }
    cl.Fullscreen = want
    if want { raise_focused() }
    reflow()
    ipc_broadcast_focus_change(old_focus, m.Focused)
}

// ewmh_activate focuses a client on behalf of a pager/launcher/tool,
// switching workspaces when the window lives elsewhere.
ewmh_activate :: proc(cl: ^c.Client) {
    m := g_wm.m
    old_focus := m.Focused
    ws := cl.Ws
    if ws == nil { return }

    if cl.Out != nil {
        if oi := c.Output_Index(m, cl.Out); oi >= 0 { m.Active = oi }
    }

    switched := ws != c.Current_WS(m)
    if switched {
        old := c.Current_WS(m)
        c.Activate_WS(m, ws) // the workspace exists (the client is on it)
        ipc_broadcast_ws_event(c.IPC_CHANGE_FOCUS, ws, old)
    }
    if m.Focused != cl {
        c.Focus_Client(m, cl)
    }
    if switched { raise_focused() }
    reflow()
    ipc_broadcast_focus_change(old_focus, m.Focused)
}

// ---------------------------------------------------------------------------
// ICCCM focus protocols
// ---------------------------------------------------------------------------

// ewmh_announce_take_focus offers WM_TAKE_FOCUS to clients that advertise it
// (Xt/Java style apps that manage their own focus). The X input focus is always
// set, and the protocol message is sent as a courtesy so such
// clients know they became active. The message goes to the client's own
// window with mask 0, which the server delivers to the creating client.
ewmh_announce_take_focus :: proc(cl: ^c.Client) {
    if !client_has_protocol(cl.Xid, atom("WM_TAKE_FOCUS")) { return }
    send_client_message(cl.Xid, atom("WM_PROTOCOLS"), atom("WM_TAKE_FOCUS"), CURRENT_TIME)
}

// adopt_pre_fullscreen lets manage() inherit a client that was already
// fullscreen when we met it (WM restart with a fullscreen app, or an app that
// set _NET_WM_STATE before its first map).
adopt_pre_fullscreen :: proc(cl: ^c.Client) {
    fs := atom("_NET_WM_STATE_FULLSCREEN")
    data, ok := get_prop(g_wm.conn, cl.Xid, atom("_NET_WM_STATE"), atom("ATOM"))
    if !ok { return }
    defer delete(data)
    if len(data) % 4 != 0 { return }
    vals := ([^]u32)(raw_data(data))[:len(data) / 4]
    for v in vals {
        if v == fs {
            cl.Fullscreen = true
            return
        }
    }
}
