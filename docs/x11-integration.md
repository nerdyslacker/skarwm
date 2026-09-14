# X11 integration

skarwm implements the EWMH/ICCCM subset used by normal applications, panels,
launchers, and tools such as `wmctrl`:

- client list, active window, desktop count/current desktop, and work areas;
- fullscreen and paired horizontal/vertical maximize state;
- close-window and activation requests;
- `WM_DELETE_WINDOW`, `WM_TAKE_FOCUS`, urgency, titles, and normal size hints.

`_NET_WM_WINDOW_TYPE_DOCK` windows are managed as output-level bars rather than
workspace clients. Their struts reserve tiling space, they remain visible across
workspace switches, and they stay above ordinary windows. A fullscreen client
is raised above the dock and covers the complete output.

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
