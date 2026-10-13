# X11 integration

skarwm implements the EWMH/ICCCM subset used by normal applications, panels,
launchers, and tools such as `wmctrl`:

- client list, active window, desktop count/current desktop, and work areas;
- desktop names and owner-aware viewports for external workspace pagers;
- fullscreen, floating always-on-top, and paired horizontal/vertical maximize state;
- close-window and activation requests;
- `WM_DELETE_WINDOW`, `WM_TAKE_FOCUS`, urgency, titles, and normal size hints.

`_NET_WM_WINDOW_TYPE_DOCK` windows are managed as output-level bars rather than
workspace clients. Their struts reserve tiling space, they remain visible across
workspace switches, and they stay above ordinary windows. A fullscreen client
is raised above the dock and covers the complete output. Panels that publish
their dock type immediately after mapping are promoted out of provisional
tiling and restored to their original pre-layout geometry. Dock surfaces are
kept fully inside their physical output; the partial off-screen allowance used
for manually moved floating windows is never applied to panels.

`_NET_WM_WINDOW_TYPE_DIALOG`, `_NET_WM_STATE_MODAL`, and ICCCM
`WM_TRANSIENT_FOR` windows are floated automatically and centered over their
managed parent, or over the output work area when no concrete parent is
available. Their requested size is preserved within the usable work area. This
behavior also applies when a toolkit publishes the hint shortly after mapping,
which keeps polkit authentication agents and file choosers from GTK, KDE, Xfce,
and other XDG Desktop Portal backends stable without backend-specific rules.

`_NET_WM_STATE_ABOVE` is supported for floating clients. Above clients remain
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

skarwm exposes `bar_tag_count` global workspace slots through EWMH. The default
is eight, and workspace `N` maps to EWMH desktop `N - 1` regardless of which
screen currently owns it. `_NET_DESKTOP_VIEWPORT` and `_NET_WORKAREA` follow
the workspace's owning screen. `_NET_WM_DESKTOP` is kept current on every
managed window, and pager requests can show a workspace or move a window to it.

Polybar's `internal/xworkspaces` module works directly with these properties.
For one bar per monitor, enable monitor grouping and pinning; a workspace moves
between bars when its owning screen changes:

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
