# Notices

skarwm can display small temporary status overlays without a bar or external
notification daemon. They close automatically after 2.5 seconds and can also
be dismissed with a click.

| Default binding | Action | Meaning |
|---|---|---|
| `Super+Ctrl+Alt+h` | `show_bindings` | Show or hide the keybindings help overlay. |
| `Super+Ctrl+Alt+t` | `show_datetime` | Show the local date and time. |
| `Super+Ctrl+Alt+b` | `show_battery` | Show battery percentage and charging state. |

Battery information comes from `/sys/class/power_supply`. On desktops without
a battery, the notice reports that battery status is unavailable.
