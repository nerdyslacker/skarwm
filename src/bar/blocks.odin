package main

import x11 "../x11"

import "core:fmt"
import "core:strconv"
import "core:strings"

Block_Alignment :: enum u8 { Left, Center, Right }
Block_Kind :: enum u8 { Workspaces, Script, Systray, Button, Audio, Bluetooth, Network }

Block_Measure_Proc :: proc(block: ^Block, state: ^State, window: ^Bar_Window) -> i32
Block_Draw_Proc :: proc(block: ^Block, state: ^State, window: ^Bar_Window, x: i32, block_index: int)
Block_Click_Proc :: proc(block: ^Block, state: ^State, window: ^Bar_Window, payload: int, button: u8)
Block_Destroy_Proc :: proc(block: ^Block, state: ^State)

Block_Ops :: struct {
    Measure: Block_Measure_Proc,
    Draw: Block_Draw_Proc,
    Click: Block_Click_Proc,
    Destroy: Block_Destroy_Proc,
}

Block :: struct {
    Name: string,
    Kind: Block_Kind,
    Alignment: Block_Alignment,
    Ops: Block_Ops,
    Data: rawptr,
    Foreground, Background: u32,
    ForegroundSet, BackgroundSet: bool,
}

Hitbox :: struct {
    X, Y, W, H: i32,
    BlockIndex: int,
    Payload: int,
}

blocks_init :: proc(state: ^State) {
    state.Blocks = make([dynamic]Block, 0, 4)
    if state.Config.Managed && blocks_read_managed(state) { return }
    append_workspace_block(state, .Left)
}

block_foreground :: proc(block: ^Block, state: ^State) -> u32 {
    if block != nil && block.ForegroundSet { return block.Foreground }
    return state.Config.BlockForeground
}

block_background :: proc(block: ^Block, state: ^State) -> u32 {
    if block != nil && block.BackgroundSet { return block.Background }
    return state.Config.BlockBackground
}

append_workspace_block :: proc(
    state: ^State, alignment: Block_Alignment,
    foreground: u32 = 0, background: u32 = 0,
    foreground_set: bool = false, background_set: bool = false,
) {
    append(&state.Blocks, Block{
        Name = "workspaces",
        Kind = .Workspaces,
        Alignment = alignment,
        Ops = Block_Ops{
            Measure = workspace_measure,
            Draw = workspace_draw,
            Click = workspace_click,
        },
        Foreground = foreground, Background = background,
        ForegroundSet = foreground_set, BackgroundSet = background_set,
    })
}

parse_block_alignment :: proc(value: string) -> (Block_Alignment, bool) {
    parsed, ok := strconv.parse_i64(value, 10)
    if !ok || parsed < 0 || parsed > 2 { return {}, false }
    return Block_Alignment(parsed), true
}

split_block_fields :: proc(line: string) -> [dynamic]string {
    fields := make([dynamic]string, 0, 6)
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    escaped := false
    for byte in transmute([]u8)line {
        if escaped {
            switch byte {
            case 't': strings.write_byte(&builder, '\t')
            case 'n': strings.write_byte(&builder, '\n')
            case 'r': strings.write_byte(&builder, '\r')
            case: strings.write_byte(&builder, byte)
            }
            escaped = false
        } else if byte == '\\' {
            escaped = true
        } else if byte == '\t' {
            append(&fields, strings.clone(strings.to_string(builder)))
            strings.builder_reset(&builder)
        } else {
            strings.write_byte(&builder, byte)
        }
    }
    if escaped { strings.write_byte(&builder, '\\') }
    append(&fields, strings.clone(strings.to_string(builder)))
    return fields
}

free_block_fields :: proc(fields: ^[dynamic]string) {
    for field in fields { delete(field) }
    delete(fields^)
}

parse_managed_colours :: proc(fields: []string, start: int) -> (
    foreground, background: u32, foreground_set, background_set, ok: bool,
) {
    if start < 0 || start + 3 >= len(fields) { return }
    foreground_flag, fg_flag_ok := strconv.parse_i64(fields[start], 10)
    foreground_value, fg_ok := strconv.parse_i64(fields[start + 1], 10)
    background_flag, bg_flag_ok := strconv.parse_i64(fields[start + 2], 10)
    background_value, bg_ok := strconv.parse_i64(fields[start + 3], 10)
    if !fg_flag_ok || !fg_ok || !bg_flag_ok || !bg_ok ||
       (foreground_flag != 0 && foreground_flag != 1) ||
       (background_flag != 0 && background_flag != 1) ||
       foreground_value < 0 || foreground_value > 0xffffff ||
       background_value < 0 || background_value > 0xffffff {
        return
    }
    return u32(foreground_value), u32(background_value),
        foreground_flag == 1, background_flag == 1, true
}

