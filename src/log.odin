package main

import "core:fmt"
import "core:os"

Log_Level :: enum u8 { Debug, Info, Warn, Error, Off }
g_log_level := Log_Level.Info

log_init :: proc() {
    buf: [32]u8
    switch os.get_env_buf(buf[:], "SKARWM_LOG") {
    case "debug", "DEBUG": g_log_level = .Debug
    case "info",  "INFO", "": g_log_level = .Info
    case "warn",  "WARN": g_log_level = .Warn
    case "error", "ERROR": g_log_level = .Error
    case "off",   "OFF": g_log_level = .Off
    case:
        fmt.eprintln("[WARN] SKARWM_LOG must be debug, info, warn, error, or off")
    }
}

log_debug :: proc(args: ..any) { if g_log_level <= .Debug { fmt.eprint("[DEBUG] "); fmt.eprintln(..args) } }
log_info  :: proc(args: ..any) { if g_log_level <= .Info  { fmt.eprint("[INFO] ");  fmt.eprintln(..args) } }
log_warn  :: proc(args: ..any) { if g_log_level <= .Warn  { fmt.eprint("[WARN] ");  fmt.eprintln(..args) } }
log_error :: proc(args: ..any) { if g_log_level <= .Error { fmt.eprint("[ERROR] "); fmt.eprintln(..args) } }
