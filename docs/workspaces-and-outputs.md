# Workspaces and outputs

Workspaces use positive numeric IDs and are created on demand. Each logical
screen shows one workspace from the shared desktop and remembers its focus.
Visible workspace IDs are unique across screens. Selecting a workspace already
visible elsewhere focuses that screen; it does not duplicate or steal the
workspace. A newly added logical screen receives the lowest workspace ID not
currently visible. Normally one logical screen covers each Xinerama region;
an ultrawide can be split into two logical screens.

Showing a hidden workspace on another screen transfers that same workspace
object rather than copying it. Its clients, layout, viewport, and remembered
focus move with it. Removing a screen likewise migrates whole workspaces to a
survivor, so reconnecting or restoring a virtual split can reuse their state.

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

Directional actions are `focus_output_left|right|up|down` and
`move_to_output_left|right|up|down`. `focus_output_order` and
`move_to_output_order` accept a one-based spatial index, making XMonad-like
`mod-{w,e,r}` bindings opt-in without replacing existing user bindings. IPC
uses `focus output TARGET` and `move output TARGET`, where `TARGET` is a
direction, `next`, `prev`, or a one-based index. Directional selection first
prefers screens intersecting the source screen's perpendicular span, then uses
edge distance, perpendicular gap, center distance, and spatial order.

Physical screen regions come from Xinerama. RandR events request a new
Xinerama query but never supply the managed rectangles. If Xinerama is absent
or inactive, skarwm reports and uses one root-sized degraded screen. Output
selection wraps in spatial left-to-right order. New windows open on the output
under the pointer; moving a window to another output uses that output's current
workspace. Sending a window to a workspace already visible on another output
moves it to that output without changing the focused output.

Xinerama has no connector names or persistent IDs. skarwm assigns session IDs
such as `xinerama-1` and preserves them best-effort across refreshes using exact
geometry, overlap, then center proximity. Identical rectangles and rectangles
fully contained by another are collapsed; distinct partial overlaps remain.

A WM-level split does not depend on a RandR monitor as its discovery source.
For physical `xinerama-1`, the logical IDs are `xinerama-1:left` and
`xinerama-1:right`. The logical screens are projected to RandR for external
monitor-aware clients, while skarwm continues using its own state. Fullscreen,
workareas, pointer selection, workspace navigation, and scrolling all use the
logical geometry. Removing a split migrates secondary workspace contents to
the surviving screen and remembers the secondary's selected workspace for the
next split.

See [Configuration](configuration.md) for declarative profiles and
[IPC](ipc.md) for runtime toggle, ratio, and boundary commands.
