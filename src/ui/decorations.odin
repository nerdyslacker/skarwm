package ui

import logger "../log"
import c "../core"
import x11 "../x11"
import "core:fmt"

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
    case .None, .Title, .Minimize, .Maximize, .Close,
         .Audio_Mute, .Audio_Slider, .Audio_Compact: return 0
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

decoration_frame :: proc(state: ^State, xid: u32) -> ^Frame_Decoration {
    if state == nil || xid == 0 { return nil }
    for &frame in state.Decorations { if frame.Xid == xid { return &frame } }
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
    decoration := decoration_frame(state, xid)
    if decoration == nil || decoration.Client == nil || m == nil { return }
    cl := decoration.Client
    init_decoration_cursors(state)
    frame := c.Decoration_Layout_Frame_Rect(cl.Geom, m.Cfg.BorderWidth)
    hit := c.Decoration_Hit_Test(frame.W, frame.H, x, y, m.Cfg.Decoration, decoration.AudioVisible)
    cursor := state.DecorationCursors[decoration_cursor_index(hit)]
    if cursor != 0 { x11.xcb_change_window_attributes(state.Conn, xid, x11.CW_CURSOR, &cursor) }
}

Destroy_Decoration :: proc(state: ^State, cl: ^c.Client) {
    if state == nil || cl == nil || cl.DecorationFrame == 0 { return }
    if state.DecorationAudioPopupClient == cl { Hide_Decoration_Audio_Popup(state) }
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

audio_percent :: proc(volume: u32) -> i32 {
    return clamp(i32((u64(volume)*100+32_768)/65_536), i32(0), i32(100))
}

draw_audio_widget :: proc(
    state: ^State, drawable: u32, frame: ^Frame_Decoration,
    layout: c.Decoration_Audio_Layout, foreground, background: u32,
) {
    if state == nil || frame == nil || layout.Mode == .Hidden { return }
    vals := [2]u32{foreground, background}
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &vals[0])

    icon := layout.Speaker
    if icon.W > 0 && icon.H > 0 {
        icon_size := min(icon.W, icon.H)
        body_x := icon.X + max(i32(2), icon_size/5)
        body_y := icon.Y + icon.H/2 - max(i32(2), icon_size/6)
        body := x11.Rectangle{x=i16(body_x), y=i16(body_y), width=u16(max(i32(2), icon_size/4)), height=u16(max(i32(4), icon_size/3))}
        x11.xcb_poly_fill_rectangle(state.Conn, drawable, state.TabGC, 1, &body)
        cone := [3]x11.Segment{
            {x1=i16(body_x+icon_size/4), y1=i16(body_y), x2=i16(body_x+icon_size/2), y2=i16(body_y-icon_size/6)},
            {x1=i16(body_x+icon_size/2), y1=i16(body_y-icon_size/6), x2=i16(body_x+icon_size/2), y2=i16(body_y+icon_size/2)},
            {x1=i16(body_x+icon_size/2), y1=i16(body_y+icon_size/2), x2=i16(body_x+icon_size/4), y2=i16(body_y+icon_size/3)},
        }
        x11.xcb_poly_segment(state.Conn, drawable, state.TabGC, 3, &cone[0])
        if frame.AudioMuted || frame.AudioMixed {
            slash := x11.Segment{x1=i16(icon.X+icon_size*2/3), y1=i16(icon.Y+icon_size/4), x2=i16(icon.X+icon_size/3), y2=i16(icon.Y+icon_size*3/4)}
            x11.xcb_poly_segment(state.Conn, drawable, state.TabGC, 1, &slash)
        }
    }

    slider := layout.Slider
    if slider.W > 0 {
        track_y := slider.Y+slider.H/2
        track := x11.Rectangle{x=i16(slider.X), y=i16(track_y-1), width=u16(slider.W), height=3}
        x11.xcb_poly_fill_rectangle(state.Conn, drawable, state.TabGC, 1, &track)
        thumb_x := slider.X+2 + max(i32(0), slider.W-4)*audio_percent(frame.AudioVolume)/100
        thumb := x11.Rectangle{x=i16(thumb_x-2), y=i16(track_y-5), width=5, height=11}
        x11.xcb_poly_fill_rectangle(state.Conn, drawable, state.TabGC, 1, &thumb)
    }
    if layout.Percentage.W > 0 {
        label := fmt.tprintf("%d%%", audio_percent(frame.AudioVolume))
        baseline := layout.Percentage.Y + max(i32(12), (layout.Percentage.H+10)/2)
        x11.xcb_image_text_8(state.Conn, u8(len(label)), drawable, state.TabGC,
                            i16(layout.Percentage.X), i16(baseline), cstring(raw_data(label)))
    }
}

