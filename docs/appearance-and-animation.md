# Appearance and animation

All visual settings reload at runtime:

```ini
[window]
outer_gap = 8
inner_gap = 8
border_width = 2
corner_radius = 10

[window.border]
normal = #504D47
selected = #FF5F00

[animation]
enabled = true
duration_ms = 180
fps = 60
easing = ease_out_cubic
```

`outer_gap` surrounds the work area and `inner_gap` separates windows. `gap`
sets both at once. Only the focused window draws `border_width`; unfocused
windows reserve the same inset without drawing it, so focus changes alter
neither client size nor gaps. Set `border_width = 0` to disable both the border
and its reserved inset, allowing client surfaces to occupy the complete tile.
`window.border.selected` is its `#RRGGBB` colour.

A positive `corner_radius` shapes normal client windows and keeps the border
thickness consistent around the curve. `0` restores square windows. Fullscreen
windows and docks/bars remain square.

Animations interpolate layout geometry and border changes using real elapsed
time. `ease_out_cubic` moves quickly then settles; `linear` uses constant
progress. Set `animation.enabled = false` or duration `0` for immediate changes.
