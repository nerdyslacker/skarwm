package main

// Static clickable blocks. Commands use the same detached shell launcher as
// WM key bindings, so a long-running launcher never stalls or zombifies the
// bar process.

import process "../process"

import "core:strings"

Button_Block_Data :: struct {
    Label, Command: string,
}

button_data :: proc(block: ^Block) -> ^Button_Block_Data {
    if block == nil || block.Kind != .Button || block.Data == nil { return nil }
    return (^Button_Block_Data)(block.Data)
}

append_button_block :: proc(
    state: ^State,
    alignment: Block_Alignment,
    label, command: string,
    foreground: u32 = 0, background: u32 = 0,
    foreground_set: bool = false, background_set: bool = false,
) {
    if label == "" || len(label) > 64 || command == "" || len(command) >= 1024 { return }
    data := new(Button_Block_Data)
    data.Label = strings.clone(label)
    data.Command = strings.clone(command)
    append(&state.Blocks, Block{
        Name = data.Label,
        Kind = .Button,
        Alignment = alignment,
        Ops = Block_Ops{
            Measure = button_measure,
            Draw = button_draw,
            Click = button_click,
            Destroy = button_destroy,
        },
        Data = data,
        Foreground = foreground, Background = background,
        ForegroundSet = foreground_set, BackgroundSet = background_set,
    })
}

button_measure :: proc(block: ^Block, state: ^State, window: ^Bar_Window) -> i32 {
    _ = window
    data := button_data(block)
    if data == nil { return 0 }
    return text_width(state, data.Label) + 16
}

button_draw :: proc(block: ^Block, state: ^State, window: ^Bar_Window, x: i32, block_index: int) {
    data := button_data(block)
    if data == nil { return }
    width := button_measure(block, state, window)
    wrapper_y := min(i32(3), max(i32(0), window.Geom.H / 4))
    fill_rect(
        state, X_Drawable(window.Canvas), x, wrapper_y, width, window.Geom.H - wrapper_y * 2,
        block_background(block, state),
    )
    draw_text_centered(
        state, window, x, wrapper_y, width, window.Geom.H - wrapper_y * 2,
        data.Label, block_foreground(block, state),
    )
    append(&window.Hits, Hitbox{
        X = x, Y = 0, W = width, H = window.Geom.H,
        BlockIndex = block_index,
    })
}

button_click :: proc(block: ^Block, state: ^State, window: ^Bar_Window, payload: int, button: u8) {
    _ = state
    _ = window
    _ = payload
    if button != 1 { return }
    if data := button_data(block); data != nil { process.Spawn(data.Command) }
}

button_destroy :: proc(block: ^Block, state: ^State) {
    _ = state
    data := button_data(block)
    if data == nil { return }
    if data.Label != "" { delete(data.Label) }
    if data.Command != "" { delete(data.Command) }
    free(data)
    block.Data = nil
}