Draw_Decoration_Audio :: proc(state: ^State, m: ^c.Manager, xid: u32) {
    decoration := decoration_frame(state, xid)
    if decoration == nil || decoration.Client == nil || !decoration.AudioVisible { return }
    frame_rect := c.Decoration_Layout_Frame_Rect(decoration.Client.Geom, m.Cfg.BorderWidth)
    layout := c.Decoration_Audio_Layout_For(frame_rect.W, frame_rect.H, m.Cfg.Decoration, true)
    if layout.Mode == .Hidden { return }
    colors := c.Resolve_Decoration_Colors(m.Cfg.Decoration, m.Cfg.FocusedBorder, m.Cfg.UnfocusedBorder, m.Focused == decoration.Client)
    clear_vals := [2]u32{colors.Background, colors.Background}
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &clear_vals[0])
    rect := x11.Rectangle{x=i16(layout.Bounds.X), y=i16(layout.Bounds.Y), width=u16(layout.Bounds.W), height=u16(layout.Bounds.H)}
    x11.xcb_poly_fill_rectangle(state.Conn, xid, state.TabGC, 1, &rect)
    draw_audio_widget(state, xid, decoration, layout, colors.Foreground, colors.Background)
}

Set_Decoration_Audio :: proc(state: ^State, m: ^c.Manager, cl: ^c.Client, visible: bool, volume: u32, muted, mixed: bool) {
    if state == nil || m == nil || cl == nil { return }
    frame := decoration_frame(state, cl.DecorationFrame)
    if frame == nil { return }
    visibility_changed := frame.AudioVisible != visible
    changed := visibility_changed || frame.AudioVolume != volume || frame.AudioMuted != muted || frame.AudioMixed != mixed
    if !changed { return }
    frame.AudioVisible, frame.AudioVolume = visible, volume
    frame.AudioMuted, frame.AudioMixed = muted, mixed
    if !visible && state.DecorationAudioPopupClient == cl { Hide_Decoration_Audio_Popup(state) }
    if visibility_changed { Draw_Decoration(state, m, frame.Xid) }
    else { Draw_Decoration_Audio(state, m, frame.Xid) }
    if state.DecorationAudioPopupClient == cl { Draw_Decoration_Audio_Popup(state, m) }
}

popup_slider_rect :: proc(state: ^State) -> c.Rect {
    r := state.DecorationAudioPopupRect
    icon_w := max(i32(16), r.H-8)
    x := 8+icon_w+4
    return {X = x, Y = 4, W = max(i32(1), r.W-x-8), H = max(i32(1), r.H-8)}
}

Decoration_Audio_Popup_Client :: proc(state: ^State, xid: u32) -> ^c.Client {
    if state != nil && xid != 0 && xid == state.DecorationAudioPopup { return state.DecorationAudioPopupClient }
    return nil
}

