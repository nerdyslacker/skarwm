package wm

import ui "../ui"

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

notice_date_time_text :: proc() -> string {
    stamp := libc.time(nil)
    local := libc.localtime(&stamp)
    if local == nil { return strings.clone("Date and time unavailable") }
    buf: [128]u8
    n := libc.strftime(&buf[0], len(buf), "%A, %d %B %Y - %H:%M", local)
    if n == 0 { return strings.clone("Date and time unavailable") }
    return strings.clone(string(buf[:int(n)]))
}

read_notice_value :: proc(path: string) -> string {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil { return "" }
    return strings.trim_space(string(data))
}

notice_battery_text :: proc() -> string {
    root := "/sys/class/power_supply"
    entries, err := os.read_all_directory_by_path(root, context.temp_allocator)
    if err != nil { return strings.clone("Battery status unavailable") }
    for entry in entries {
        type_path := fmt.tprintf("%s/%s/type", root, entry.name)
        if read_notice_value(type_path) != "Battery" { continue }
        capacity_path := fmt.tprintf("%s/%s/capacity", root, entry.name)
        capacity_text := read_notice_value(capacity_path)
        capacity, ok := strconv.parse_i64(capacity_text, 10)
        if !ok { continue }
        capacity = min(i64(100), max(i64(0), capacity))
        status_path := fmt.tprintf("%s/%s/status", root, entry.name)
        status := read_notice_value(status_path)
        if status == "" { return fmt.aprintf("Battery: %d%%", capacity) }
        return fmt.aprintf("Battery: %d%% - %s", capacity, status)
    }
    return strings.clone("Battery status unavailable")
}

show_date_time_notice :: proc() {
    text := notice_date_time_text()
    defer delete(text)
    ui.Show_Notice(&g_wm.ui, g_wm.m, text)
}

show_battery_notice :: proc() {
    text := notice_battery_text()
    defer delete(text)
    ui.Show_Notice(&g_wm.ui, g_wm.m, text)
}
