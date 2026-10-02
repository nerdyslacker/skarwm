package ui

import logger "../log"
import c "../core"
import x11 "../x11"

// Decorations are non-reparenting override-redirect root children. The frame
// is stacked immediately below its client; the client covers the frame's
// content opening while the titlebar and edge ring remain visible and receive
// input. This preserves skarwm's root-coordinate client model.

DECORATION_CURSOR_SHAPES :: [9]u16{
    68,  // left_ptr
    138, // top_side
    16,  // bottom_side
    70,  // left_side
    96,  // right_side
    134, // top_left_corner
    136, // top_right_corner
    12,  // bottom_left_corner
    14,  // bottom_right_corner
}

init_decoration_cursors :: proc(state: ^State) {
    if state == nil || state.Conn == nil || state.DecorationCursors[0] != 0 { return }
    font_name := "cursor"
    state.DecorationCursorFont = x11.xcb_generate_id(state.Conn)
    x11.xcb_open_font(state.Conn, state.DecorationCursorFont, u16(len(font_name)), cstring(raw_data(font_name)))
    for shape, i in DECORATION_CURSOR_SHAPES {
        cursor := x11.xcb_generate_id(state.Conn)
        x11.xcb_create_glyph_cursor(
            state.Conn, cursor, state.DecorationCursorFont, state.DecorationCursorFont,
            shape, shape+1, 0, 0, 0, 0xffff, 0xffff, 0xffff,
        )
        state.DecorationCursors[i] = cursor
    }
}

decoration_cursor_index :: proc(hit: c.Decoration_Hit) -> int {
    switch hit {
    case .Resize_Top: return 1
    case .Resize_Bottom: return 2
    case .Resize_Left: return 3
    case .Resize_Right: return 4
    case .Resize_Top_Left: return 5
    case .Resize_Top_Right: return 6
    case .Resize_Bottom_Left: return 7
    case .Resize_Bottom_Right: return 8
    case .None, .Title, .Minimize, .Maximize, .Close: return 0
    }
    return 0
}

Decoration_Client :: proc(state: ^State, xid: u32) -> ^c.Client {
    if state == nil || xid == 0 { return nil }
    for frame in state.Decorations {
        if frame.Xid == xid { return frame.Client }
    }
    return nil
}

Ensure_Decoration :: proc(state: ^State, m: ^c.Manager, cl: ^c.Client) -> bool {
    if state == nil || state.Conn == nil || m == nil || cl == nil || cl.Dock || !cl.Decorated { return false }
    if cl.DecorationFrame != 0 { return true }
    Init_Tabs(state) // shared fixed-font GC
    init_decoration_cursors(state)
    xid := x11.xcb_generate_id(state.Conn)
    mask := x11.EVENT_MASK_EXPOSURE | x11.EVENT_MASK_BUTTON_PRESS |
        x11.EVENT_MASK_BUTTON_RELEASE | x11.EVENT_MASK_POINTER_MOTION |
        x11.EVENT_MASK_ENTER_WINDOW | x11.EVENT_MASK_LEAVE_WINDOW
    vals := [4]u32{m.Cfg.Decoration.InactiveBackground, 1, mask, state.DecorationCursors[0]}
    cookie := x11.xcb_create_window_checked(
        state.Conn, 0, xid, state.Root, 0, 0, 1, 1, 0,
        x11.WINDOW_CLASS_INPUT_OUTPUT, 0,
        x11.CW_BACK_PIXEL | x11.CW_OVERRIDE_REDIRECT | x11.CW_EVENT_MASK | x11.CW_CURSOR, &vals[0],
    )
    if err := x11.xcb_request_check(state.Conn, cookie); err != nil {
        xe := (^x11.X_Error)(err)
        logger.Error("cannot create client decoration; X error", xe.error_code,
                     "request", xe.major_code, "resource", xe.resource_id)
        x11.free_libc(err)
        cl.Decorated = false
        return false
    }
    cl.DecorationFrame = xid
    append(&state.Decorations, Frame_Decoration{Xid = xid, Client = cl})
    x11.set_prop_text(state.Conn, xid, atom(state, "_NET_WM_NAME"), atom(state, "UTF8_STRING"), "skarwm decoration")
    x11.set_prop_text(state.Conn, xid, atom(state, "WM_NAME"), atom(state, "STRING"), "skarwm decoration")
    return true
}