ensure_decoration_audio_popup :: proc(state: ^State, m: ^c.Manager) -> bool {
    if state.DecorationAudioPopup != 0 { return true }
    xid := x11.xcb_generate_id(state.Conn)
    mask := x11.EVENT_MASK_EXPOSURE | x11.EVENT_MASK_BUTTON_PRESS |
        x11.EVENT_MASK_BUTTON_RELEASE | x11.EVENT_MASK_POINTER_MOTION
    vals := [3]u32{m.Cfg.Decoration.InactiveBackground, 1, mask}
    cookie := x11.xcb_create_window_checked(
        state.Conn, 0, xid, state.Root, 0, 0, 1, 1, 0,
        x11.WINDOW_CLASS_INPUT_OUTPUT, 0,
        x11.CW_BACK_PIXEL | x11.CW_OVERRIDE_REDIRECT | x11.CW_EVENT_MASK, &vals[0],
    )
    if err := x11.xcb_request_check(state.Conn, cookie); err != nil {
        x11.free_libc(err)
        return false
    }
    state.DecorationAudioPopup = xid
    return true
}

Show_Decoration_Audio_Popup :: proc(state: ^State, m: ^c.Manager, cl: ^c.Client) {
    if state == nil || m == nil || cl == nil || !ensure_decoration_audio_popup(state, m) { return }
    frame := decoration_frame(state, cl.DecorationFrame)
    if frame == nil || !frame.AudioVisible { return }
    root_frame := c.Decoration_Layout_Frame_Rect(cl.Geom, m.Cfg.BorderWidth)
    layout := c.Decoration_Audio_Layout_For(root_frame.W, root_frame.H, m.Cfg.Decoration, true)
    if layout.Mode != .Compact { return }
    popup_h := max(i32(24), m.Cfg.Decoration.TitlebarHeight+8)
    popup_w := max(i32(70), m.Cfg.Decoration.AudioSliderWidth*m.Cfg.Decoration.TitlebarHeight/20)+popup_h+12
    popup_x := max(i32(0), root_frame.X+layout.Speaker.X+layout.Speaker.W-popup_w)
    popup_y := max(i32(0), root_frame.Y+layout.Speaker.Y+layout.Speaker.H)
    state.DecorationAudioPopupRect = {X=popup_x, Y=popup_y, W=popup_w, H=popup_h}
    state.DecorationAudioPopupClient = cl
    values := [5]u32{u32(popup_x), u32(popup_y), u32(popup_w), u32(popup_h), x11.STACK_MODE_ABOVE}
    x11.xcb_configure_window(state.Conn, state.DecorationAudioPopup,
        x11.CW_X | x11.CW_Y | x11.CW_WIDTH | x11.CW_HEIGHT | x11.CW_STACK_MODE, &values[0])
    x11.xcb_map_window(state.Conn, state.DecorationAudioPopup)
    Draw_Decoration_Audio_Popup(state, m)
}

Hide_Decoration_Audio_Popup :: proc(state: ^State) {
    if state == nil || state.DecorationAudioPopupClient == nil { return }
    if state.Conn != nil && state.DecorationAudioPopup != 0 { x11.xcb_unmap_window(state.Conn, state.DecorationAudioPopup) }
    state.DecorationAudioPopupClient = nil
    state.DecorationAudioPopupRect = {}
}

Draw_Decoration_Audio_Popup :: proc(state: ^State, m: ^c.Manager) {
    cl := state.DecorationAudioPopupClient
    frame := decoration_frame(state, cl.DecorationFrame) if cl != nil else nil
    if frame == nil || state.DecorationAudioPopup == 0 { return }
    colors := c.Resolve_Decoration_Colors(m.Cfg.Decoration, m.Cfg.FocusedBorder, m.Cfg.UnfocusedBorder, m.Focused == cl)
    r := state.DecorationAudioPopupRect
    vals := [2]u32{colors.Background, colors.Background}
    x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &vals[0])
    bg := x11.Rectangle{x=0, y=0, width=u16(r.W), height=u16(r.H)}
    x11.xcb_poly_fill_rectangle(state.Conn, state.DecorationAudioPopup, state.TabGC, 1, &bg)
    slider := popup_slider_rect(state)
    speaker := c.Rect{X=8, Y=4, W=max(i32(16), r.H-8), H=max(i32(1), r.H-8)}
    layout := c.Decoration_Audio_Layout{Mode=.Inline_No_Percentage, Bounds={X=0,Y=0,W=r.W,H=r.H}, Speaker=speaker, Slider=slider}
    draw_audio_widget(state, state.DecorationAudioPopup, frame, layout, colors.Foreground, colors.Background)
}

