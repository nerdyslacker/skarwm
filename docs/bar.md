# Built-in bar

`skarwm-bar` is an optional standalone process. It is disabled by default, so
external docks and desktop shells continue to work without any built-in bar
process or reserved space.

Enable the managed bar in `config.d/bar.conf`:

```ini
[bar]
enabled = true
position = top
height = 26
font = monospace
font_size = 11
font_weight = normal
tag_count = 8
```

The WM launches `skarwm-bar`, or the executable named by `$SKARWM_BAR`. During
development it uses `build/skarwm-bar` when that file exists. Reloading the WM
configuration updates the position and height; disabling the bar makes a
managed instance exit and removes its struts.

The binary can also be run independently:

```sh
skarwm-bar --position bottom --height 30
```

It creates one dock window per active RandR 1.5 monitor, including virtual
screens published by skarwm, follows geometry changes, and publishes both
`_NET_WM_STRUT` and `_NET_WM_STRUT_PARTIAL`. skarwm converts those root-relative
struts to per-output reserved insets, so tiled and maximized windows use the
remaining workarea.

The first reusable block is `workspaces`, aligned on the left. It receives
workspace, window, and output events through the existing i3-compatible IPC
socket and refreshes from `GET_WORKSPACES`; there is no render-loop polling.
Each monitor always renders `bar_tag_count` slots (eight by default),
including empty workspaces which are not yet present in the WM snapshot. The
active workspace uses the main bar color pair. Hover and vacant colors are
derived from the configured palette instead of hard-coded values. Occupied
workspaces use a bold face and underline, while urgent workspaces carry `!`.
Left-click switches to the selected slot on the clicked
logical screen. Wheel up/down cycles that screen's active workspace within the fixed range; it
does not derive a new workspace number from the hovered slot. The IPC client
reconnects after WM restarts.

Foreground and background are configurable:

```ini
[bar]
foreground = #E6E6E6
background = #1E1E2E

[bar.tag]
foreground = #262626
background = #5F87AF

[bar.block]
foreground = #262626
background = #AF5F5F
```

Workspace cells, script blocks, and button blocks use their own
foreground/background pairs, with the main bar background visible between
aligned blocks.

## Blocks and scripts

Block order is the order of named `[bar.block.NAME]` sections. Position may be
`left`, `center`, or `right`. If there are no named block sections, the bar
shows left-aligned workspace and current-layout blocks plus the focused window
title in the centre.

The layout block uses Nerd Font glyphs for Scrolling Tile, Vertical Scroller,
Tabbed, Dwindle, Monocle, and Floating.

The title block fits short titles and caps its width at 240 pixels. Long titles
are ellipsized;
hover the title to see the complete text. Hover a layout glyph to see its name.

```ini
[bar.block.workspaces]
type = workspaces
position = left

[bar.block.layout]
type = layout
position = left

[bar.block.title]
type = title
position = center

[bar.block.clock]
type = script
position = right
icon = 󰃭
interval = 1
timeout = 1
command = date '+%H:%M'

[bar.block.audio]
type = audio
position = right
icon = 󰕾

[bar.block.systray]
type = systray
position = right
```

The `audio` block reads the default PipeWire/PulseAudio sink, toggles mute on
middle click, and changes volume in five-percent steps when the pointer is over
the block and the mouse wheel is scrolled. It uses `wpctl` when available and
falls back to `pactl`.

The `network` block reports the first active non-loopback interface name, uses
`󰤭 off` when disconnected, and opens `nm-connection-editor` on left click.
Middle click toggles the Wi-Fi radio. The `bluetooth` block reports adapter
power using its configured icon when enabled and `󰂲` when disabled. The icon
is followed by `on` or `off`; hover it to see each connected device and its
battery percentage when available. It opens
`blueman-manager` on left click, and middle click toggles Bluetooth power.
Muted audio replaces its configured icon with `󰝟` and displays `muted`.
Missing NetworkManager tooling uses the network-off state without blocking the
bar.

Audio, Network, and Bluetooth accept an optional final shell command for left
click. It replaces the Network/Bluetooth settings application; Audio has no
default left-click action. Commands may contain colons and should be quoted:

```ini
[bar.block.audio]
type = audio
position = right
icon = 󰕾
command = pavucontrol

[bar.block.network]
type = network
position = right
icon = 󰤨
command = rofi -show network

[bar.block.bluetooth]
type = bluetooth
position = right
icon = 󰂯
command = blueman-manager
```

Every block can override its foreground and background. Omit a color, or set it
to `_`, to inherit that color from `[bar.block]`:

```ini
[bar.block.network]
type = network
position = right
icon = 󰤨
foreground = #FCE8C3
background = #3C3836

[bar.block.systray]
type = systray
position = right
foreground = _
background = #282828
```

Button fields after the alignment are `label` and command. The label may be
text or an icon glyph. A left click starts the command detached from the bar,
so launchers and long-running menus do not block status updates. For example,
use `rofi -show drun` for an application launcher, or replace the power-menu
example with any dmenu/rofi script installed on your system.

Script fields after the alignment are `name`, update interval in seconds,
timeout in seconds, and command. Named blocks render as `name value`, so icon
labels do not acquire punctuation. Use `_` as the name to render only command
output; a glyph or icon can be used as an ordinary name. Intervals are
`1..86400`; timeouts are
`1..60`. Commands deliberately run through `/bin/sh -c` with the user's
permissions so shell pipelines and quoting work. Button commands use the same
shell behavior. Do not place untrusted text in these commands.

Each script has its own timer and is never launched by the render path. Output
is limited to 4 KiB, trailing whitespace is removed, and embedded control
characters are made display-safe. A non-zero exit displays `error`; a command
that exceeds its timeout displays `timeout`. The entire command process group
is stopped on timeout, bar shutdown, or configuration reload.

Bars are double-buffered per monitor: a complete frame is composed off-screen
and copied to the dock window in one operation, preventing script refreshes
from exposing a partially cleared or partially redrawn bar.

Changing block definitions and reloading skarwm rebuilds the blocks without
restarting the WM. The managed bar receives the ordered definitions through
the versioned `_SKARWM_BAR_BLOCKS` root property.

## System tray

The `systray` block implements the X11 system-tray and XEmbed protocols. It
creates a dedicated child host, owns `_NET_SYSTEM_TRAY_Sn`, announces that host
with `MANAGER`, accepts dock requests, reparents and sizes icons, and uses the X
save set so icons survive a bar-window rebuild. Destroyed and reparented-away
icons are removed from layout.

X11 permits one tray owner per screen. On a multi-monitor X screen, the tray is
therefore shown on the first active RandR monitor; other monitors still get
their own workspace and script blocks. If another tray already owns the
selection, `skarwm-bar` leaves it alone and renders no tray icons.
It also prints the conflicting owner window id to stderr. The built-in tray is
an XEmbed tray; applications which expose only the DBus StatusNotifierItem
protocol require an SNI-to-XEmbed bridge.

## External bars

Keep `[bar] enabled = false` and start the external bar normally. skarwm still
manages EWMH dock windows and honors their struts; workspace/output IPC and EWMH
desktop state remain available.
