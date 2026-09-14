# Scrolling and drag/drop

## Scrollable strip

When more columns exist than fit on an output, the workspace becomes a
horizontal strip.

- `Super`+wheel down reveals columns to the right.
- `Super`+wheel up reveals columns to the left.
- A narrow continuation of the real neighboring window remains visible at
  each available edge. Hover it to reveal and focus that window.
- Edge space is reserved with the normal inner gap, so previews do not overlap
  visible columns.
- A maximized column remains full-width while scrolling and pushes its
  neighbors along the strip.

Scrolling is per output and does not change focus until an edge preview is
activated.

## Drag and drop

Hold `Super` and left-drag a tiled window. Crossing an edge target shows one
contextual overlay:

- Left/right creates or reorders a horizontal column at that position.
- Top/bottom inserts the window at the corresponding end of the selected
  vertical column.
- A drop can cross outputs; the destination output and workspace receive focus.

The overlay uses a translucent fill when a compositor is available and an
opaque outline otherwise. Resized column widths are retained when reordered.

For floating windows, `Super`+left-drag moves and `Super`+right-drag resizes.