blocks_read_managed :: proc(state: ^State) -> bool {
    payload, ok := x11.get_text(state.Conn, state.Root, atom(state, BAR_BLOCKS_ATOM))
    if !ok { return false }
    defer delete(payload)
    lines := strings.split(payload, "\n")
    defer delete(lines)
    if len(lines) == 0 || (lines[0] != "version=1" && lines[0] != "version=2") { return false }
    version_two := lines[0] == "version=2"

    parsed_any := false
    for line in lines[1:] {
        if line == "" { continue }
        fields := split_block_fields(line)
        if !version_two && len(fields) == 2 && fields[0] == "workspaces" {
            if alignment, valid := parse_block_alignment(fields[1]); valid {
                append_workspace_block(state, alignment)
                parsed_any = true
            }
        } else if version_two && len(fields) == 6 && fields[0] == "workspaces" {
            alignment, alignment_ok := parse_block_alignment(fields[1])
            foreground, background, foreground_set, background_set, colours_ok :=
                parse_managed_colours(fields[:], 2)
            if alignment_ok && colours_ok {
                append_workspace_block(state, alignment, foreground, background,
                    foreground_set, background_set)
                parsed_any = true
            }
        } else if !version_two && len(fields) == 6 && fields[0] == "script" {
            alignment, alignment_ok := parse_block_alignment(fields[1])
            interval, interval_ok := strconv.parse_i64(fields[2], 10)
            timeout, timeout_ok := strconv.parse_i64(fields[3], 10)
            if alignment_ok && interval_ok && timeout_ok &&
               interval >= 1000 && interval <= 86400000 &&
               timeout >= 1000 && timeout <= 60000 && len(fields[5]) < 1024 {
                append_script_block(
                    state, alignment, fields[4], fields[5],
                    i32(interval), i32(timeout),
                )
                parsed_any = true
            }
        } else if version_two && len(fields) == 10 && fields[0] == "script" {
            alignment, alignment_ok := parse_block_alignment(fields[1])
            interval, interval_ok := strconv.parse_i64(fields[2], 10)
            timeout, timeout_ok := strconv.parse_i64(fields[3], 10)
            foreground, background, foreground_set, background_set, colours_ok :=
                parse_managed_colours(fields[:], 4)
            if alignment_ok && interval_ok && timeout_ok && colours_ok &&
               interval >= 1000 && interval <= 86400000 &&
               timeout >= 1000 && timeout <= 60000 && len(fields[9]) < 1024 {
                append_script_block(state, alignment, fields[8], fields[9],
                    i32(interval), i32(timeout), foreground, background,
                    foreground_set, background_set)
                parsed_any = true
            }
        } else if !version_two && len(fields) == 2 && fields[0] == "systray" {
            if alignment, valid := parse_block_alignment(fields[1]); valid {
                append_systray_block(state, alignment)
                parsed_any = true
            }
        } else if version_two && len(fields) == 6 && fields[0] == "systray" {
            alignment, alignment_ok := parse_block_alignment(fields[1])
            foreground, background, foreground_set, background_set, colours_ok :=
                parse_managed_colours(fields[:], 2)
            if alignment_ok && colours_ok {
                append_systray_block(state, alignment, foreground, background,
                    foreground_set, background_set)
                parsed_any = true
            }
        } else if !version_two && len(fields) == 4 && fields[0] == "button" {
            if alignment, valid := parse_block_alignment(fields[1]); valid &&
               fields[2] != "" && fields[3] != "" &&
               len(fields[2]) <= 64 && len(fields[3]) < 1024 {
                append_button_block(state, alignment, fields[2], fields[3])
                parsed_any = true
            }
        } else if version_two && len(fields) == 8 && fields[0] == "button" {
            alignment, alignment_ok := parse_block_alignment(fields[1])
            foreground, background, foreground_set, background_set, colours_ok :=
                parse_managed_colours(fields[:], 2)
            if alignment_ok && colours_ok && fields[6] != "" && fields[7] != "" &&
               len(fields[6]) <= 64 && len(fields[7]) < 1024 {
                append_button_block(state, alignment, fields[6], fields[7],
                    foreground, background, foreground_set, background_set)
                parsed_any = true
            }
        } else if version_two && (len(fields) == 7 || len(fields) == 8) &&
                  (fields[0] == "audio" || fields[0] == "bluetooth" || fields[0] == "network") {
            alignment, alignment_ok := parse_block_alignment(fields[1])
            foreground, background, foreground_set, background_set, colours_ok :=
                parse_managed_colours(fields[:], 2)
            click_command := ""
            if len(fields) == 8 { click_command = fields[7] }
            if alignment_ok && colours_ok && fields[6] != "" && len(fields[6]) <= 64 &&
               len(click_command) < 1024 {
                if fields[0] == "audio" {
                    append_audio_block(state, alignment, fields[6], foreground, background,
                        foreground_set, background_set, click_command)
                } else {
                    kind := Block_Kind.Bluetooth
                    if fields[0] == "network" { kind = .Network }
                    append_status_block(state, kind, alignment, fields[6], foreground, background,
                        foreground_set, background_set, click_command)
                }
                parsed_any = true
            }
        }
        free_block_fields(&fields)
    }
    return parsed_any
}

