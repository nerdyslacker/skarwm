package wm

// Optional built-in bar process control. The bar remains an ordinary EWMH
// dock client: this module only publishes its small bootstrap configuration
// and starts it. Rendering and monitor handling live in cmd/skarwm-bar.

import process "../process"
import x11 "../x11"

import "core:fmt"
import "core:os"
import "core:strings"

BAR_CONFIG_ATOM :: "_SKARWM_BAR_CONFIG"
BAR_BLOCKS_ATOM :: "_SKARWM_BAR_BLOCKS"
BAR_CONFIG_VERSION :: u32(1)

bar_write_escaped :: proc(builder: ^strings.Builder, value: string) {
    for byte in transmute([]u8)value {
        switch byte {
        case '\\': strings.write_string(builder, "\\\\")
        case '\t': strings.write_string(builder, "\\t")
        case '\n': strings.write_string(builder, "\\n")
        case '\r': strings.write_string(builder, "\\r")
        case: strings.write_byte(builder, byte)
        }
    }
}

bar_publish_blocks :: proc() {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    strings.write_string(&builder, "version=1\n")
    for block in g_wm.bar_blocks {
        switch block.kind {
        case .Workspaces:
            strings.write_string(&builder, "workspaces\t")
            strings.write_i64(&builder, i64(block.alignment))
            strings.write_byte(&builder, '\n')
        case .Script:
            strings.write_string(&builder, "script\t")
            strings.write_i64(&builder, i64(block.alignment))
            strings.write_byte(&builder, '\t')
            strings.write_i64(&builder, i64(block.interval_ms))
            strings.write_byte(&builder, '\t')
            strings.write_i64(&builder, i64(block.timeout_ms))
            strings.write_byte(&builder, '\t')
            bar_write_escaped(&builder, block.name)
            strings.write_byte(&builder, '\t')
            bar_write_escaped(&builder, block.command)
            strings.write_byte(&builder, '\n')
        case .Systray:
            strings.write_string(&builder, "systray\t")
            strings.write_i64(&builder, i64(block.alignment))
            strings.write_byte(&builder, '\n')
        }
    }
    payload := strings.to_string(builder)
    x11.set_prop_text(
        g_wm.conn, g_wm.root, atom(BAR_BLOCKS_ATOM), atom("UTF8_STRING"), payload,
    )
}

bar_sync_config :: proc() {
    if g_wm.conn == nil || g_wm.m == nil { return }
    cfg := &g_wm.m.Cfg
    position := u32(cfg.BarPosition)
    values := []u32{
        BAR_CONFIG_VERSION, u32(cfg.BarEnabled), position, u32(cfg.BarHeight),
        cfg.BarForeground, cfg.BarBackground,
    }
    x11.set_prop32(g_wm.conn, g_wm.root, atom(BAR_CONFIG_ATOM), atom("CARDINAL"), values)
    bar_publish_blocks()
    x11.xcb_flush(g_wm.conn)

    if !cfg.BarEnabled {
        // A managed bar observes the root property and exits. Mark it stopped
        // so a later enable can launch a fresh process.
        g_wm.bar_managed_started = false
        return
    }
    if g_wm.bar_managed_started { return }

    executable := "skarwm-bar"
    env_buf: [1024]u8
    if configured := os.get_env_buf(env_buf[:], "SKARWM_BAR"); configured != "" {
        executable = configured
    } else if os.exists("build/skarwm-bar") {
        executable = "build/skarwm-bar"
    }
    command := fmt.aprintf("%q --managed", executable)
    process.Spawn(command)
    delete(command)
    g_wm.bar_managed_started = true
}

bar_shutdown :: proc() {
    if g_wm.conn == nil || !g_wm.bar_managed_started { return }
    values := []u32{BAR_CONFIG_VERSION, 0, 0, 0}
    x11.set_prop32(g_wm.conn, g_wm.root, atom(BAR_CONFIG_ATOM), atom("CARDINAL"), values)
    x11.xcb_flush(g_wm.conn)
    g_wm.bar_managed_started = false
}
