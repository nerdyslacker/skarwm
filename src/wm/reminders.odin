package wm

import ui "../ui"
import input "../input"
import x11 "../x11"

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

REMINDER_MAX_MINUTES :: i64(525600) // one year

Reminder :: struct {
    Message: string,
    Due: time.Tick,
    Minutes: i64,
}

reminder_dialog_end :: proc() {
    if g_wm.reminder_dialog_active {
        x11.xcb_ungrab_keyboard(g_wm.conn, x11.CURRENT_TIME)
    }
    g_wm.reminder_dialog_active = false
    ui.Hide_Reminder_Panel(&g_wm.ui)
}

reminder_dialog_begin :: proc() {
    if ipc_simple_ui_event("ui-reminder-new") {
        reminder_dialog_end()
        return
    }
    if g_wm.reminder_dialog_active {
        reminder_dialog_end()
        return
    }
    ui.Hide_Help(&g_wm.ui)
    ui.Hide_Reminder_Panel(&g_wm.ui)

    // Replace the passive shortcut grab with an explicit keyboard grab so all
    // editor keystrokes reach the WM regardless of the focused application.
    x11.xcb_ungrab_keyboard(g_wm.conn, x11.CURRENT_TIME)
    cookie := x11.xcb_grab_keyboard(
        g_wm.conn, 0, g_wm.root, x11.CURRENT_TIME,
        x11.GRAB_MODE_ASYNC, x11.GRAB_MODE_ASYNC,
    )
    err: ^x11.Error
    reply := x11.xcb_grab_keyboard_reply(g_wm.conn, cookie, &err)
    if err != nil { x11.free_libc(err) }
    if reply == nil { return }
    success := reply.status == 0
    x11.free_libc(reply)
    if !success { return }

    g_wm.reminder_dialog_active = true
    ui.Show_Reminder_Dialog(&g_wm.ui, g_wm.m)
    if g_wm.ui.ReminderWindow == 0 { reminder_dialog_end() }
}

reminder_add :: proc(minutes: i64, message: string) {
    if g_wm.reminders == nil { g_wm.reminders = make([dynamic]Reminder, 0, 8) }
    append(&g_wm.reminders, Reminder{
        Message = strings.clone(message),
        Due = time.tick_add(time.tick_now(), time.Duration(minutes) * time.Minute),
        Minutes = minutes,
    })
}

reminder_submit_dialog :: proc() {
    minutes_text := strings.trim_space(g_wm.ui.ReminderMinutes)
    minutes, ok := strconv.parse_i64(minutes_text, 10)
    if !ok || minutes < 1 || minutes > REMINDER_MAX_MINUTES {
        ui.Set_Reminder_Field(&g_wm.ui, g_wm.m, 0)
        ui.Set_Reminder_Error(&g_wm.ui, g_wm.m, "Minutes must be a whole number from 1 to 525600")
        return
    }
    message := strings.trim_space(g_wm.ui.ReminderMessage)
    if message == "" {
        ui.Set_Reminder_Field(&g_wm.ui, g_wm.m, 1)
        ui.Set_Reminder_Error(&g_wm.ui, g_wm.m, "Message cannot be empty")
        return
    }
    reminder_add(minutes, message)
    confirmation := fmt.aprintf("Reminder set for %d minute%s", minutes, "" if minutes == 1 else "s")
    defer delete(confirmation)
    reminder_dialog_end()
    notice_show(confirmation, false)
}