Decoration_Audio_Popup_Hit :: proc(state: ^State, x, y: i32) -> c.Decoration_Hit {
    if state == nil || state.DecorationAudioPopupClient == nil { return .None }
    r := state.DecorationAudioPopupRect
    speaker := c.Rect{X=8, Y=4, W=max(i32(16), r.H-8), H=max(i32(1), r.H-8)}
    if x >= speaker.X && y >= speaker.Y && x < speaker.X+speaker.W && y < speaker.Y+speaker.H { return .Audio_Mute }
    slider := popup_slider_rect(state)
    if x >= slider.X && y >= slider.Y && x < slider.X+slider.W && y < slider.Y+slider.H { return .Audio_Slider }
    return .None
}

Decoration_Audio_Hit :: proc(state: ^State, m: ^c.Manager, xid: u32, x, y: i32) -> c.Decoration_Hit {
    frame := decoration_frame(state, xid)
    if frame == nil || frame.Client == nil { return .None }
    rect := c.Decoration_Layout_Frame_Rect(frame.Client.Geom, m.Cfg.BorderWidth)
    return c.Decoration_Hit_Test(rect.W, rect.H, x, y, m.Cfg.Decoration, frame.AudioVisible)
}

Decoration_Audio_Value_At :: proc(state: ^State, m: ^c.Manager, xid: u32, x: i32) -> (u32, bool) {
    slider: c.Rect
    if xid == state.DecorationAudioPopup && state.DecorationAudioPopupClient != nil {
        slider = popup_slider_rect(state)
    } else if frame := decoration_frame(state, xid); frame != nil && frame.Client != nil {
        rect := c.Decoration_Layout_Frame_Rect(frame.Client.Geom, m.Cfg.BorderWidth)
        slider = c.Decoration_Audio_Layout_For(rect.W, rect.H, m.Cfg.Decoration, frame.AudioVisible).Slider
    }
    if slider.W <= 0 { return 0, false }
    return c.Decoration_Audio_Volume_At(slider, x), true
}

Draw_Decoration :: proc(state: ^State, m: ^c.Manager, xid: u32) {
    decoration := decoration_frame(state, xid)
    if decoration == nil { return }
    cl := decoration.Client
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
        x11.xcb_change_gc(state.Conn, state.TabGC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &text_vals[0])
    }
    if cfg.ShowTitle {
        audio_layout := c.Decoration_Audio_Layout_For(w, h, cfg, decoration.AudioVisible)
        title_right := w - 3*button_w - b
        if audio_layout.Mode != .Hidden { title_right = audio_layout.Bounds.X }
        max_chars := max(i32(0), (title_right - title_x - 7)/6)
        buf: [255]u8
        title_len := decoration_ascii_title(cl, buf[:])
        n := min(title_len, int(max_chars))
        if n < title_len && n >= 3 { buf[n-3], buf[n-2], buf[n-1] = '.', '.', '.' }
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
    audio_layout := c.Decoration_Audio_Layout_For(w, h, cfg, decoration.AudioVisible)
    draw_audio_widget(state, xid, decoration, audio_layout, colors.Foreground, colors.Background)
    if state.DecorationAudioPopupClient == cl {
        if audio_layout.Mode == .Compact { Show_Decoration_Audio_Popup(state, m, cl) }
        else { Hide_Decoration_Audio_Popup(state) }
    }
}

Draw_All_Decorations :: proc(state: ^State, m: ^c.Manager) {
    if state == nil { return }
    for frame in state.Decorations { Draw_Decoration(state, m, frame.Xid) }
}

Shutdown_Decorations :: proc(state: ^State) {
    if state == nil { return }
    if state.Conn != nil {
        if state.DecorationAudioPopup != 0 { x11.xcb_destroy_window(state.Conn, state.DecorationAudioPopup) }
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
    state.DecorationAudioPopup = 0
    state.DecorationAudioPopupClient = nil
    state.DecorationAudioPopupRect = {}
}
