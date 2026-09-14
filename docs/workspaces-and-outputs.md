# Workspaces and outputs

Workspaces use positive numeric IDs and are created on demand. Each RandR
monitor keeps its own visible workspace and remembered focus.

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
