# Built-in bar

`skarwm-bar` is an optional standalone process. It is disabled by default, so
external docks and desktop shells continue to work without any built-in bar
process or reserved space.

Enable the managed bar in `config.rc`:

```rc
bar_enabled : true
bar_position : top
bar_height : 26
```

The WM launches `skarwm-bar`, or the executable named by `$SKARWM_BAR`. During
development it uses `build/skarwm-bar` when that file exists. Reloading the WM
configuration updates the position and height; disabling the bar makes a
managed instance exit and removes its struts.

The binary can also be run independently:

```sh
skarwm-bar --position bottom --height 30
```

It creates one dock window per active RandR 1.5 monitor, follows geometry
changes, and publishes both
`_NET_WM_STRUT` and `_NET_WM_STRUT_PARTIAL`. skarwm converts those root-relative
struts to per-output reserved insets, so tiled and maximized windows use the
remaining workarea.

The first reusable block is `workspaces`, aligned on the left. It receives
workspace, window, and output events through the existing i3-compatible IPC
socket and refreshes from `GET_WORKSPACES`; there is no render-loop polling.
The active workspace is inverted, occupied workspaces carry `+`, and urgent
workspaces carry `!`. Left-click switches that workspace on the clicked
monitor; wheel up/down selects the adjacent numeric workspace. The IPC client
reconnects after WM restarts.

Foreground and background are configurable:

```rc
bar_foreground : #E6E6E6
bar_background : #1E1E2E
```

## Blocks and scripts

Block order is the order of repeated `bar_block` directives. Alignment may be
`left`, `center`, or `right`. If there are no `bar_block` directives, the bar
uses a single left-aligned workspace block.

```rc
bar_block : workspaces : left
bar_block : script : right : load : 2 : 1 : "cut -d ' ' -f 1 /proc/loadavg"
bar_block : systray : right
bar_block : script : right : clock : 1 : 1 : "date '+%H:%M'"
```

Script fields after the alignment are `name`, update interval in seconds,
timeout in seconds, and command. Intervals are `1..86400`; timeouts are
`1..60`. Commands deliberately run through `/bin/sh -c` with the user's
permissions so shell pipelines and quoting work. Do not place untrusted text in
these commands.

Each script has its own timer and is never launched by the render path. Output
is limited to 4 KiB, trailing whitespace is removed, and embedded control
characters are made display-safe. A non-zero exit displays `error`; a command
that exceeds its timeout displays `timeout`. The entire command process group
is stopped on timeout, bar shutdown, or configuration reload.

Changing block definitions and reloading skarwm rebuilds the blocks without
restarting the WM. The managed bar receives the ordered definitions through
the versioned `_SKARWM_BAR_BLOCKS` root property.

## System tray

The `systray` block implements the X11 system-tray and XEmbed protocols. It
owns `_NET_SYSTEM_TRAY_Sn`, announces itself with `MANAGER`, accepts dock
requests, reparents and sizes icons, and uses the X save set so icons survive a
bar-window rebuild. Destroyed and withdrawn icons are removed from layout.

X11 permits one tray owner per screen. On a multi-monitor X screen, the tray is
therefore shown on the first active RandR monitor; other monitors still get
their own workspace and script blocks. If another tray already owns the
selection, `skarwm-bar` leaves it alone and renders no tray icons.

## External bars

Keep `bar_enabled : false` and start the external bar normally. skarwm still
manages EWMH dock windows and honors their struts; workspace/output IPC and EWMH
desktop state remain available.
