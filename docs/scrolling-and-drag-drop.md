# Scrolling and drag/drop

## Scrollable strip

When more columns exist than fit on an output, the workspace becomes a
horizontal strip.

- `Super`+wheel down reveals columns to the right.
- `Super`+wheel up reveals columns to the left.
- A narrow continuation of the real neighboring window remains visible at
  each available edge. Hover it to reveal and focus that window.
- Vertical-scroller previews use the same behavior at the top and bottom. If
  that edge is reserved by a bar, passive hover is suppressed so the pointer
  can reach the bar without changing focus; clicking the preview still reveals
  it.
- Edge space is reserved with the normal inner gap, so previews do not overlap
  visible columns.
- A maximized column remains full-width while scrolling and pushes its
  neighbors along the strip.

Scrolling is per output and does not change focus until an edge preview is
activated.

## Drag and drop

Hold `Super` and left-drag a tiled window. The tiled window under the pointer—or
the nearest visible one—becomes the drop anchor. An overlay covers the active half
of that target:

- Left/right inserts a horizontal column immediately before/after the target.
- Top/bottom inserts the window immediately above/below the target in its
  vertical column.
- A drop can cross outputs; the destination output and workspace receive focus.

Hold `Super+Alt` and left-drag onto a tiled window to join its column as a tab.
The full-window overlay identifies the destination, and the dragged window
becomes the active tab after the drop.

Hold `Super` and left-drag a tab header to move its complete tabbed column.
Dropping on the left or right half of another column inserts the group before
or after it without changing tab order, the active tab, or resized width.

The overlay uses a translucent fill when a compositor is available and an
opaque outline otherwise. Resized column widths are retained when reordered.

For floating windows, `Super`+left-drag moves and `Super`+right-drag resizes.
On tiled windows, `Super`+right-drag resizes the focused column and stacked row
from the side where the drag began. Moving outward grows that dimension;
moving inward shrinks it. A column across the selected boundary takes or gives
the same width, preserving the pair's place in the scrollable strip; an outer
strip edge remains independently resizable. The remaining stacked rows share
the leftover height proportionally.
