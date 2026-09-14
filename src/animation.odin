package main

// X-facing window geometry animation. Layout rectangles remain authoritative
// targets in core.Client.Geom; this module only tracks what has actually been
// sent to X, keeping rendering concerns out of the layout model.

import "core:time"
import c "core"

configure_client_geometry :: proc(cl: ^c.Client, geom: c.Rect, border: i32) {
    vals := [5]u32 {
        u32(i16(geom.X)),
        u32(i16(geom.Y)),
        u32(max(i32(1), geom.W)),
        u32(max(i32(1), geom.H)),
        u32(max(i32(0), border)),
    }
    xcb_configure_window(
        g_wm.conn, cl.Xid,
        CW_X | CW_Y | CW_WIDTH | CW_HEIGHT | CW_BORDER_WIDTH, &vals[0],
    )
    shape_client(cl, geom, border)
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

animation_frame_interval :: proc() -> time.Duration {
    fps := max(i32(1), g_wm.m.Cfg.AnimationFps)
    return time.Duration(i64(time.Second) / i64(fps))
}

animation_schedule_next :: proc(now: time.Tick) {
    g_wm.animation_next_frame = time.tick_add(now, animation_frame_interval())
}

animation_map_client :: proc(cl: ^c.Client) {
    if cl.Mapped { return }
    xcb_map_window(g_wm.conn, cl.Xid)
    cl.Mapped = true
    ewmh_mark_mapped(cl)
}

animation_clear_states :: proc() {
    for _, st in g_wm.animations { free(st) }
    clear(&g_wm.animations)
    g_wm.animations_active = false
}

animation_commit_targets :: proc(request_animation: bool) {
    cfg := &g_wm.m.Cfg
    // Preserve the old direct path when animation is disabled: no per-client
    // animation allocations, clock deadline, timer wakeup, or map lookup.
    if !cfg.Animations || cfg.AnimationDurationMs <= 0 {
        if len(g_wm.animations) > 0 { animation_clear_states() }
        for cl in g_wm.m.Clients {
            configure_client_geometry(cl, cl.Geom, cl.Border)
            animation_map_client(cl)
        }
        return
    }

    enabled := request_animation && cfg.Animations && cfg.AnimationDurationMs > 0
    now := time.tick_now()
    any_active := false

    for cl in g_wm.m.Clients {
        st := g_wm.animations[cl.Xid]
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
            g_wm.animations[cl.Xid] = st
            configure_client_geometry(cl, cl.Geom, cl.Border)
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
            configure_client_geometry(cl, st.Current, st.Current_Border)
        }

        if st.Active { any_active = true }
        animation_map_client(cl)
    }

    g_wm.animations_active = any_active
    if any_active { animation_schedule_next(now) }
}

animation_run_frame :: proc(now: time.Tick) {
    if !g_wm.animations_active { return }
    any_active := false
    for cl in g_wm.m.Clients {
        st := g_wm.animations[cl.Xid]
        if st == nil || !st.Active { continue }
        animation_sample(st, now)
        configure_client_geometry(cl, st.Current, st.Current_Border)
        if st.Active { any_active = true }
    }
    g_wm.animations_active = any_active
    if any_active { animation_schedule_next(now) }
    xcb_flush(g_wm.conn)
}

animation_poll_timeout_ms :: proc() -> i32 {
    if !g_wm.animations_active { return -1 }
    remaining := time.tick_diff(time.tick_now(), g_wm.animation_next_frame)
    if remaining <= 0 { return 0 }
    // poll() takes whole milliseconds; ceiling prevents an early-wakeup spin.
    ns := i64(remaining)
    return i32((ns + i64(time.Millisecond) - 1) / i64(time.Millisecond))
}

animation_run_due_frame :: proc() {
    if !g_wm.animations_active { return }
    now := time.tick_now()
    if time.tick_diff(g_wm.animation_next_frame, now) >= 0 {
        animation_run_frame(now)
    }
}

animation_forget :: proc(xid: u32) {
    if st := g_wm.animations[xid]; st != nil { free(st) }
    delete_key(&g_wm.animations, xid)
    shape_forget(xid)
}

animation_shutdown :: proc() {
    if g_wm.animations == nil { return }
    animation_clear_states()
    delete(g_wm.animations)
    g_wm.animations = nil
    g_wm.animations_active = false
}
