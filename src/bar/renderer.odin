package main

import x11 "../x11"
import core "../core"

import c "core:c"
import "core:fmt"
import "core:strings"

BAR_PAD :: i32(6)
BLOCK_GAP :: i32(4)
X_Z_PIXMAP :: c.int(2)

window_icon_load :: proc(state: ^State, xid: u32) -> Window_Icon {
    result: Window_Icon
    error: ^x11.Error
    reply := x11.xcb_get_property_reply(
        state.Conn,
        x11.xcb_get_property(
            state.Conn, 0, xid, atom(state, "_NET_WM_ICON"), atom(state, "CARDINAL"),
            0, u32(x11.PROPERTY_MAX_BYTES/4),
        ),
        &error,
    )
    if error != nil { x11.free_libc(error); return result }
    if reply == nil { return result }
    defer x11.free_libc(reply)
    if reply.type_ != atom(state, "CARDINAL") || reply.format != x11.ATOM_FORMAT_32 ||
       reply.bytes_after != 0 || reply.value_len < 3 ||
       u64(reply.value_len)*4 > x11.PROPERTY_MAX_BYTES {
        return result
    }
    value := x11.xcb_get_property_value(reply)
    if value == nil { return result }
    values := ([^]u32)(value)[:int(reply.value_len)]
    choice, found := core.Select_Net_Wm_Icon(values, WINDOW_ICON_SIZE)
    if !found { return result }

    width, height := WINDOW_ICON_SIZE, WINDOW_ICON_SIZE
    if choice.Width > choice.Height {
        height = max(1, choice.Height*WINDOW_ICON_SIZE/choice.Width)
    } else if choice.Height > choice.Width {
        width = max(1, choice.Width*WINDOW_ICON_SIZE/choice.Height)
    }
    for y in 0 ..< height {
        source_y := y*choice.Height/height
        for x in 0 ..< width {
            source_x := x*choice.Width/width
            result.Pixels[y*WINDOW_ICON_SIZE+x] =
                values[choice.PixelOffset+source_y*choice.Width+source_x]
        }
    }
    result.W, result.H, result.Available = i32(width), i32(height), true
    return result
}

window_icons_sync :: proc(state: ^State) {
    for client in state.WindowsState {
        if _, cached := state.WindowIcons[client.Id]; cached { continue }
        state.WindowIcons[client.Id] = window_icon_load(state, client.Id)
        mask := u32(x11.EVENT_MASK_PROPERTY_CHANGE)
        cookie := x11.xcb_change_window_attributes_checked(
            state.Conn, client.Id, x11.CW_EVENT_MASK, &mask,
        )
        if error := x11.xcb_request_check(state.Conn, cookie); error != nil {
            x11.free_libc(error)
        }
    }
    for xid in state.WindowIcons {
        if window_state_by_xid(state, xid) == nil { delete_key(&state.WindowIcons, xid) }
    }
}

window_icon_available :: proc(state: ^State, xid: u32) -> bool {
    icon, found := state.WindowIcons[xid]
    return found && icon.Available
}

draw_window_icon :: proc(
    state: ^State, window: ^Bar_Window, xid: u32, x, y, size: i32,
    background: u32, opacity: u32 = 255,
) -> bool {
    icon, found := state.WindowIcons[xid]
    if !found || !icon.Available || size <= 0 || state.Display == nil || state.GC == nil {
        return false
    }
    width, height := size, size
    if icon.W > icon.H {
        height = max(1, icon.H*size/icon.W)
    } else if icon.H > icon.W {
        width = max(1, icon.W*size/icon.H)
    }
    bytes := x_calloc(c.size_t(width*height), c.size_t(4))
    if bytes == nil { return false }
    image := XCreateImage(
        state.Display, state.Visual, c.uint(XDefaultDepth(state.Display, state.ScreenNumber)),
        X_Z_PIXMAP, 0, bytes, c.uint(width), c.uint(height), 32, 0,
    )
    if image == nil { x_free(bytes); return false }
    defer XDestroyImage(image)
    for destination_y in 0 ..< height {
        source_y := destination_y*icon.H/height
        for destination_x in 0 ..< width {
            source_x := destination_x*icon.W/width
            pixel := icon.Pixels[source_y*WINDOW_ICON_SIZE+source_x]
            XPutPixel(
                image, destination_x, destination_y,
                c.ulong(core.Blend_Argb_Over_Rgb(pixel, background, opacity)),
            )
        }
    }
    XPutImage(
        state.Display, X_Drawable(window.Canvas), state.GC, image, 0, 0,
        x+(size-width)/2, y+(size-height)/2, c.uint(width), c.uint(height),
    )
    return true
}