blocks_reload :: proc(state: ^State) {
    blocks_destroy(state)
    state.Blocks = make([dynamic]Block, 0, 4)
    if !blocks_read_managed(state) { append_workspace_block(state, .Left) }
    tray_update_owner(state)
    draw_all_bars(state)
}

blocks_destroy :: proc(state: ^State) {
    for &block in state.Blocks {
        if block.Ops.Destroy != nil { block.Ops.Destroy(&block, state) }
    }
    delete(state.Blocks)
    state.Blocks = nil
}

workspace_for_slot :: proc(state: ^State, window: ^Bar_Window, id: int) -> ^Workspace_State {
    for &ws in state.Workspaces {
        if ws.Id == id && ws.Output == window.Output { return &ws }
    }
    return nil
}

workspace_label :: proc(id: int, ws: ^Workspace_State) -> string {
    if ws == nil { return fmt.aprintf("%d", id) }
    if ws.Urgent { return fmt.aprintf("%s!", ws.Name) }
    return fmt.aprintf("%s", ws.Name)
}

workspace_width :: proc(state: ^State, label: string, occupied: bool) -> i32 {
    return text_width(state, label, occupied) + 20
}

blend_colour :: proc(from, to: u32, to_parts: u32, total_parts: u32 = 100) -> u32 {
    from_parts := total_parts - to_parts
    red := (((from >> 16) & 0xff) * from_parts + ((to >> 16) & 0xff) * to_parts) / total_parts
    green := (((from >> 8) & 0xff) * from_parts + ((to >> 8) & 0xff) * to_parts) / total_parts
    blue := ((from & 0xff) * from_parts + (to & 0xff) * to_parts) / total_parts
    return red << 16 | green << 8 | blue
}

workspace_measure :: proc(block: ^Block, state: ^State, window: ^Bar_Window) -> i32 {
    _ = block
    width := i32(0)
    for id := 1; id <= int(state.Config.WorkspaceCount); id += 1 {
        label := workspace_label(id, workspace_for_slot(state, window, id))
        ws := workspace_for_slot(state, window, id)
        width += workspace_width(state, label, ws != nil && ws.Occupied)
        delete(label)
    }
    return width
}

workspace_draw :: proc(block: ^Block, state: ^State, window: ^Bar_Window, start_x: i32, block_index: int) {
    x := start_x
    base_background := block_background(block, state)
    base_foreground := block_foreground(block, state)
    for id := 1; id <= int(state.Config.WorkspaceCount); id += 1 {
        ws := workspace_for_slot(state, window, id)
        label := workspace_label(id, ws)
        occupied := ws != nil && ws.Occupied
        width := workspace_width(state, label, occupied)
        background := block.BackgroundSet ? base_background : state.Config.WorkspaceBackground
        foreground := block.ForegroundSet ? base_foreground : state.Config.WorkspaceForeground
        if ws != nil && ws.Active {
            background = block.ForegroundSet ? base_foreground : state.Config.Foreground
            foreground = block.BackgroundSet ? base_background : state.Config.Background
        } else if ws != nil && ws.Urgent {
            background = base_background
            foreground = base_foreground
        } else if window.HoverWorkspace == id {
            background = blend_colour(
                background, block.ForegroundSet ? base_foreground : state.Config.Foreground, 35,
            )
        } else if !occupied {
            foreground = blend_colour(
                foreground, background, 55,
            )
        }
        fill_rect(state, X_Drawable(window.Canvas), x, 0, width, window.Geom.H, background)
        draw_text(state, window, x + 10, label, foreground, occupied)
        if occupied {
            fill_rect(
                state, X_Drawable(window.Canvas), x + 6, window.Geom.H - 2,
                width - 12, 2, foreground,
            )
        }
        append(&window.Hits, Hitbox{
            X = x, Y = 0, W = width, H = window.Geom.H,
            BlockIndex = block_index, Payload = id,
        })
        x += width
        delete(label)
    }
}

workspace_click :: proc(block: ^Block, state: ^State, window: ^Bar_Window, workspace_id: int, button: u8) {
    _ = block
    target := workspace_id
    if button == 4 || button == 5 {
        target = 1
        for ws in state.Workspaces {
            if ws.Output == window.Output && ws.Active { target = ws.Id; break }
        }
        if button == 4 { target -= 1 }
        if button == 5 { target += 1 }
        if target < 1 { target = int(state.Config.WorkspaceCount) }
        if target > int(state.Config.WorkspaceCount) { target = 1 }
    }
    if button != 1 && button != 4 && button != 5 { return }
    if target < 1 || target > int(state.Config.WorkspaceCount) { return }
    ipc_switch_workspace(state, window.Output, target)
}
