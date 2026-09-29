# Layouts and window actions

## Workspace layouts

`Super+g` / `layout_next` cycles the active workspace through five layouts:

- **Scrolling Tile** — the original hybrid tiled-column layout: up to two
  columns tile the work area and additional columns continue in a scrollable
  strip.
- **Vertical Scrolling Tile** — the transposed scroller: one selected row uses
  the work area while its previous/next rows peek from the top and bottom.
  Members grouped in one row tile left-to-right, and the vertical viewport is
  remembered per workspace.
- **Dwindle/Fibonacci** — all tiled windows recursively split the remaining
  work area, alternating left/right and top/bottom axes. It never scrolls.
- **Monocle** — the focused tiled window fills the work area; the others are
  parked off-screen until focused.
- **Floating** — all current tiled windows become floating, and new windows
  open floating until another workspace layout is selected. Automatically
  floated windows start at slightly offset, fully visible positions instead of
  overlapping exactly.

The choice belongs to the workspace, survives workspace switches, and applies
automatically to newly opened windows. Use `layout_scrolling_tile`,
`layout_vertical_scroller`, `layout_dwindle` (also `layout_fibonacci`), or
`layout_monocle` to select one directly; `layout_floating` selects
workspace-wide Floating. The older
`layout_scroller` name remains an alias. Dwindle and Monocle leave existing
stacked/tabbed column grouping intact when returning to Scrolling Tile.

`Super+Space` / `togglefloating` continues to affect only the focused window.
A window floated this way remains floating when the workspace enters and later
leaves its all-window Floating mode.

Workspace-wide Floating places and keeps its automatically floated windows
inside the reserved work area, including gaps beside left/right bars. Manually
positioned floating windows may still overlap panels intentionally.

## Columns

New tiled windows become horizontal columns. One column fills the work area;
two columns share it; additional columns continue along a scrollable strip.
Each column can contain a vertical stack of windows.

| Default binding | Action | Meaning |
|---|---|---|
| `Super+h/l` | `focusleft/right` | Focus the neighboring column. |
| `Super+j/k` | `focusdown/up` | Focus another window in the column. |
| `Super+Control+h/l` | `resizeleft/right` | Make the focused column narrower/wider. |
| `Super+Control+k/j` | `resizeup/down` | Make the focused row shorter/taller. |
| `Super+Shift+h/l` | `moveleft/right` | Move the window into a neighboring column. |
| `Super+Shift+j/k` | `movedown/up` | Reorder it vertically. |

## Stacked and tabbed columns

Stacked mode divides column height between its windows. Tabbed mode shows one
window at a time with a WM-owned tab bar.

- `Super+t` / `toggle_tabbed` toggles the focused column.
- `layout_tabbed` and `layout_stacked` select a mode directly.
- In tabbed mode, `Super+j/k` selects tabs and `Super+Shift+j/k` reorders them.
- `Super+Alt`+left-drag onto a tiled window joins its column and activates the
  dragged window as a tab.
- `Super`+left-drag on a tab header reorders the complete tabbed column while
  preserving its tabs and width.
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

The keyboard equivalent:
`Super+Control+h/l` makes the focused column 40 pixels narrower/wider, and
`Super+Control+k/j` makes its stacked row shorter/taller. Columns keep
independent widths at the outer strip edges; an adjacent column receives or
provides the horizontal space at a shared boundary. The other stacked rows
share remaining height proportionally.
These actions are configurable as `resizeleft`, `resizeright`, `resizeup`, and
`resizedown`.
