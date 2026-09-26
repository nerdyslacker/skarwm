# Workspaces and outputs

Workspaces use positive numeric IDs and are created on demand. Each logical
screen keeps its own visible workspace, scrolling viewport, and remembered
focus. Normally one logical screen covers each RandR monitor; an ultrawide can
be split into two independent logical screens.

| Default binding | Action |
|---|---|
| `Super+1` … `Super+9` | Show workspace 1 … 9. |
| `Super+Shift+1` … `Super+Shift+9` | Send the focused window there. |
| `Super+n/p` | Show the next/previous workspace ID. |
| `Super+Control+n/p` | Send the focused window to next/previous. |
| `Super+,/.` | Focus the previous/next output. |
| `Super+Shift+,/.` | Send the focused window to previous/next output. |

Equivalent action names include `ws_next`, `ws_prev`, `tag_next`, `tag_prev`,
`focus_output_next|prev`, and `move_to_output_next|prev`.

Outputs come from RandR 1.5 monitor objects, so named and split monitors are
handled independently. Output selection wraps. New windows open on the output
under the pointer; moving a window to another output uses that output's current
workspace.

A WM-level split does not create synthetic RandR monitors. For physical
`DP-1`, the stable logical IDs are `DP-1:left` and `DP-1:right`. Fullscreen,
workareas, pointer selection, workspace navigation, and scrolling all use the
logical geometry. Removing a split migrates secondary workspace contents to
matching workspace IDs on the surviving screen and remembers the secondary's
selected workspace for the next split.

See [Configuration](configuration.md) for declarative profiles and
[IPC](ipc.md) for runtime toggle, ratio, and boundary commands.
