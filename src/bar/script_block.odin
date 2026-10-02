package main

// Script-backed bar blocks.

import process "../process"

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"

SCRIPT_OUTPUT_MAX :: 4096
SCRIPT_VISIBLE_MAX :: 220

Script_Block_Data :: struct {
    Name: string,
    Command: [1024]byte,
    ClickCommand: [1024]byte,
    ClickCommandLen: int,
    Text: string,
    Interval, Timeout: time.Duration,
    NextRun, Started: time.Tick,
    Pid: posix.pid_t,
    Fd: posix.FD,
    Output: [SCRIPT_OUTPUT_MAX]byte,
    OutputLen: int,
    Eof, TimedOut: bool,
}

script_set_click_command :: proc(block: ^Block, command: string) {
    data := script_data(block)
    if data == nil || len(command) >= len(data.ClickCommand) { return }
    copy(data.ClickCommand[:len(command)], transmute([]u8)command)
    data.ClickCommand[len(command)] = 0
    data.ClickCommandLen = len(command)
}

script_click_command :: proc(block: ^Block) -> string {
    data := script_data(block)
    if data == nil || data.ClickCommandLen == 0 { return "" }
    return string(data.ClickCommand[:data.ClickCommandLen])
}

script_data :: proc(block: ^Block) -> ^Script_Block_Data {
    if block == nil || block.Data == nil { return nil }
    if block.Kind != .Script && block.Kind != .Audio &&
       block.Kind != .Bluetooth && block.Kind != .Network { return nil }
    return (^Script_Block_Data)(block.Data)
}

append_script_block :: proc(
    state: ^State,
    alignment: Block_Alignment,
    name, command: string,
    interval_ms, timeout_ms: i32,
    foreground: u32 = 0, background: u32 = 0,
    foreground_set: bool = false, background_set: bool = false,
) {
    if command == "" || len(command) >= 1024 { return }
    data := new(Script_Block_Data)
    data.Name = strings.clone(name)
    copy(data.Command[:len(command)], transmute([]u8)command)
    data.Command[len(command)] = 0
    data.Text = strings.clone("…")
    data.Interval = time.Duration(interval_ms) * time.Millisecond
    data.Timeout = time.Duration(timeout_ms) * time.Millisecond
    data.Fd = -1
    data.NextRun = time.tick_now()
    append(&state.Blocks, Block{
        Name = data.Name,
        Kind = .Script,
        Alignment = alignment,
        Ops = Block_Ops{
            Measure = script_measure,
            Draw = script_draw,
            Destroy = script_destroy,
        },
        Data = data,
        Foreground = foreground, Background = background,
        ForegroundSet = foreground_set, BackgroundSet = background_set,
    })
}

BLUETOOTH_OFF_ICON :: "󰂲"
AUDIO_OFF_ICON :: "󰝟"
NETWORK_OFF_ICON :: "󰤭"

script_label :: proc(block: ^Block) -> string {
    data := script_data(block)
    if data == nil { return fmt.aprintf("") }
    if block.Kind == .Bluetooth {
        if data.Text == "connected" { return fmt.aprintf("%s on", data.Name) }
        return fmt.aprintf("%s off", BLUETOOTH_OFF_ICON)
    }
    if block.Kind == .Network && (data.Text == "offline" || data.Text == "unavailable") {
        return fmt.aprintf("%s off", NETWORK_OFF_ICON)
    }
    if block.Kind == .Audio && data.Text == "muted" {
        return fmt.aprintf("%s muted", AUDIO_OFF_ICON)
    }
    if data.Name == "" || data.Name == "_" { return fmt.aprintf("%s", data.Text) }
    return fmt.aprintf("%s %s", data.Name, data.Text)
}

script_measure :: proc(block: ^Block, state: ^State, window: ^Bar_Window) -> i32 {
    _ = window
    label := script_label(block)
    defer delete(label)
    visible := label[:min(len(label), SCRIPT_VISIBLE_MAX)]
    return text_width(state, visible) + 16
}

