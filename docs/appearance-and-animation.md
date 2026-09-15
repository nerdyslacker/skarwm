# Appearance and animation

All visual settings reload at runtime:

```rc
outer_gap : 8
inner_gap : 8
border_width : 2
corner_radius : 10
norm_outer_border : #504D47
sel_outer_border : #FF5F00

animations : true
animation_duration_ms : 180
animation_fps : 60
animation_easing : ease_out_cubic
```

`outer_gap` surrounds the work area and `inner_gap` separates windows. `gap`
sets both at once. Only the focused window draws `border_width`; unfocused
windows reserve the same inset without drawing it, so focus changes alter
neither client size nor gaps. Set `border_width : 0` to disable both the border
and its reserved inset, allowing client surfaces to occupy the complete tile.
`sel_outer_border` is its `#RRGGBB` colour. `norm_outer_border` remains accepted
for configuration compatibility.

A positive `corner_radius` shapes normal client windows and keeps the border
thickness consistent around the curve. `0` restores square windows. Fullscreen
windows and docks/bars remain square.

Animations interpolate layout geometry and border changes using real elapsed
time. `ease_out_cubic` moves quickly then settles; `linear` uses constant
progress. Set `animations : false` or duration `0` for immediate changes.
