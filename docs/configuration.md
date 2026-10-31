# Configuration

skarwm loads the first existing configuration in this order:

1. `skarwm -c FILE`
2. `$SKARWM_CONFIG`
3. `$XDG_CONFIG_HOME/skarwm/skarwm.rc`
4. `$XDG_CONFIG_HOME/skarwm/config.rc` (legacy fallback)
5. `~/.config/skarwm/skarwm.rc`
6. `~/.config/skarwm/config.rc` (legacy fallback)
7. `/etc/skarwm/skarwm.rc`
8. `/etc/skarwm/config.rc` (legacy fallback)

Without a file, built-in settings and bindings are used. Copy
[`assets/example.rc`](../assets/example.rc) for a complete starting point.
Lines beginning with `#` are comments.

## Imports

The main configuration can optionally include other rc files at any point:

```text
import : config.d/keybindings.rc
import : config.d/rules.rc
```

skarwm resolves relative paths from the directory containing the `import`
directive, including inside nested imports. It accepts absolute and quoted
paths. skarwm processes imported content in place, so later settings override
earlier settings.

Imports can nest. A cycle or unreadable file rejects the reload and leaves the
running configuration unchanged. skarwm watches the main file and each import
for changes. A single `skarwm.rc` works without imports.

## Settings

| Setting | Meaning |
|---|---|
| `mod_key : super` | Modifier represented by `mod` in bindings. |
| `outer_gap : 8` | Space around the output work area. |
| `inner_gap : 8` | Space between columns and stacked windows. |
| `gap : 8` | Convenience value that sets both gaps. |
| `border_width : 2` | Focused-window border width; `0` disables borders and their reserved inset. |
| `corner_radius : 0` | Rounded-corner radius; `0` disables shaping. |
| `norm_outer_border : #504D47` | Compatibility colour; unfocused borders are hidden. |
| `sel_outer_border : #FF5F00` | Focused border colour. |
| `decorations_enabled : false` | Opt in to skarwm-owned client titlebars and frames. |
| `decoration_titlebar_height : 20` | Compact titlebar height in pixels, `16..128`. |
| `decoration_border_width : border_width` | Painted decoration frame width, `0..32`; inherits `border_width` when omitted. |
| `decoration_resize_hit_width : 4` | Edge/corner input target width, `1..32`; independent of the painted width. |
| `decoration_show_title : true` | Draw the client title when the decoration renderer is enabled. |
| `decoration_audio_enabled : false` | Opt in to per-application audio discovery for decorated windows. Missing PulseAudio or pipewire-pulse is harmless. |
| `decoration_audio_show_percentage : true` | Show the volume percentage when the titlebar has room. |
| `decoration_audio_slider_width : 90` | Inline volume slider width in logical pixels, `70..100`. |
| `decoration_audio_volume_step : 5` | Percentage-point change for the mouse wheel, `1..25`. |
| `decoration_color_source : active-border` | Style source: `active-border`, `accent`, or `explicit`. |
| `decoration_accent : #89B4FA` | Accent used by the `accent` source. |
| `decoration_active_background : #313244` | Explicit active titlebar background. |
| `decoration_inactive_background : #1E1E2E` | Explicit inactive titlebar background. |
| `decoration_active_foreground : #FFFFFF` | Active title foreground. |
| `decoration_inactive_foreground : #A6ADC8` | Inactive title foreground. |
| `decoration_active_border : #89B4FA` | Explicit active frame colour. |
| `decoration_inactive_border : #45475A` | Explicit inactive frame colour. |
| `focus_follows_mouse : true` | Focus a window when the pointer enters it. |
| `preview_hover_delay_ms : 250` | Delay before a stationary pointer reveals a scroll preview, `0..5000`. |
| `animations : true` | Enable layout transitions. |
| `animation_duration_ms : 180` | Transition duration, `0..5000`. |
| `animation_fps : 60` | Animation target rate, `1..240`. |
| `animation_easing : ease_out_cubic` | `linear` or `ease_out_cubic`. |
| `bar_enabled : false` | Launch the optional built-in `skarwm-bar`; disabled by default. |
| `bar_position : top` | Place the built-in bar at `top` or `bottom`. |
| `bar_height : 26` | Bar height in pixels, `1..512`. |
| `bar_font : monospace` | Fontconfig family used by the built-in bar. |
| `bar_font_size : 11` | Bar font size in points, `6..72`. |
| `bar_font_weight : normal` | Default text weight: `normal`, `medium`, or `bold`. |
| `bar_foreground : #E6E6E6` | Built-in bar text colour. |
| `bar_background : #1E1E2E` | Built-in bar background colour. |
| `bar_tag_count : 8` | Fixed workspace slots shown by the built-in bar and exported to EWMH pagers on every monitor, `1..64`. |
| `bar_tag_foreground : #262626` | Workspace-slot text colour. |
| `bar_tag_background : #5F87AF` | Workspace-slot wrapper colour. |
| `bar_block_foreground : #262626` | Script/status block text colour. |
| `bar_block_background : #AF5F5F` | Script/status block wrapper colour. |

