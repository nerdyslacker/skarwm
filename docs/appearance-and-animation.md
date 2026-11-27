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

Animations interpolate client geometry and border changes using real elapsed
time. New windows grow into their assigned rectangle; layout moves, window
reordering, and scroller viewport changes slide and resize existing windows.
Clients entering or leaving a viewport transition through the nearest monitor
edge instead of travelling to or from the off-screen parking coordinate.

WM-initiated closes shrink the client before sending `WM_DELETE_WINDOW` (or
killing a client that does not support it). If the client stays open—for
example, to show a save prompt—it returns to its normal rectangle. A client
that destroys its own X11 window closes immediately because there is no window
left to animate without a compositor snapshot.

Tabbed visibility changes, fullscreen clients, docks, minimized clients, and
interactive pointer resize previews remain immediate where intermediate
geometry would violate their existing behavior. `ease_out_cubic` moves quickly
then settles; `linear` uses constant progress. Set `animations : false` or
duration `0` for immediate changes. Frames are scheduled only while a
transition is active.
