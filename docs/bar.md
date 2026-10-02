# Built-in bar

`skarwm-bar` is an optional standalone process. It is disabled by default, so
external docks and desktop shells continue to work without any built-in bar
process or reserved space.

Enable the managed bar in `config.rc`:

```rc
bar_enabled : true
bar_position : top
bar_height : 26
bar_font : monospace
bar_font_size : 11
bar_font_weight : normal
bar_tag_count : 8
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

```rc
bar_foreground : #E6E6E6
bar_background : #1E1E2E
bar_tag_foreground : #262626
bar_tag_background : #5F87AF
bar_block_foreground : #262626
bar_block_background : #AF5F5F
```

Workspace cells, script blocks, and button blocks use their own
foreground/background pairs, with the main bar background visible between
aligned blocks.

## Blocks and scripts

Block order is the order of repeated `bar_block` directives. Alignment may be
`left`, `center`, or `right`. If there are no `bar_block` directives, the bar
uses a single left-aligned workspace block.

```rc
bar_block : workspaces : left
bar_block : button : left : 󰀻 : "rofi -show drun"
bar_block : script : right : _ : 2 : 1 : "cut -d ' ' -f 1 /proc/loadavg"
bar_block : network : right : 󰤨
bar_block : bluetooth : right : 󰂯
bar_block : audio : right : 󰕾
bar_block : systray : right
bar_block : button : right : ⏻ : "rofi -show power-menu -modi power-menu:rofi-power-menu"
bar_block : script : right : clock : 1 : 1 : "date '+%H:%M'"
```

The `audio` block reads the default PipeWire/PulseAudio sink, toggles mute on
middle click, and changes volume in five-percent steps when the pointer is over
the block and the mouse wheel is scrolled. It uses `wpctl` when available and
falls back to `pactl`.

The `network` block reports the first active non-loopback interface name, uses
`󰤭 off` when disconnected, and opens `nm-connection-editor` on left click.
Middle click toggles the Wi-Fi radio. The `bluetooth` block reports its
connection state using its configured icon when connected and `󰂲` when
disconnected. The icon is followed by `on` or `off`. It opens
`blueman-manager` on left click, and middle click toggles Bluetooth power.
Muted audio replaces its configured icon with `󰝟` and displays `muted`.
Missing NetworkManager tooling uses the network-off state without blocking the
bar.

Audio, Network, and Bluetooth accept an optional final shell command for left
click. It replaces the Network/Bluetooth settings application; Audio has no
default left-click action. Commands may contain colons and should be quoted:

```rc
bar_block : audio : right : 󰕾 : "pavucontrol"
bar_block : network : right : 󰤨 : "rofi -show network"
bar_block : bluetooth : right : 󰂯 : "blueman-manager"
```

Every block can override its foreground and background. Use `_` to inherit one
of the global `bar_block_*` colours:

```rc
bar_block : workspaces : left : #0E0D0C : #917E6B
bar_block : network : right : 󰤨 : #FCE8C3 : #3C3836
bar_block : bluetooth : right : 󰂯 : #FCE8C3 : #3C3836
bar_block : audio : right : 󰕾 : #121110 : #D79921 : "pavucontrol"
bar_block : button : right : ⏻ : #FCE8C3 : #9D0006 : "rofi -show power-menu"
bar_block : script : right : clock : 1 : 1 : _ : #3C3836 : "date '+%H:%M'"
bar_block : systray : right : _ : #282828
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

Keep `bar_enabled : false` and start the external bar normally. skarwm still
manages EWMH dock windows and honors their struts; workspace/output IPC and EWMH
desktop state remain available.