script_draw :: proc(block: ^Block, state: ^State, window: ^Bar_Window, x: i32, block_index: int) {
    label := script_label(block)
    defer delete(label)
    visible := label[:min(len(label), SCRIPT_VISIBLE_MAX)]
    width := text_width(state, visible) + 16
    wrapper_y := min(i32(3), max(i32(0), window.Geom.H / 4))
    fill_rect(
        state, X_Drawable(window.Canvas), x, wrapper_y, width, window.Geom.H - wrapper_y * 2,
        block_background(block, state),
    )
    draw_text(state, window, x + 8, visible, block_foreground(block, state))
    if block.Ops.Click != nil {
        append(&window.Hits, Hitbox{
            X = x, Y = 0, W = width, H = window.Geom.H,
            BlockIndex = block_index,
        })
    }
}

AUDIO_READ_COMMAND :: `if command -v wpctl >/dev/null 2>&1; then wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{if ($0 ~ /\[MUTED\]/) printf "muted"; else printf "%d%%", $2 * 100}'; elif pactl get-sink-mute @DEFAULT_SINK@ | grep -q 'yes'; then printf 'muted'; else pactl get-sink-volume @DEFAULT_SINK@ | grep -o '[0-9]*%' | head -1; fi`
AUDIO_UP_COMMAND :: `if command -v wpctl >/dev/null 2>&1; then wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+; else pactl set-sink-volume @DEFAULT_SINK@ +5%; fi`
AUDIO_DOWN_COMMAND :: `if command -v wpctl >/dev/null 2>&1; then wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-; else pactl set-sink-volume @DEFAULT_SINK@ -5%; fi`
AUDIO_TOGGLE_COMMAND :: `if command -v wpctl >/dev/null 2>&1; then wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle; else pactl set-sink-mute @DEFAULT_SINK@ toggle; fi`

append_audio_block :: proc(
    state: ^State, alignment: Block_Alignment, label: string,
    foreground: u32 = 0, background: u32 = 0,
    foreground_set: bool = false, background_set: bool = false,
    click_command: string = "",
) {
    before := len(state.Blocks)
    append_script_block(state, alignment, label, AUDIO_READ_COMMAND, 1000, 1000,
        foreground, background, foreground_set, background_set)
    if len(state.Blocks) == before { return }
    block := &state.Blocks[len(state.Blocks) - 1]
    block.Kind = .Audio
    block.Ops.Click = audio_click
    script_set_click_command(block, click_command)
}

audio_click :: proc(block: ^Block, state: ^State, window: ^Bar_Window, payload: int, button: u8) {
    _ = state
    _ = window
    _ = payload
    command := ""
    if button == 1 { command = script_click_command(block) }
    if button == 2 { command = AUDIO_TOGGLE_COMMAND }
    if button == 4 { command = AUDIO_UP_COMMAND }
    if button == 5 { command = AUDIO_DOWN_COMMAND }
    if command == "" { return }
    process.Spawn(command)
    if data := script_data(block); data != nil {
        data.NextRun = time.tick_add(time.tick_now(), 150 * time.Millisecond)
    }
}

NETWORK_READ_COMMAND :: `if command -v nmcli >/dev/null 2>&1; then LC_ALL=C nmcli -t -f DEVICE,STATE device status | awk -F: '$2 == "connected" && $1 != "lo" {print $1; found=1; exit} END {if (!found) print "offline"}'; else printf 'unavailable'; fi`
NETWORK_CLICK_COMMAND :: `command -v nm-connection-editor >/dev/null 2>&1 && exec nm-connection-editor`
NETWORK_TOGGLE_COMMAND :: `if command -v nmcli >/dev/null 2>&1; then if [ "$(nmcli radio wifi)" = "enabled" ]; then nmcli radio wifi off; else nmcli radio wifi on; fi; fi`
BLUETOOTH_READ_COMMAND :: `if command -v bluetoothctl >/dev/null 2>&1 && bluetoothctl devices Connected 2>/dev/null | grep -q .; then printf 'connected'; else printf 'disconnected'; fi`
BLUETOOTH_CLICK_COMMAND :: `command -v blueman-manager >/dev/null 2>&1 && exec blueman-manager`
BLUETOOTH_TOGGLE_COMMAND :: `if command -v bluetoothctl >/dev/null 2>&1; then if bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; then bluetoothctl power off; else bluetoothctl power on; fi; fi`

