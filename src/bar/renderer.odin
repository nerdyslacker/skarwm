package main

import x11 "../x11"

import c "core:c"
import "core:fmt"

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
