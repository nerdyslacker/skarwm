package main

import x11 "../x11"

import c "core:c"
import "core:fmt"
import "core:strings"

BAR_PAD :: i32(6)
BLOCK_GAP :: i32(4)

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

draw_alignment :: proc(state: ^State, window: ^Bar_Window, alignment: Block_Alignment, start: i32) {
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
}

draw_bar :: proc(state: ^State, window: ^Bar_Window) {
    if state.GC == nil || window == nil || window.Xid == 0 || window.Canvas == 0 { return }
    clear(&window.Hits)
    fill_rect(
        state, X_Drawable(window.Canvas), 0, 0, window.Geom.W, window.Geom.H,
        state.Config.Background,
    )
    center_width := alignment_width(state, window, .Center)
    right_width := alignment_width(state, window, .Right)
    draw_alignment(state, window, .Left, BAR_PAD)
    draw_alignment(state, window, .Center, max(BAR_PAD, (window.Geom.W - center_width) / 2))
    draw_alignment(state, window, .Right, max(BAR_PAD, window.Geom.W - BAR_PAD - right_width))
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
