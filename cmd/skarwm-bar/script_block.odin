package main

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
    Text: string,
    Interval, Timeout: time.Duration,
    NextRun, Started: time.Tick,
    Pid: posix.pid_t,
    Fd: posix.FD,
    Output: [SCRIPT_OUTPUT_MAX]byte,
    OutputLen: int,
    Eof, TimedOut: bool,
}

script_data :: proc(block: ^Block) -> ^Script_Block_Data {
    if block == nil || block.Kind != .Script || block.Data == nil { return nil }
    return (^Script_Block_Data)(block.Data)
}

append_script_block :: proc(
    state: ^State,
    alignment: Block_Alignment,
    name, command: string,
    interval_ms, timeout_ms: i32,
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
    })
}

script_label :: proc(data: ^Script_Block_Data) -> string {
    if data == nil { return fmt.aprintf("") }
    if data.Name == "" { return fmt.aprintf("%s", data.Text) }
    return fmt.aprintf("%s: %s", data.Name, data.Text)
}

script_measure :: proc(block: ^Block, state: ^State, window: ^Bar_Window) -> i32 {
    _ = state
    _ = window
    label := script_label(script_data(block))
    defer delete(label)
    return i32(min(len(label), SCRIPT_VISIBLE_MAX)) * 6 + 16
}

script_draw :: proc(block: ^Block, state: ^State, window: ^Bar_Window, x: i32, block_index: int) {
    _ = block_index
    label := script_label(script_data(block))
    defer delete(label)
    visible := label[:min(len(label), SCRIPT_VISIBLE_MAX)]
    width := i32(len(visible)) * 6 + 16
    fill_rect(state, window.Xid, x, 0, width, window.Geom.H, state.Config.Background)
    draw_text(
        state, window.Xid, x + 8, window.Geom.H / 2 + 5,
        visible, state.Config.Foreground, state.Config.Background,
    )
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
