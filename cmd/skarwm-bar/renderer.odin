package main

import x11 "../../src/x11"

import "core:fmt"

BAR_PAD :: i32(6)
BLOCK_GAP :: i32(4)

renderer_init :: proc(state: ^State) {
    state.Font = x11.xcb_generate_id(state.Conn)
    font_name := "fixed"
    font_cookie := x11.xcb_open_font_checked(
        state.Conn, state.Font, u16(len(font_name)), cstring(raw_data(font_name)),
    )
    if error := x11.xcb_request_check(state.Conn, font_cookie); error != nil {
        fmt.eprintfln("skarwm-bar: cannot open X core font (error %d)", (^x11.X_Error)(error).error_code)
        x11.free_libc(error)
        state.Font = 0
        return
    }
    state.GC = x11.xcb_generate_id(state.Conn)
    values := [3]u32{state.Config.Foreground, state.Config.Background, state.Font}
    gc_cookie := x11.xcb_create_gc_checked(
        state.Conn, state.GC, state.Root,
        x11.GC_FOREGROUND | x11.GC_BACKGROUND | x11.GC_FONT, &values[0],
    )
    if error := x11.xcb_request_check(state.Conn, gc_cookie); error != nil {
        fmt.eprintfln("skarwm-bar: cannot create text GC (error %d)", (^x11.X_Error)(error).error_code)
        x11.free_libc(error)
        state.GC = 0
    }
}

renderer_shutdown :: proc(state: ^State) {
    if state.Conn == nil { return }
    if state.GC != 0 { x11.xcb_free_gc(state.Conn, state.GC) }
    if state.Font != 0 { x11.xcb_close_font(state.Conn, state.Font) }
    state.GC, state.Font = 0, 0
}

fill_rect :: proc(state: ^State, window: u32, x, y, width, height: i32, colour: u32) {
    if width <= 0 || height <= 0 { return }
    value := colour
    x11.xcb_change_gc(state.Conn, state.GC, x11.GC_FOREGROUND, &value)
    rect := x11.Rectangle{x = i16(x), y = i16(y), width = u16(width), height = u16(height)}
    x11.xcb_poly_fill_rectangle(state.Conn, window, state.GC, 1, &rect)
}

draw_text :: proc(state: ^State, window: u32, x, y: i32, label: string, foreground, background: u32) {
    count := min(len(label), 255)
    if count <= 0 { return }
    values := [2]u32{foreground, background}
    x11.xcb_change_gc(state.Conn, state.GC, x11.GC_FOREGROUND | x11.GC_BACKGROUND, &values[0])
    x11.xcb_image_text_8(
        state.Conn, u8(count), window, state.GC, i16(x), i16(y),
        cstring(raw_data(label)),
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
    if state.GC == 0 || window == nil || window.Xid == 0 { return }
    clear(&window.Hits)
    fill_rect(state, window.Xid, 0, 0, window.Geom.W, window.Geom.H, state.Config.Background)
    center_width := alignment_width(state, window, .Center)
    right_width := alignment_width(state, window, .Right)
    draw_alignment(state, window, .Left, BAR_PAD)
    draw_alignment(state, window, .Center, max(BAR_PAD, (window.Geom.W - center_width) / 2))
    draw_alignment(state, window, .Right, max(BAR_PAD, window.Geom.W - BAR_PAD - right_width))
    x11.xcb_flush(state.Conn)
}

draw_all_bars :: proc(state: ^State) {
    for &window in state.Windows { draw_bar(state, &window) }
}