See [Built-in bar](bar.md) for the current implementation status and manual
launch options.

## Directives

```rc
bind : mod + Return : "xterm"
call : mod + f : togglefullscreen
call : mod + g : layout_next
call : mod + Control + Alt + h : show_bindings
call : mod + Control + Alt + t : show_datetime
call : mod + Control + Alt + b : show_battery
call : mod + Control + r : reminder_new
call : mod + Control + Alt + r : reminder_show_all
call : mod + Control + Shift + r : reminder_clear_all
workspace : mod + 1 : view 1
workspace : mod + Shift + 1 : tag 1
workspace-3 : dwindle : 󰕮 : Code
autostart : "xsetroot -solid '#202020'"
bar_block : workspaces : left
workspace-1 : scrolling-tile : 󰈹 : Web
bar_block : layout : left
bar_block : title : center
bar_block : systray : right
bar_block : clock : right
bar_block : network : right
bar_block : bluetooth : right
bar_block : audio : right
bar_block : battery : right
virtual_screen : DP-1 : split : 75 : -30
rule : class : Firefox : workspace 3 floating decorate false
```

`bind` launches a shell command. `call` invokes a WM action. `workspace view`
switches workspace and `workspace tag` sends the focused window. `autostart`
runs once at startup and is not run again by configuration reloads.

The `focus` action accepts `class`, `instance`, and `title` criteria. It uses
case-sensitive substring matches, combines criteria with AND, and cycles
through matches on repeat presses. It skips docks and hidden scratchpads.

```rc
call : mod + a : focus class URxvt title VIM
call : mod + m : focus title "Music Player"
```

`workspace-ID : LAYOUT : ICON [: NAME]` gives that workspace/tag a persistent
layout on every output and configures its bar icon plus optional hover name.
skarwm accepts `workspace_ID` as an equivalent spelling. Supported names are
`scrolling-tile`, `vertical-scrolling-tile`, `game`, `dwindle` (`fibonacci` is an
alias), `monocle`, and `floating`. skarwm creates and updates matching
workspaces when the configuration loads, so new windows use the declared
layout. A manual layout selection may override it until the next reload.

The older layout-only directives remain available so existing configurations
continue to load:

```rc
workspace_layout : 3 : dwindle
# Equivalent deprecated spelling:
tag_layout : 4 : monocle
```

Both `workspace_layout` and `tag_layout` are deprecated and will be removed in
a future release. Use `workspace-ID : LAYOUT : ICON [: NAME]` for new
configurations.

Workspace-wide layout actions are `layout_scrolling_tile`,
`layout_vertical_scroller`, `layout_game`, `layout_dwindle`
(`layout_fibonacci` is an alias), `layout_monocle`, `layout_floating`, and
`layout_next`. The last one cycles Scrolling Tile → Vertical Scrolling Tile →
Game → Dwindle/Fibonacci → Monocle → Floating and is bound to `Super+g` by the built-in defaults.
`layout_scroller` remains a compatibility alias. `togglefloating` changes only
the focused window. `togglealwaysontop` toggles the above layer for a focused
floating window and has no effect on tiled windows. Returning the window to
tiling clears the state. Always-on-top borders and titlebar pins use
`decoration_accent`, which defaults to blue.