renderer_init :: proc(state: ^State) {
    state.Display = XOpenDisplay(nil)
    if state.Display == nil {
        fmt.eprintln("skarwm-bar: cannot open X display for Xft")
        return
    }
    screen := XDefaultScreen(state.Display)
    state.Visual = XDefaultVisual(state.Display, screen)
    state.Colormap = XDefaultColormap(state.Display, screen)
    renderer_load_fonts(state)
    if state.NormalFont == nil { return }

    state.GC = XCreateGC(state.Display, X_Drawable(state.Root), 0, nil)
    if state.GC == nil { fmt.eprintln("skarwm-bar: cannot create drawing GC") }
}

renderer_shutdown :: proc(state: ^State) {
    tooltip_shutdown(state)
    if state.Display != nil {
        if state.GC != nil { XFreeGC(state.Display, state.GC) }
        if state.BoldFont != nil && state.BoldFont != state.NormalFont {
            XftFontClose(state.Display, state.BoldFont)
        }
        if state.NormalFont != nil { XftFontClose(state.Display, state.NormalFont) }
        XCloseDisplay(state.Display)
    }
    state.GC = nil
    state.Display, state.Visual = nil, nil
    state.NormalFont, state.BoldFont = nil, nil
}

tooltip_show :: proc(state: ^State, mouse_x, mouse_y: i32, label: string) {
    if state.Display == nil || label == "" { return }
    lines := strings.split(label, "\n")
    defer delete(lines)
    max_line_width := i32(0)
    for line in lines { max_line_width = max(max_line_width, text_width(state, line)) }
    width := min(max(i32(1), max_line_width + 16), max(i32(1), state.RootW - 8))
    height := max(i32(1), i32(len(lines)) * i32(state.NormalFont.height) + 8)
    x := clamp(mouse_x - width / 2, i32(4), max(i32(4), state.RootW - width - 4))
    y := mouse_y - height - 6
    if y < 0 { y = mouse_y + 16 }
    if state.TooltipXid == 0 {
        xid := x11.xcb_generate_id(state.Conn)
        values := [2]u32{state.Config.Background, 1}
        cookie := x11.xcb_create_window_checked(state.Conn, 0, xid, state.Root,
            i16(x), i16(y), u16(width), u16(height), 0, x11.WINDOW_CLASS_INPUT_OUTPUT, 0,
            x11.CW_BACK_PIXEL | x11.CW_OVERRIDE_REDIRECT, &values[0])
        if err := x11.xcb_request_check(state.Conn, cookie); err != nil { x11.free_libc(err); return }
        state.TooltipXid = xid
        state.TooltipDraw = XftDrawCreate(state.Display, X_Drawable(xid), state.Visual, state.Colormap)
    } else {
        values := [4]u32{u32(x), u32(y), u32(width), u32(height)}
        x11.xcb_configure_window(state.Conn, state.TooltipXid,
            x11.CW_X | x11.CW_Y | x11.CW_WIDTH | x11.CW_HEIGHT, &values[0])
    }
    if state.TooltipDraw == nil { return }
    // This is a second X connection: commit XCB window lifetime/geometry
    // before issuing Xlib drawing requests against the tooltip drawable.
    x11.xcb_flush(state.Conn)
    fill_rect(state, X_Drawable(state.TooltipXid), 0, 0, width, height, state.Config.Background)
    colour := xft_colour(state.Config.Foreground)
    baseline := i32(state.NormalFont.ascent) + 4
    for line in lines {
        XftDrawStringUtf8(state.TooltipDraw, &colour, state.NormalFont, 8, baseline,
            ([^]u8)(raw_data(line)), i32(len(line)))
        baseline += i32(state.NormalFont.height)
    }
    x11.xcb_map_window(state.Conn, state.TooltipXid)
    stack := x11.STACK_MODE_ABOVE
    x11.xcb_configure_window(state.Conn, state.TooltipXid, x11.CW_STACK_MODE, &stack)
    XFlush(state.Display)
    x11.xcb_flush(state.Conn)
}

