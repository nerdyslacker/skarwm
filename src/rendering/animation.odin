package rendering

import x11 "../x11"
import c "../core"

// X-facing window geometry animation. Layout rectangles remain authoritative
// targets in core.Client.Geom; this module only tracks what has actually been
// sent to X, keeping rendering concerns out of the layout model.

import "core:time"

Client_Animation :: struct {
    Start, Current, Target: c.Rect,
    Start_Border, Current_Border, Target_Border: i32,
    Started: time.Tick,
    Duration: time.Duration,
    Easing: c.Animation_Easing,
    Active: bool,
}

Window_Shape_State :: struct {
    Width, Height, Border, Radius: i32,
    Rounded: bool,
}

State :: struct {
    Animations: map[u32]^Client_Animation,
    WindowShapes: map[u32]Window_Shape_State,
    ShapeAvailable: bool,
    AnimationsActive: bool,
    NextFrame: time.Tick,
}

Mapped_Callback :: proc(cl: ^c.Client)

Init :: proc(state: ^State, conn: ^x11.Connection) {
    state.Animations = make(map[u32]^Client_Animation)
    state.WindowShapes = make(map[u32]Window_Shape_State)
    shape_init(state, conn)
}

configure_client_geometry :: proc(state: ^State, conn: ^x11.Connection, m: ^c.Manager, cl: ^c.Client, geom: c.Rect, border: i32) {
    vals := [5]u32 {
        u32(i16(geom.X)),
        u32(i16(geom.Y)),
        u32(max(i32(1), geom.W)),
        u32(max(i32(1), geom.H)),
        u32(max(i32(0), border)),
    }
    x11.xcb_configure_window(
        conn, cl.Xid,
        x11.CW_X | x11.CW_Y | x11.CW_WIDTH | x11.CW_HEIGHT | x11.CW_BORDER_WIDTH, &vals[0],
    )
    shape_client(state, conn, m, cl, geom, border)
}

animation_sample :: proc(st: ^Client_Animation, now: time.Tick) {
    if st == nil || !st.Active { return }
    elapsed := time.tick_diff(st.Started, now)
    progress := c.Animation_Progress(i64(elapsed), i64(st.Duration))
    if progress >= 1 {
        st.Current = st.Target
        st.Current_Border = st.Target_Border
        st.Active = false
        return
    }
    factor := c.Animation_Ease(st.Easing, progress)
    st.Current = c.Animation_Lerp_Rect(st.Start, st.Target, factor)
    st.Current_Border = c.Animation_Lerp_I32(st.Start_Border, st.Target_Border, factor)
}

animation_is_parked :: proc(cl: ^c.Client, geom: c.Rect) -> bool {
    if cl.Out == nil { return false }
    return geom.X <= cl.Out.Geom.X + c.HIDE_X / 2
}

animation_frame_interval :: proc(m: ^c.Manager) -> time.Duration {
    fps := max(i32(1), m.Cfg.AnimationFps)
    return time.Duration(i64(time.Second) / i64(fps))
}

animation_schedule_next :: proc(state: ^State, m: ^c.Manager, now: time.Tick) {
    state.NextFrame = time.tick_add(now, animation_frame_interval(m))
}

animation_map_client :: proc(conn: ^x11.Connection, cl: ^c.Client, on_mapped: Mapped_Callback) {
    if cl.Mapped { return }
    x11.xcb_map_window(conn, cl.Xid)
    cl.Mapped = true
    if on_mapped != nil { on_mapped(cl) }
}

animation_clear_states :: proc(state: ^State) {
    for _, st in state.Animations { free(st) }
    clear(&state.Animations)
    state.AnimationsActive = false
}