append_status_block :: proc(
    state: ^State, kind: Block_Kind, alignment: Block_Alignment, label: string,
    foreground: u32 = 0, background: u32 = 0,
    foreground_set: bool = false, background_set: bool = false,
    click_command: string = "",
) {
    if kind != .Bluetooth && kind != .Network { return }
    read_command := kind == .Bluetooth ? BLUETOOTH_READ_COMMAND : NETWORK_READ_COMMAND
    before := len(state.Blocks)
    append_script_block(state, alignment, label, read_command, 3000, 2000,
        foreground, background, foreground_set, background_set)
    if len(state.Blocks) == before { return }
    block := &state.Blocks[len(state.Blocks) - 1]
    block.Kind = kind
    block.Ops.Click = status_click
    script_set_click_command(block, click_command)
}

status_click :: proc(block: ^Block, state: ^State, window: ^Bar_Window, payload: int, button: u8) {
    _ = state
    _ = window
    _ = payload
    command := ""
    if button == 1 {
        command = script_click_command(block)
        if command == "" {
            if block.Kind == .Bluetooth { command = BLUETOOTH_CLICK_COMMAND }
            if block.Kind == .Network { command = NETWORK_CLICK_COMMAND }
        }
    } else if button == 2 {
        if block.Kind == .Bluetooth { command = BLUETOOTH_TOGGLE_COMMAND }
        if block.Kind == .Network { command = NETWORK_TOGGLE_COMMAND }
    }
    if command == "" { return }
    process.Spawn(command)
    if button == 2 {
        if data := script_data(block); data != nil {
            data.NextRun = time.tick_add(time.tick_now(), 150 * time.Millisecond)
        }
    }
}

script_stop :: proc(data: ^Script_Block_Data) {
    if data == nil { return }
    if data.Pid > 0 {
        if posix.killpg(data.Pid, .SIGKILL) != .OK { posix.kill(data.Pid, .SIGKILL) }
        posix.waitpid(data.Pid, nil, {})
    }
    if data.Fd >= 0 { posix.close(data.Fd) }
    data.Pid = 0
    data.Fd = -1
}

script_destroy :: proc(block: ^Block, state: ^State) {
    _ = state
    data := script_data(block)
    if data == nil { return }
    script_stop(data)
    if data.Name != "" { delete(data.Name) }
    if data.Text != "" { delete(data.Text) }
    free(data)
    block.Data = nil
}

script_start :: proc(data: ^Script_Block_Data, now: time.Tick) -> bool {
    pipes: [2]posix.FD
    if posix.pipe(&pipes) != .OK {
        script_set_result(data, false)
        data.NextRun = time.tick_add(now, data.Interval)
        return true
    }
    pid := posix.fork()
    if pid < 0 {
        posix.close(pipes[0])
        posix.close(pipes[1])
        script_set_result(data, false)
        data.NextRun = time.tick_add(now, data.Interval)
        return true
    }
    if pid == 0 {
        posix.setpgid(0, 0)
        posix.close(pipes[0])
        posix.dup2(pipes[1], posix.STDOUT_FILENO)
        if pipes[1] != posix.STDOUT_FILENO { posix.close(pipes[1]) }
        devnull := posix.open("/dev/null", {.RDWR})
        if devnull >= 0 {
            posix.dup2(devnull, posix.STDIN_FILENO)
            posix.dup2(devnull, posix.STDERR_FILENO)
            if devnull > posix.STDERR_FILENO { posix.close(devnull) }
        }
        command := cstring(&data.Command[0])
        argv := [4]cstring{"/bin/sh", "-c", command, nil}
        posix.execv("/bin/sh", &argv[0])
        posix._exit(127)
    }

    posix.close(pipes[1])
    posix.setpgid(pid, pid)
    flags := posix.fcntl(pipes[0], .GETFL)
    if flags >= 0 { posix.fcntl(pipes[0], .SETFL, flags | posix.O_NONBLOCK) }
    data.Pid = pid
    data.Fd = pipes[0]
    data.Started = now
    data.OutputLen = 0
    data.Eof = false
    data.TimedOut = false
    return false
}