Update_Decoration_Cursor :: proc(state: ^State, m: ^c.Manager, xid: u32, x, y: i32) {
    cl := Decoration_Client(state, xid)
    if cl == nil || m == nil { return }
    init_decoration_cursors(state)
    frame := c.Decoration_Layout_Frame_Rect(cl.Geom, m.Cfg.BorderWidth)
    hit := c.Decoration_Hit_Test(frame.W, frame.H, x, y, m.Cfg.Decoration)
    cursor := state.DecorationCursors[decoration_cursor_index(hit)]
    if cursor != 0 { x11.xcb_change_window_attributes(state.Conn, xid, x11.CW_CURSOR, &cursor) }
}

Destroy_Decoration :: proc(state: ^State, cl: ^c.Client) {
    if state == nil || cl == nil || cl.DecorationFrame == 0 { return }
    xid := cl.DecorationFrame
    for frame, i in state.Decorations {
        if frame.Xid == xid {
            unordered_remove(&state.Decorations, i)
            break
        }
    }
    if state.Conn != nil { x11.xcb_destroy_window(state.Conn, xid) }
    cl.DecorationFrame = 0
    cl.DecorationFrameMapped = false
}

Sync_Decorations :: proc(state: ^State, m: ^c.Manager) {
    if state == nil || m == nil { return }
    for cl in m.Clients {
        if cl.Decorated && !cl.Dock { Ensure_Decoration(state, m, cl) }
        else { Destroy_Decoration(state, cl) }
    }
}

decoration_ascii_title :: proc(cl: ^c.Client, dst: []u8) -> int {
    label := "untitled"
    if cl != nil && cl.Title != "" { label = cl.Title }
    n := min(len(label), len(dst))
    for i in 0 ..< n {
        ch := label[i]
        dst[i] = ch if ch >= 0x20 && ch < 0x7f else '?'
    }
    return n
}