`virtual_screen` declares a horizontal logical split for a named physical
RandR output. The split is a percentage from 10 through 90; the optional final
field adjusts the boundary by signed pixels. The example uses 75% minus 30
pixels for the left screen and the exact remainder for the right. Geometry is
recomputed from the current physical output after resolution changes. Profiles
for disconnected outputs are retained and applied when that output appears.
Duplicate output profiles and profiles that cannot satisfy the 160-pixel
minimum on a connected output reject the whole reload.

The same feature is bindable without a declarative profile:

```rc
call : mod + F5 : screen_split_shrink 15
call : mod + F6 : screen_split_disable
call : mod + F7 : screen_split_enable 75
call : mod + F8 : screen_split_grow 15
```

`bar_block` directives define the built-in bar's blocks in declaration order.
Workspace, layout, title, and `systray` blocks take an alignment. A workspace
declaration uses `workspace-ID : LAYOUT : ICON [: NAME]` (or `workspace_ID`):
it sets the workspace layout and changes the corresponding workspace cell
without rendering a block. Other blocks take an alignment followed by their
label, colours, or command. Use `_` to inherit a global colour or omit a script
label. See [Built-in bar](bar.md) for field order, examples, actions, limits,
and failure handling.

Rules use a substring match against `class`, `instance`, or `title`. Effects are
`workspace N`, `floating`, `floating true|false`, `decorate`, and
`decorate true|false`; the first matching rule is used. A decoration rule
overrides the global `decorations_enabled` value for that client.

Titlebar audio matching fails closed. When Pulse supplies process metadata,
skarwm verifies the live local PID, start time, executable, host, and machine.
Native PipeWire streams can lose their PID in the Pulse compatibility view; in
that case skarwm accepts the stream only when its application identity resolves
to exactly one same-user local process. An exact Pulse X11 window ID is used
only after process verification. For terminal and helper processes, the stream
may match a verified ancestor process that owns exactly one decorated window.
Reused PIDs, remote streams, duplicate processes, and multi-window ambiguity
are hidden. Multiple verified writable streams for one window are grouped,
with the highest channel-average volume displayed and mixed mute state retained.

Click the speaker to mute, click or drag the slider to set volume, and use the
mouse wheel over the widget for `decoration_audio_volume_step` changes. These
actions affect only the matched Pulse sink inputs, never the default sink or
master output. Relative channel and grouped-stream levels are preserved where
possible, and volume is capped at 100%.

The widget appears only while a matched playback stream exists. An idle
terminal therefore has no widget; start playback in the terminal (including a
TUI player) to make it appear. Xephyr does not isolate PulseAudio or
PipeWire-Pulse, so it does not prevent discovery. After rebuilding, restart the
nested skarwm process. For matching diagnostics, run:

```sh
make
SKARWM_LOG=debug make xephyr
```

Look for `titlebar audio:` messages in the launching terminal. They report
whether the stream was verified, rejected for incomplete or non-local process
metadata, or left unmatched.

### Titlebar audio verification

| Check | Result |
| --- | --- |
| Disabled by default | No audio connection, subscription, timer, or decoration resource is created. |
| PipeWire-Pulse playback | VLC, Elisa, native PipeWire mpv, and mpv inside kitty were matched and rendered in a nested X server. |
| Controls | Slider changes persisted on the sink input; speaker click muted it; master volume remained unchanged. |
| Idle cost, disabled / enabled | 0 CPU ticks over 5 seconds in both cases; RSS 3,180 / 5,364 KiB. |
| 500 IPC window queries, disabled / enabled | 418 / 433 ms; one WM CPU tick in both cases. |
| Core and audio tests | 997 core and 38 audio tests passed. |
| X11 regression tests | 131 main, 28 XRandR, and 18 decoration checks passed. |

Native PulseAudio was not available for this verification. Matching also
intentionally hides PID-less streams whose application identity matches zero or
multiple local processes, detached players outside the window owner's process
ancestry, remote streams, and ambiguous owners of multiple decorated windows.
A paused stream remains visible while the server keeps it; the widget
disappears when the last matching stream is removed.

skarwm watches the main configuration and its imports, including editor saves
that replace a file. `Super+Shift+r` runs `reload_config` on demand. Reload is
atomic: malformed input leaves the active configuration unchanged.