script_read_output :: proc(data: ^Script_Block_Data) {
    if data.Fd < 0 { return }
    scratch: [1024]byte
    for {
        count := int(posix.read(data.Fd, &scratch[0], len(scratch)))
        if count > 0 {
            available := SCRIPT_OUTPUT_MAX - data.OutputLen
            copied := min(count, available)
            if copied > 0 {
                copy(data.Output[data.OutputLen:data.OutputLen + copied], scratch[:copied])
                data.OutputLen += copied
            }
            continue
        }
        if count == 0 {
            posix.close(data.Fd)
            data.Fd = -1
            data.Eof = true
        }
        break
    }
}

script_set_result :: proc(data: ^Script_Block_Data, success: bool) {
    if data.Text != "" { delete(data.Text) }
    if !success {
        data.Text = strings.clone(data.TimedOut ? "timeout" : "error")
        return
    }
    bytes := make([]byte, data.OutputLen)
    copy(bytes, data.Output[:data.OutputLen])
    for &byte in bytes {
        if byte == '\n' || byte == '\r' || byte == '\t' { byte = ' ' }
        if byte < 0x20 { byte = '?' }
    }
    trimmed := strings.trim_right_space(string(bytes))
    data.Text = strings.clone(trimmed)
    delete(bytes)
}

script_service_one :: proc(data: ^Script_Block_Data, now: time.Tick) -> bool {
    if data.Pid <= 0 {
        if time.tick_diff(data.NextRun, now) >= 0 { return script_start(data, now) }
        return false
    }

    script_read_output(data)
    status: c.int
    waited := posix.waitpid(data.Pid, &status, {.NOHANG})
    if waited == 0 && !data.TimedOut && time.tick_diff(data.Started, now) >= data.Timeout {
        data.TimedOut = true
        if posix.killpg(data.Pid, .SIGKILL) != .OK { posix.kill(data.Pid, .SIGKILL) }
        if data.Fd >= 0 { posix.close(data.Fd); data.Fd = -1 }
        data.Eof = true
        return false
    }
    if waited == 0 { return false }
    success := waited == data.Pid && !data.TimedOut &&
        posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
    // A shell command that backgrounds work must not leave that work attached
    // to the bar after the shell itself exits.
    posix.killpg(data.Pid, .SIGKILL)
    script_set_result(data, success)
    if data.Fd >= 0 { posix.close(data.Fd) }
    data.Fd = -1
    data.Pid = 0
    data.NextRun = time.tick_add(now, data.Interval)
    return true
}

scripts_service :: proc(state: ^State) {
    now := time.tick_now()
    changed := false
    for &block in state.Blocks {
        if data := script_data(&block); data != nil {
            if script_service_one(data, now) { changed = true }
        }
    }
    if changed { draw_all_bars(state) }
}

scripts_poll_timeout :: proc(state: ^State) -> i32 {
    now := time.tick_now()
    timeout := i32(-1)
    for &block in state.Blocks {
        data := script_data(&block)
        if data == nil { continue }
        candidate := i32(50)
        if data.Pid <= 0 {
            remaining := time.tick_diff(now, data.NextRun)
            if remaining <= 0 {
                candidate = 0
            } else {
                milliseconds := (i64(remaining) + i64(time.Millisecond) - 1) / i64(time.Millisecond)
                candidate = i32(min(milliseconds, i64(2147483647)))
            }
        }
        if timeout < 0 || candidate < timeout { timeout = candidate }
    }
    return timeout
}
