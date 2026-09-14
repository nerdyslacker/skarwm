# Layouts and window actions

## Columns

New tiled windows become horizontal columns. One column fills the work area;
two columns share it; additional columns continue along a scrollable strip.
Each column can contain a vertical stack of windows.

| Default binding | Action | Meaning |
|---|---|---|
| `Super+h/l` | `focusleft/right` | Focus the neighboring column. |
| `Super+j/k` | `focusdown/up` | Focus another window in the column. |
| `Super+Shift+h/l` | `moveleft/right` | Move the window into a neighboring column. |
| `Super+Shift+j/k` | `movedown/up` | Reorder it vertically. |

## Stacked and tabbed columns

Stacked mode divides column height between its windows. Tabbed mode shows one
window at a time with a WM-owned tab bar.

- `Super+t` / `toggle_tabbed` toggles the focused column.
- `layout_tabbed` and `layout_stacked` select a mode directly.
- In tabbed mode, `Super+j/k` selects tabs and `Super+Shift+j/k` reorders them.
- The otherwise-unbound Shift variant of a spawn binding opens the new window
  in the active tab group. With the default launcher this is `Super+Shift+Return`.
- Toggling a multi-window tab group off splits its tabs back into columns.

## Floating, maximize, and fullscreen

| Input | Action |
|---|---|
| `Super+Space` | Toggle the focused window between tiled and floating. |
| Middle-click | Maximize/restore inside the usable work area. |
| `Super+f` | Fullscreen/restore across the entire output, above bars. |
| `Super+Shift+q` | Ask the focused client to close. |

Maximize preserves tiled/floating membership and respects panel struts.
Fullscreen is borderless and temporarily hides the other workspace windows.

## Resizing

`Super`+right-drag resizes floating windows directly. On a tiled window it
moves the nearest boundary: neighboring columns resize as a pair, and windows
in a vertical stack follow their shared row boundary. Size hints and minimums
are respected. The resized column width survives new windows and drag/drop.
