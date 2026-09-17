package main

// Minimal Xlib/Xft surface used only by the standalone bar. The WM itself
// remains XCB-only; Xft gives the bar fontconfig family/size/weight matching,
// UTF-8 glyphs, and exact text extents without introducing a GUI toolkit.

import c "core:c"

X_Display :: struct {}
X_Visual :: struct {}
X_GC :: struct {}
Xft_Draw :: struct {}
Fc_Char_Set :: struct {}
Fc_Pattern :: struct {}
X_Colormap :: c.ulong
X_Drawable :: c.ulong
X_Pixmap :: c.ulong

Xft_Font :: struct {
    ascent, descent, height, max_advance_width: c.int,
    charset: ^Fc_Char_Set,
    pattern: ^Fc_Pattern,
}

X_Render_Color :: struct {
    red, green, blue, alpha: u16,
}

Xft_Color :: struct {
    pixel: c.ulong,
    color: X_Render_Color,
}

X_Glyph_Info :: struct {
    width, height: u16,
    x, y, x_off, y_off: i16,
}

foreign import xlib "system:X11"
foreign import xft "system:Xft"

@(default_calling_convention = "c")
foreign xlib {
    XOpenDisplay :: proc(name: cstring) -> ^X_Display ---
    XCloseDisplay :: proc(display: ^X_Display) -> c.int ---
    XDefaultScreen :: proc(display: ^X_Display) -> c.int ---
    XDefaultVisual :: proc(display: ^X_Display, screen: c.int) -> ^X_Visual ---
    XDefaultColormap :: proc(display: ^X_Display, screen: c.int) -> X_Colormap ---
    XDefaultDepth :: proc(display: ^X_Display, screen: c.int) -> c.int ---
    XCreateGC :: proc(display: ^X_Display, drawable: X_Drawable, mask: c.ulong, values: rawptr) -> ^X_GC ---
    XFreeGC :: proc(display: ^X_Display, gc: ^X_GC) -> c.int ---
    XSetForeground :: proc(display: ^X_Display, gc: ^X_GC, foreground: c.ulong) -> c.int ---
    XFillRectangle :: proc(
        display: ^X_Display, drawable: X_Drawable, gc: ^X_GC,
        x, y: c.int, width, height: c.uint,
    ) -> c.int ---
    XCreatePixmap :: proc(
        display: ^X_Display, drawable: X_Drawable, width, height: c.uint, depth: c.uint,
    ) -> X_Pixmap ---
    XFreePixmap :: proc(display: ^X_Display, pixmap: X_Pixmap) -> c.int ---
    XCopyArea :: proc(
        display: ^X_Display, source, destination: X_Drawable, gc: ^X_GC,
        source_x, source_y: c.int, width, height: c.uint, destination_x, destination_y: c.int,
    ) -> c.int ---
    XFlush :: proc(display: ^X_Display) -> c.int ---
}

@(default_calling_convention = "c")
foreign xft {
    XftFontOpenName :: proc(display: ^X_Display, screen: c.int, name: cstring) -> ^Xft_Font ---
    XftFontClose :: proc(display: ^X_Display, font: ^Xft_Font) ---
    XftDrawCreate :: proc(
        display: ^X_Display, drawable: X_Drawable, visual: ^X_Visual, colormap: X_Colormap,
    ) -> ^Xft_Draw ---
    XftDrawDestroy :: proc(draw: ^Xft_Draw) ---
    XftDrawStringUtf8 :: proc(
        draw: ^Xft_Draw, colour: ^Xft_Color, font: ^Xft_Font,
        x, y: c.int, text: [^]u8, count: c.int,
    ) ---
    XftTextExtentsUtf8 :: proc(
        display: ^X_Display, font: ^Xft_Font, text: [^]u8,
        count: c.int, extents: ^X_Glyph_Info,
    ) ---
}

xft_colour :: proc(rgb: u32) -> Xft_Color {
    red := u16((rgb >> 16) & 0xff)
    green := u16((rgb >> 8) & 0xff)
    blue := u16(rgb & 0xff)
    return Xft_Color{
        pixel = c.ulong(rgb),
        color = X_Render_Color{
            red = red * 257, green = green * 257, blue = blue * 257, alpha = 0xffff,
        },
    }
}
