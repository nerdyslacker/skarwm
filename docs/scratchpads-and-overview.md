# Scratchpads and overview

## Scratchpads

Scratchpads are numbered, session-only registers. The first toggle assigns the
focused window. Later toggles hide it or summon and focus it on the active
workspace/output.

| Default binding | Action |
|---|---|
| `Super+grave` | `scratchpad_toggle 1` |
| `Super+Shift+grave` | `scratchpad_toggle_float 2` |
| `Super+Control+grave` | `scratchpad_remove 1` |

Hidden scratchpads remain managed but leave the workspace layout. The floating
variant makes the window floating. Removing a register summons a hidden window
before forgetting it. Closing a window clears its registrations.

IPC can also toggle groups by exact app ID, class, instance, or title and can
spawn a command when no match exists. See [IPC.md](IPC.md).

## Overview integration

The overview action is a controller for an external shell UI such as Anush. It
grabs the keyboard and emits window events; it does not draw thumbnails itself.

```rc
call : Alt + Tab : overview_next
call : Alt + Shift + Tab : overview_prev
```

While active: Tab/Shift+Tab cycles, arrows emit workspace/window navigation,
Return or Space commits, Escape cancels, and releasing Alt commits. A subscribed
shell consumes `overview-*` window events and presents the visual overview.
