package main

// X Shape-backed rounded client corners. Shapes are relative to the window
// origin, so moving a window needs no update; resize animation frames do.

import "core:math"
import c "core"

Shape_Rectangle :: struct {
    x, y: i16,
    width, height: u16,
}

SHAPE_SET      :: u8(0)
SHAPE_BOUNDING :: u8(0)
SHAPE_CLIP     :: u8(1)
SHAPE_UNSORTED :: u8(0)

foreign import xcb_shape "system:xcb-shape"

@(default_calling_convention = "c")
foreign xcb_shape {
    xcb_shape_rectangles :: proc(
        conn: ^Connection,
        operation, destination_kind, ordering: u8,
        destination_window: u32,
        x_offset, y_offset: i16,
        rectangles_len: u32,
        rectangles: ^Shape_Rectangle,
    ) -> Cookie ---
    xcb_shape_mask :: proc(
        conn: ^Connection,
        operation, destination_kind: u8,
        destination_window: u32,
        x_offset, y_offset: i16,
        source_bitmap: u32,
    ) -> Cookie ---
}

shape_init :: proc() {
    name := "SHAPE"
    e: ^Error
    reply := xcb_query_extension_reply(
        g_wm.conn,
        xcb_query_extension(g_wm.conn, u16(len(name)), cstring(raw_data(name))),
        &e,
    )
    if e != nil { free_libc(e) }
    if reply != nil {
        g_wm.shape_available = reply.present != 0
        free_libc(reply)
    }
    if !g_wm.shape_available {
        log_warn("X Shape unavailable; corner_radius is disabled")
    }
}

rounded_inset :: proc(radius, row, height: i32) -> i32 {
    edge := min(row, height - 1 - row)
    if edge >= radius { return 0 }
    r := f64(radius)
    dy := r - (f64(edge) + 0.5)
    return i32(math.ceil(r - math.sqrt(max(f64(0), r * r - dy * dy))))
}

shape_rounded_rectangle :: proc(xid: u32, kind: u8, x, y, width, height, radius: i32) {
    r := clamp(radius, i32(0), min(width, height) / 2)
    if r <= 0 {
        rect := Shape_Rectangle{x = i16(x), y = i16(y), width = u16(width), height = u16(height)}
        xcb_shape_rectangles(
            g_wm.conn, SHAPE_SET, kind, SHAPE_UNSORTED, xid,
            0, 0, 1, &rect,
        )
        return
    }

    rects := make([dynamic]Shape_Rectangle, 0, min(height, r * 2 + 1))
    defer delete(rects)
    band_y := i32(0)
    band_inset := rounded_inset(r, 0, height)
    for row in 1 ..< height {
        inset := rounded_inset(r, row, height)
        if inset == band_inset { continue }
        append(&rects, Shape_Rectangle{
            x = i16(x + band_inset), y = i16(y + band_y),
            width = u16(max(i32(1), width - 2 * band_inset)),
            height = u16(row - band_y),
        })
        band_y = row
        band_inset = inset
    }
    append(&rects, Shape_Rectangle{
        x = i16(x + band_inset), y = i16(y + band_y),
        width = u16(max(i32(1), width - 2 * band_inset)),
        height = u16(height - band_y),
    })
    xcb_shape_rectangles(
        g_wm.conn, SHAPE_SET, kind, SHAPE_UNSORTED, xid,
        0, 0, u32(len(rects)), raw_data(rects),
    )
}

shape_client :: proc(cl: ^c.Client, geom: c.Rect, border: i32) {
    if !g_wm.shape_available || cl == nil { return }

    width := max(i32(1), geom.W) + 2 * max(i32(0), border)
    height := max(i32(1), geom.H) + 2 * max(i32(0), border)
    radius := clamp(g_wm.m.Cfg.CornerRadius, i32(0), min(width, height) / 2)
    rounded := radius > 0 && !cl.Fullscreen && !cl.Dock
    desired := Window_Shape_State{
        Width = width, Height = height, Border = border,
        Radius = radius, Rounded = rounded,
    }
    if old, found := g_wm.window_shapes[cl.Xid]; found && old == desired { return }

    if !rounded {
        // None removes both client regions and restores the server defaults.
        xcb_shape_mask(g_wm.conn, SHAPE_SET, SHAPE_BOUNDING, cl.Xid, 0, 0, 0)
        xcb_shape_mask(g_wm.conn, SHAPE_SET, SHAPE_CLIP, cl.Xid, 0, 0, 0)
        g_wm.window_shapes[cl.Xid] = desired
        return
    }

    b := max(i32(0), border)
    // X draws its border as bounding minus clip. Concentric outer and inner
    // arcs keep that difference visually equal to `border` around corners.
    shape_rounded_rectangle(cl.Xid, SHAPE_BOUNDING, -b, -b, width, height, radius)
    shape_rounded_rectangle(
        cl.Xid, SHAPE_CLIP, 0, 0,
        max(i32(1), geom.W), max(i32(1), geom.H), max(i32(0), radius - b),
    )
    g_wm.window_shapes[cl.Xid] = desired
}

shape_forget :: proc(xid: u32) {
    if g_wm.window_shapes != nil { delete_key(&g_wm.window_shapes, xid) }
}

shape_shutdown :: proc() {
    if g_wm.window_shapes != nil { delete(g_wm.window_shapes) }
    g_wm.window_shapes = nil
    g_wm.shape_available = false
}
