# Reminders

Reminders are countdown timers kept for the lifetime of the running WM. When a
timer expires, its message appears as a persistent notice that remains visible
until clicked. Later reminders are appended instead of replacing an unread one.

| Default binding | Meaning |
|---|---|
| `Super+Ctrl+r` | Open the reminder editor. |
| `Super+Ctrl+Alt+r` | Show all pending reminders and their remaining time. |
| `Super+Ctrl+Shift+r` | Clear all pending reminders. |

The editor has `Minutes` and `Message` inputs. Use `Tab` or `Enter` to move to
the message, `Shift+Tab` to move back, `Enter` from the message to save,
`Backspace` to edit, and `Escape` to cancel. Minutes must be a positive whole
number. The pending-reminder list can be dismissed with a click.
