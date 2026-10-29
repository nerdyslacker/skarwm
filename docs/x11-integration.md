# X11 integration

skarwm implements the EWMH/ICCCM subset used by normal applications, panels,
launchers, and tools such as `wmctrl`:

- client list, active window, desktop count/current desktop, and work areas;
- desktop names and per-output viewports for external workspace pagers;
- fullscreen, floating always-on-top, and paired horizontal/vertical maximize state;
- close-window and activation requests;
- `WM_DELETE_WINDOW`, `WM_TAKE_FOCUS`, urgency, titles, and normal size hints.

skarwm manages `_NET_WM_WINDOW_TYPE_DOCK` windows as output-level bars. Their
struts reserve tiling space, they remain visible across workspace switches, and
they stay above ordinary windows. A fullscreen client covers the output above
the dock. If a panel publishes its dock type after mapping, skarwm removes it
from provisional tiling and restores its original geometry. skarwm keeps dock
surfaces inside their physical output. It allows partial off-screen placement
only for floating windows.

skarwm floats windows marked with `_NET_WM_WINDOW_TYPE_DIALOG`,
`_NET_WM_STATE_MODAL`, or ICCCM `WM_TRANSIENT_FOR` and centers them over their
managed parent, or over the output work area when no concrete parent is
available. skarwm preserves their requested size within the usable work area.
This behavior also applies when a toolkit publishes the hint shortly after
mapping, which keeps polkit authentication agents and file choosers from GTK,
KDE, Xfce, and other XDG Desktop Portal backends stable without
backend-specific rules.

skarwm supports `_NET_WM_STATE_ABOVE` for floating clients. Above clients remain
over ordinary workspace windows and below docks/fullscreen windows. Requests
for tiled clients are ignored, and re-tiling an above client clears the state.

Focus follows the pointer by default:

```rc
focus_follows_mouse : true
```

Set it to `false` for keyboard/click-directed focus. Dock windows never receive
normal client focus.

Window rules run when a client is managed:

```rc
rule : class : Pavucontrol : floating
rule : instance : firefox : workspace 3
rule : title : "Picture in picture" : workspace 2 floating
```

For automation and bars, use the nonblocking i3-compatible socket documented in
[ipc.md](ipc.md).

## External bars and workspace pagers

skarwm exposes `bar_tag_count` workspace slots per logical output through EWMH.
The default is eight. Each `(output, workspace)` pair receives its own global
EWMH desktop index, while `_NET_DESKTOP_VIEWPORT` maps that index back to the
output geometry. `_NET_WM_DESKTOP` is kept current on every managed window, so
external pagers can distinguish occupied and empty workspaces. Pager requests
can switch desktops or move a window to another desktop.

Polybar's `internal/xworkspaces` module works directly with these properties.
For one bar per monitor, enable monitor grouping and pinning:

```ini
[module/xworkspaces]
type = internal/xworkspaces
group-by-monitor = true
pin-workspaces = true
enable-click = true
enable-scroll = true

[settings]
; Let picom composite transparent borders and rounded corners. Pseudo
; transparency falls back to black when no compatible root pixmap exists.
pseudo-transparency = false
```

Start a compositor such as picom before Polybar when using transparent borders
or rounded corners. Without a compositor, set `pseudo-transparency = true` and
set the wallpaper with a root-pixmap-aware tool such as `feh` or `nitrogen`.
`xsetroot -solid` does not provide the pixmap Polybar needs for pseudo-
transparency, so transparent corner pixels otherwise appear black.

Desktop names default to `1`, `2`, and so on. A configured workspace name is
published when present:

```rc
workspace : 1 : scrolling-tile : 󰈹 : web
workspace : 2 : scrolling-tile :  : terminal
```

tint2 needs no skarwm-specific adapter. Its `multi_desktop` taskbar mode uses
the same desktop, client-list, and client-desktop properties; workspace clicks
and task moves are accepted by skarwm.

lemonbar is a renderer rather than an EWMH workspace module. Run it in dock
mode so it publishes its dock type/strut, and feed workspace state from
`skarwm-msg get-workspaces` or the workspace/window/output IPC subscriptions
described in [ipc.md](ipc.md). Click handlers can call, for example,
`skarwm-msg workspace 3`.