tooltip_hide :: proc(state: ^State) {
    if state.TooltipXid != 0 { x11.xcb_unmap_window(state.Conn, state.TooltipXid); x11.xcb_flush(state.Conn) }
}

tooltip_shutdown :: proc(state: ^State) {
    if state.TooltipDraw != nil { XftDrawDestroy(state.TooltipDraw) }
    if state.Conn != nil && state.TooltipXid != 0 { x11.xcb_destroy_window(state.Conn, state.TooltipXid) }
    state.TooltipXid, state.TooltipDraw = 0, nil
}

font_weight_name :: proc(weight: Bar_Font_Weight) -> string {
    switch weight {
    case .Normal: return "regular"
    case .Medium: return "medium"
    case .Bold: return "bold"
    }
    return "regular"
}

renderer_load_fonts :: proc(state: ^State) -> bool {
    if state.Display == nil { return false }
    if state.BoldFont != nil && state.BoldFont != state.NormalFont {
        XftFontClose(state.Display, state.BoldFont)
    }
    if state.NormalFont != nil { XftFontClose(state.Display, state.NormalFont) }
    state.NormalFont, state.BoldFont = nil, nil

    family := config_font(&state.Config)
    normal_name := fmt.aprintf(
        "%s:size=%d:weight=%s", family, state.Config.FontSize,
        font_weight_name(state.Config.FontWeight),
    )
    bold_name := fmt.aprintf("%s:size=%d:weight=bold", family, state.Config.FontSize)
    normal_c := make([]byte, len(normal_name) + 1)
    bold_c := make([]byte, len(bold_name) + 1)
    copy(normal_c, transmute([]u8)normal_name)
    copy(bold_c, transmute([]u8)bold_name)
    state.NormalFont = XftFontOpenName(state.Display, state.ScreenNumber, cstring(&normal_c[0]))
    state.BoldFont = XftFontOpenName(state.Display, state.ScreenNumber, cstring(&bold_c[0]))
    delete(normal_c)
    delete(bold_c)
    delete(normal_name)
    delete(bold_name)
    if state.NormalFont == nil {
        fmt.eprintfln("skarwm-bar: cannot load font %q", family)
        return false
    }
    if state.BoldFont == nil { state.BoldFont = state.NormalFont }
    return true
}

fill_rect :: proc(state: ^State, drawable: X_Drawable, x, y, width, height: i32, colour: u32) {
    if width <= 0 || height <= 0 { return }
    XSetForeground(state.Display, state.GC, c.ulong(colour))
    XFillRectangle(
        state.Display, drawable, state.GC, x, y, c.uint(width), c.uint(height),
    )
}

text_font :: proc(state: ^State, bold: bool) -> ^Xft_Font {
    if bold && state.BoldFont != nil { return state.BoldFont }
    return state.NormalFont
}

text_width :: proc(state: ^State, label: string, bold: bool = false) -> i32 {
    font := text_font(state, bold)
    if state.Display == nil || font == nil || label == "" { return 0 }
    extents: X_Glyph_Info
    XftTextExtentsUtf8(
        state.Display, font, ([^]u8)(raw_data(label)), i32(len(label)), &extents,
    )
    return max(i32(0), i32(extents.x_off))
}

text_baseline :: proc(state: ^State, height: i32, bold: bool = false) -> i32 {
    font := text_font(state, bold)
    if font == nil { return height / 2 }
    return (height - i32(font.height)) / 2 + i32(font.ascent)
}