reminder_dialog_keypress :: proc(ev: ^x11.Key_Press_Event) {
    if ev == nil { return }
    if keycode_is(ev.detail, "Escape") {
        reminder_dialog_end()
        return
    }
    if keycode_is(ev.detail, "Tab") {
        field := 1
        if ev.state & x11.MOD_MASK_SHIFT != 0 { field = 0 }
        ui.Set_Reminder_Field(&g_wm.ui, g_wm.m, field)
        return
    }
    if keycode_is(ev.detail, "Return") || keycode_is(ev.detail, "KP_Enter") {
        if g_wm.ui.ReminderField == 0 {
            ui.Set_Reminder_Field(&g_wm.ui, g_wm.m, 1)
        } else {
            reminder_submit_dialog()
        }
        return
    }
    if keycode_is(ev.detail, "BackSpace") {
        ui.Backspace_Reminder_Field(&g_wm.ui, g_wm.m)
        return
    }

    level := 0
    if ev.state & x11.MOD_MASK_SHIFT != 0 { level = 1 }
    symbol := input.keysym_at_level(&g_wm.kb, ev.detail, level)
    if symbol < 0x20 || symbol > 0x7e { return }
    ch := u8(symbol)
    if g_wm.ui.ReminderField == 0 && (ch < '0' || ch > '9') { return }
    ui.Append_Reminder_Character(&g_wm.ui, g_wm.m, ch)
}

reminder_remaining_text :: proc(reminder: Reminder, now: time.Tick) -> string {
    remaining := time.tick_diff(now, reminder.Due)
    if remaining <= 0 { return strings.clone("due now") }
    seconds := (i64(remaining) + i64(time.Second) - 1) / i64(time.Second)
    if seconds < 60 { return fmt.aprintf("%d sec", seconds) }
    minutes := (seconds + 59) / 60
    return fmt.aprintf("%d min", minutes)
}

reminder_show_all :: proc() {
    if g_wm.ui.ReminderWindow != 0 && g_wm.ui.ReminderListMode {
        ui.Hide_Reminder_Panel(&g_wm.ui)
        return
    }
    if len(g_wm.reminders) == 0 {
        notice_show("No pending reminders", false)
        return
    }
    lines := make([dynamic]string, 0, len(g_wm.reminders))
    now := time.tick_now()
    for reminder, i in g_wm.reminders {
        remaining := reminder_remaining_text(reminder, now)
        append(&lines, fmt.aprintf("%d. %s - %s", i + 1, remaining, reminder.Message))
        delete(remaining)
    }
    if !ipc_reminders_event(lines[:]) {
        ui.Show_Reminder_List(&g_wm.ui, g_wm.m, lines[:])
    }
    for line in lines { delete(line) }
    delete(lines)
}

reminder_clear_all :: proc() {
    count := len(g_wm.reminders)
    for reminder in g_wm.reminders { delete(reminder.Message) }
    clear(&g_wm.reminders)
    ui.Hide_Reminder_Panel(&g_wm.ui)
    if count == 0 {
        notice_show("No pending reminders", false)
    } else {
        notice_show(fmt.tprintf("Cleared %d reminder%s", count, "" if count == 1 else "s"), false)
    }
}

reminder_poll_timeout_ms :: proc() -> i32 {
    if len(g_wm.reminders) == 0 { return -1 }
    now := time.tick_now()
    shortest := time.tick_diff(now, g_wm.reminders[0].Due)
    for reminder in g_wm.reminders[1:] {
        remaining := time.tick_diff(now, reminder.Due)
        if remaining < shortest { shortest = remaining }
    }
    if shortest <= 0 { return 0 }
    ns := i64(shortest)
    return i32(min(i64(max(i32)), (ns + i64(time.Millisecond) - 1) / i64(time.Millisecond)))
}

reminder_run_due :: proc() {
    if len(g_wm.reminders) == 0 { return }
    now := time.tick_now()
    text := strings.clone("Reminder: ")
    due_count := 0
    i := 0
    for i < len(g_wm.reminders) {
        reminder := g_wm.reminders[i]
        if time.tick_diff(reminder.Due, now) < 0 {
            i += 1
            continue
        }
        separator := ""
        if due_count > 0 { separator = "; " }
        next := fmt.aprintf("%s%s%s", text, separator, reminder.Message)
        delete(text)
        text = next
        delete(reminder.Message)
        ordered_remove(&g_wm.reminders, i)
        due_count += 1
    }
    if due_count > 0 { notice_show(text, true) }
    delete(text)
}

reminder_destroy_all :: proc() {
    reminder_dialog_end()
    for reminder in g_wm.reminders { delete(reminder.Message) }
    if g_wm.reminders != nil { delete(g_wm.reminders) }
    g_wm.reminders = nil
}
