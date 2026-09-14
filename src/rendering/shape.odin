package rendering

import logger "../log"
import x11 "../x11"
import c "../core"

// X Shape-backed rounded client corners. Shapes are relative to the window
// origin, so moving a window needs no update; resize animation frames do.

import "core:math"

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
        conn: ^x11.Connection,
        operation, destination_kind, ordering: u8,
        destination_window: u32,
        x_offset, y_offset: i16,
        rectangles_len: u32,
        rectangles: ^Shape_Rectangle,
    ) -> x11.Cookie ---
    xcb_shape_mask :: proc(
        conn: ^x11.Connection,
        operation, destination_kind: u8,
        destination_window: u32,
        x_offset, y_offset: i16,
        source_bitmap: u32,
    ) -> x11.Cookie ---
}

shape_init :: proc(state: ^State, conn: ^x11.Connection) {
    name := "SHAPE"
    e: ^x11.Error
    reply := x11.xcb_query_extension_reply(
        conn,
        x11.xcb_query_extension(conn, u16(len(name)), cstring(raw_data(name))),
        &e,
    )
    if e != nil { x11.free_libc(e) }
    if reply != nil {
        state.ShapeAvailable = reply.present != 0
        x11.free_libc(reply)
    }
    if !state.ShapeAvailable {
        logger.Warn("X Shape unavailable; corner_radius is disabled")
    }
}

rounded_inset :: proc(radius, row, height: i32) -> i32 {
    edge := min(row, height - 1 - row)
    if edge >= radius { return 0 }
    r := f64(radius)
    dy := r - (f64(edge) + 0.5)
    return i32(math.ceil(r - math.sqrt(max(f64(0), r * r - dy * dy))))
}

shape_rounded_rectangle :: proc(conn: ^x11.Connection, xid: u32, kind: u8, x, y, width, height, radius: i32) {
    r := clamp(radius, i32(0), min(width, height) / 2)
    if r <= 0 {
        rect := Shape_Rectangle{x = i16(x), y = i16(y), width = u16(width), height = u16(height)}
        xcb_shape_rectangles(
            conn, SHAPE_SET, kind, SHAPE_UNSORTED, xid,
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
        conn, SHAPE_SET, kind, SHAPE_UNSORTED, xid,
        0, 0, u32(len(rects)), raw_data(rects),
    )
}

shape_client :: proc(state: ^State, conn: ^x11.Connection, m: ^c.Manager, cl: ^c.Client, geom: c.Rect, border: i32) {
    if !state.ShapeAvailable || cl == nil { return }

    width := max(i32(1), geom.W) + 2 * max(i32(0), border)
    height := max(i32(1), geom.H) + 2 * max(i32(0), border)
    radius := clamp(m.Cfg.CornerRadius, i32(0), min(width, height) / 2)
    rounded := radius > 0 && !cl.Fullscreen && !cl.Dock
    desired := Window_Shape_State{
        Width = width, Height = height, Border = border,
        Radius = radius, Rounded = rounded,
    }
    if old, found := state.WindowShapes[cl.Xid]; found && old == desired { return }

    if !rounded {
        // None removes both client regions and restores the server defaults.
        xcb_shape_mask(conn, SHAPE_SET, SHAPE_BOUNDING, cl.Xid, 0, 0, 0)
        xcb_shape_mask(conn, SHAPE_SET, SHAPE_CLIP, cl.Xid, 0, 0, 0)
        state.WindowShapes[cl.Xid] = desired
        return
    }

    b := max(i32(0), border)
    // X draws its border as bounding minus clip. Concentric outer and inner
    // arcs keep that difference visually equal to `border` around corners.
    shape_rounded_rectangle(conn, cl.Xid, SHAPE_BOUNDING, -b, -b, width, height, radius)
    shape_rounded_rectangle(
        conn, cl.Xid, SHAPE_CLIP, 0, 0,
        max(i32(1), geom.W), max(i32(1), geom.H), max(i32(0), radius - b),
    )
    state.WindowShapes[cl.Xid] = desired
}

shape_forget :: proc(state: ^State, xid: u32) {
    if state.WindowShapes != nil { delete_key(&state.WindowShapes, xid) }
}

shape_shutdown :: proc(state: ^State) {
    if state.WindowShapes != nil { delete(state.WindowShapes) }
    state.WindowShapes = nil
    state.ShapeAvailable = false
}