draw_text :: proc(
    state: ^State, window: ^Bar_Window, x: i32, label: string,
    foreground: u32, bold: bool = false,
) {
    _ = window.Xid
    font := text_font(state, bold)
    if window.TextDraw == nil || font == nil || label == "" { return }
    colour := xft_colour(foreground)
    XftDrawStringUtf8(
        window.TextDraw, &colour, font, x, text_baseline(state, window.Geom.H, bold),
        ([^]u8)(raw_data(label)), i32(len(label)),
    )
}

// Center by rendered ink bounds rather than only advance width and baseline.
// Icon fonts often have asymmetric bearings that otherwise look off-center.
draw_text_centered :: proc(
    state: ^State, window: ^Bar_Window, x, y, width, height: i32,
    label: string, foreground: u32, bold: bool = false,
) {
    font := text_font(state, bold)
    if window.TextDraw == nil || font == nil || label == "" { return }
    extents: X_Glyph_Info
    XftTextExtentsUtf8(
        state.Display, font, ([^]u8)(raw_data(label)), i32(len(label)), &extents,
    )
    draw_x := x + (width - i32(extents.width)) / 2 - i32(extents.x)
    draw_y := y + (height - i32(extents.height)) / 2 + i32(extents.y)
    colour := xft_colour(foreground)
    XftDrawStringUtf8(
        window.TextDraw, &colour, font, draw_x, draw_y,
        ([^]u8)(raw_data(label)), i32(len(label)),
    )
}

alignment_width :: proc(state: ^State, window: ^Bar_Window, alignment: Block_Alignment) -> i32 {
    result := i32(0)
    count := 0
    for &block in state.Blocks {
        if block.Alignment != alignment || block.Ops.Measure == nil { continue }
        width := block.Ops.Measure(&block, state, window)
        if width <= 0 { continue }
        if count > 0 { result += BLOCK_GAP }
        result += width
        count += 1
    }
    return result
}

draw_alignment :: proc(state: ^State, window: ^Bar_Window, alignment: Block_Alignment, start: i32) -> i32 {
    x := start
    first := true
    for &block, index in state.Blocks {
        if block.Alignment != alignment || block.Ops.Measure == nil || block.Ops.Draw == nil { continue }
        width := block.Ops.Measure(&block, state, window)
        if width <= 0 { continue }
        if !first { x += BLOCK_GAP }
        block.Ops.Draw(&block, state, window, x, index)
        x += width
        first = false
    }
    return x
}

draw_bar :: proc(state: ^State, window: ^Bar_Window) {
    if state.GC == nil || window == nil || window.Xid == 0 || window.Canvas == 0 { return }
    window_animation_sync(state, window)
    clear(&window.Hits)
    fill_rect(
        state, X_Drawable(window.Canvas), 0, 0, window.Geom.W, window.Geom.H,
        state.Config.Background,
    )
    center_width := alignment_width(state, window, .Center)
    right_width := alignment_width(state, window, .Right)
    right_start := max(BAR_PAD, window.Geom.W-BAR_PAD-right_width)
    left_end := draw_alignment(state, window, .Left, BAR_PAD)
    center_min := left_end
    if left_end > BAR_PAD && center_width > 0 { center_min += BLOCK_GAP }
    center_max := max(BAR_PAD, right_start-center_width-(right_width > 0 ? BLOCK_GAP : 0))
    center_start := clamp((window.Geom.W-center_width)/2, center_min, max(center_min, center_max))
    _ = draw_alignment(state, window, .Center, center_start)
    _ = draw_alignment(state, window, .Right, right_start)
    XCopyArea(
        state.Display, X_Drawable(window.Canvas), X_Drawable(window.Xid), state.GC,
        0, 0, c.uint(window.Geom.W), c.uint(window.Geom.H), 0, 0,
    )
    XFlush(state.Display)
    x11.xcb_flush(state.Conn)
}

draw_all_bars :: proc(state: ^State) {
    for &window in state.Windows { draw_bar(state, &window) }
}