Draw_Decoration :: proc(state: ^State, m: ^c.Manager, xid: u32) {
    cl := Decoration_Client(state, xid)
    if cl == nil || cl.DecorationFrame == 0 || cl.Fullscreen || cl.Stashed { return }
    cfg := m.Cfg.Decoration
    frame := c.Decoration_Layout_Frame_Rect(cl.Geom, m.Cfg.BorderWidth)
    w, h := max(i32(1), frame.W), max(i32(1), frame.H)
    b := clamp(cfg.BorderWidth, i32(0), min(w, h)/2)
    title_h := min(max(i32(0), cfg.TitlebarHeight), max(i32(0), h-2*b))
    colors := c.Resolve_Decoration_Colors(cfg, m.Cfg.FocusedBorder, m.Cfg.UnfocusedBorder, m.Focused == cl)
    if cl.AlwaysOnTop { colors.Border = cfg.Accent }

    // Keep the resize gutter visually quiet. Only the one-pixel outline and
    // title strip use active colors; the wider hit area remains dark.
    frame_base := cfg.InactiveBackground
    x11.xcb_change_window_attributes(state.Conn, xid, x11.CW_BACK_PIXEL, &frame_base)
    x11.xcb_clear_area(state.Conn, 0, xid, 0, 0, u16(w), u16(h))
    title_vals := [2]u32{colors.Background, colors.Background}
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &title_vals[0])
    if title_h > 0 {
        title_rect := x11.Rectangle{x=i16(b), y=i16(b), width=u16(max(i32(1), w-2*b)), height=u16(title_h)}
        x11.xcb_poly_fill_rectangle(state.Conn, xid, state.TabGC, 1, &title_rect)
    }
    gc_vals := [2]u32{colors.Border, colors.Background}
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &gc_vals[0])
    if b > 0 {
        rects := [4]x11.Rectangle{
            {x = 0, y = 0, width = u16(w), height = u16(b)},
            {x = 0, y = i16(h-b), width = u16(w), height = u16(b)},
            {x = 0, y = i16(b), width = u16(b), height = u16(max(i32(1), h-2*b))},
            {x = i16(w-b), y = i16(b), width = u16(b), height = u16(max(i32(1), h-2*b))},
        }
        x11.xcb_poly_fill_rectangle(state.Conn, xid, state.TabGC, 4, &rects[0])
    }

    text_vals := [2]u32{colors.Foreground, colors.Background}
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &text_vals[0])
    baseline := i16(b + max(i32(12), (title_h+10)/2))
    button_w := max(i32(1), cfg.TitlebarHeight)
    title_x := b + 7
    indicator_w := i32(0)
    if cl.AlwaysOnTop && title_h >= 10 {
        // A tiny geometric pushpin avoids depending on any icon font. Draw it
        // in the existing configurable decoration accent.
        pin_x := b + 7
        pin_y := b + max(i32(1), (title_h-11)/2)
        pin_vals := [2]u32{cfg.Accent, colors.Background}
        x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &pin_vals[0])
        pin_head := x11.Rectangle{x=i16(pin_x), y=i16(pin_y), width=7, height=5}
        pin_stem := x11.Rectangle{x=i16(pin_x+3), y=i16(pin_y+5), width=1, height=5}
        x11.xcb_poly_fill_rectangle(state.Conn, xid, state.TabGC, 1, &pin_head)
        x11.xcb_poly_fill_rectangle(state.Conn, xid, state.TabGC, 1, &pin_stem)
        pin_tip := x11.Segment{x1=i16(pin_x+1), y1=i16(pin_y+10), x2=i16(pin_x+5), y2=i16(pin_y+10)}
        x11.xcb_poly_segment(state.Conn, xid, state.TabGC, 1, &pin_tip)
        title_x += 15
        indicator_w = 15
        x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &text_vals[0])
    }
    if cfg.ShowTitle {
        max_chars := max(i32(0), (w - 3*button_w - 2*b - 14 - indicator_w)/6)
        buf: [255]u8
        n := min(decoration_ascii_title(cl, buf[:]), int(max_chars))
        if n > 0 { x11.xcb_image_text_8(state.Conn, u8(n), xid, state.TabGC, i16(title_x), baseline, cstring(&buf[0])) }
    }
    button_size := clamp(title_h-7, i32(8), i32(12))
    button_y := b + max(i32(0), (title_h-button_size)/2)
    for i in 0 ..< 3 {
        center := w - i32(3-i)*button_w + button_w/2
        button_x := center-button_size/2
        outline := [4]x11.Rectangle{
            {x=i16(button_x), y=i16(button_y), width=u16(button_size), height=1},
            {x=i16(button_x), y=i16(button_y+button_size-1), width=u16(button_size), height=1},
            {x=i16(button_x), y=i16(button_y), width=1, height=u16(button_size)},
            {x=i16(button_x+button_size-1), y=i16(button_y), width=1, height=u16(button_size)},
        }
        x11.xcb_poly_fill_rectangle(state.Conn, xid, state.TabGC, 4, &outline[0])
        if i == 0 {
            mark := x11.Rectangle{x=i16(button_x+2), y=i16(button_y+button_size-3), width=u16(max(i32(1), button_size-4)), height=1}
            x11.xcb_poly_fill_rectangle(state.Conn, xid, state.TabGC, 1, &mark)
        } else if i == 1 && button_size >= 8 {
            inner := [4]x11.Rectangle{
                {x=i16(button_x+2), y=i16(button_y+2), width=u16(button_size-4), height=1},
                {x=i16(button_x+2), y=i16(button_y+button_size-3), width=u16(button_size-4), height=1},
                {x=i16(button_x+2), y=i16(button_y+2), width=1, height=u16(button_size-4)},
                {x=i16(button_x+button_size-3), y=i16(button_y+2), width=1, height=u16(button_size-4)},
            }
            x11.xcb_poly_fill_rectangle(state.Conn, xid, state.TabGC, 4, &inner[0])
        } else if i == 2 {
            pad := i32(3)
            cross := [2]x11.Segment{
                {x1=i16(button_x+pad), y1=i16(button_y+pad), x2=i16(button_x+button_size-pad-1), y2=i16(button_y+button_size-pad-1)},
                {x1=i16(button_x+button_size-pad-1), y1=i16(button_y+pad), x2=i16(button_x+pad), y2=i16(button_y+button_size-pad-1)},
            }
            x11.xcb_poly_segment(state.Conn, xid, state.TabGC, 2, &cross[0])
        }
    }
}

Draw_All_Decorations :: proc(state: ^State, m: ^c.Manager) {
    if state == nil { return }
    for frame in state.Decorations { Draw_Decoration(state, m, frame.Xid) }
}

Shutdown_Decorations :: proc(state: ^State) {
    if state == nil { return }
    if state.Conn != nil {
        for frame in state.Decorations {
            if frame.Client != nil {
                frame.Client.DecorationFrame = 0
                frame.Client.DecorationFrameMapped = false
            }
            x11.xcb_destroy_window(state.Conn, frame.Xid)
        }
        for cursor in state.DecorationCursors {
            if cursor != 0 { x11.xcb_free_cursor(state.Conn, cursor) }
        }
        if state.DecorationCursorFont != 0 { x11.xcb_close_font(state.Conn, state.DecorationCursorFont) }
    }
    if state.Decorations != nil { delete(state.Decorations) }
    state.Decorations = nil
    state.DecorationCursors = {}
    state.DecorationCursorFont = 0
}