Commit :: proc(state: ^State, conn: ^x11.Connection, m: ^c.Manager, request_animation: bool, on_mapped: Mapped_Callback) {
    cfg := &m.Cfg
    // Preserve the old direct path when animation is disabled: no per-client
    // animation allocations, clock deadline, timer wakeup, or map lookup.
    if !cfg.Animations || cfg.AnimationDurationMs <= 0 {
        if len(state.Animations) > 0 { animation_clear_states(state) }
        for cl in m.Clients {
            configure_client_geometry(state, conn, m, cl, cl.Geom, cl.Border)
            animation_map_client(conn, cl, on_mapped)
        }
        return
    }

    enabled := request_animation && cfg.Animations && cfg.AnimationDurationMs > 0
    now := time.tick_now()
    any_active := false

    for cl in m.Clients {
        st := state.Animations[cl.Xid]
        if st == nil {
            st = new(Client_Animation)
            st.Start = cl.Geom
            st.Current = cl.Geom
            st.Target = cl.Geom
            st.Start_Border = cl.Border
            st.Current_Border = cl.Border
            st.Target_Border = cl.Border
            st.Duration = time.Duration(cfg.AnimationDurationMs) * time.Millisecond
            st.Easing = cfg.AnimationEasing
            state.Animations[cl.Xid] = st
            configure_client_geometry(state, conn, m, cl, cl.Geom, cl.Border)
        } else {
            // Always sample first. If a second layout arrives mid-flight this
            // exact displayed rectangle becomes the new start, avoiding jumps.
            animation_sample(st, now)
            changed := st.Target != cl.Geom || st.Target_Border != cl.Border
            snap := !enabled || animation_is_parked(cl, st.Current) || animation_is_parked(cl, cl.Geom)
            if changed && !snap {
                st.Start = st.Current
                st.Start_Border = st.Current_Border
                st.Target = cl.Geom
                st.Target_Border = cl.Border
                st.Started = now
                st.Duration = time.Duration(cfg.AnimationDurationMs) * time.Millisecond
                st.Easing = cfg.AnimationEasing
                st.Active = true
            } else if changed || snap {
                st.Start = cl.Geom
                st.Current = cl.Geom
                st.Target = cl.Geom
                st.Start_Border = cl.Border
                st.Current_Border = cl.Border
                st.Target_Border = cl.Border
                st.Active = false
            }
            configure_client_geometry(state, conn, m, cl, st.Current, st.Current_Border)
        }

        if st.Active { any_active = true }
        animation_map_client(conn, cl, on_mapped)
    }

    state.AnimationsActive = any_active
    if any_active { animation_schedule_next(state, m, now) }
}

Run_Frame :: proc(state: ^State, conn: ^x11.Connection, m: ^c.Manager, now: time.Tick) {
    if !state.AnimationsActive { return }
    any_active := false
    for cl in m.Clients {
        st := state.Animations[cl.Xid]
        if st == nil || !st.Active { continue }
        animation_sample(st, now)
        configure_client_geometry(state, conn, m, cl, st.Current, st.Current_Border)
        if st.Active { any_active = true }
    }
    state.AnimationsActive = any_active
    if any_active { animation_schedule_next(state, m, now) }
    x11.xcb_flush(conn)
}

Poll_Timeout_Ms :: proc(state: ^State) -> i32 {
    if !state.AnimationsActive { return -1 }
    remaining := time.tick_diff(time.tick_now(), state.NextFrame)
    if remaining <= 0 { return 0 }
    // poll() takes whole milliseconds; ceiling prevents an early-wakeup spin.
    ns := i64(remaining)
    return i32((ns + i64(time.Millisecond) - 1) / i64(time.Millisecond))
}

Run_Due_Frame :: proc(state: ^State, conn: ^x11.Connection, m: ^c.Manager) {
    if !state.AnimationsActive { return }
    now := time.tick_now()
    if time.tick_diff(state.NextFrame, now) >= 0 {
        Run_Frame(state, conn, m, now)
    }
}

Forget :: proc(state: ^State, xid: u32) {
    if st := state.Animations[xid]; st != nil { free(st) }
    delete_key(&state.Animations, xid)
    shape_forget(state, xid)
}

Shutdown :: proc(state: ^State) {
    if state.Animations != nil {
        animation_clear_states(state)
        delete(state.Animations)
        state.Animations = nil
    }
    shape_shutdown(state)
    state.AnimationsActive = false
}
