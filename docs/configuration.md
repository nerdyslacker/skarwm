# Configuration

skarwm loads the first existing configuration in this order:

1. `skarwm -c FILE`
2. `$SKARWM_CONFIG`
3. `$XDG_CONFIG_HOME/skarwm/config.rc`
4. `~/.config/skarwm/config.rc`
5. `/etc/skarwm/config.rc`

Without a file, built-in settings and bindings are used. Copy
[`assets/example.rc`](../assets/example.rc) for a complete starting point.

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
| `focus_follows_mouse : true` | Focus a window when the pointer enters it. |
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
| `bar_tag_count : 8` | Fixed workspace slots shown on every monitor, `1..64`. |
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
call : mod + Control + Alt + h : show_bindings
call : mod + Control + Alt + t : show_datetime
call : mod + Control + Alt + b : show_battery
call : mod + Control + r : reminder_new
call : mod + Control + Alt + r : reminder_show_all
call : mod + Control + Shift + r : reminder_clear_all
workspace : mod + 1 : view 1
workspace : mod + Shift + 1 : tag 1
autostart : "xsetroot -solid '#202020'"
bar_block : workspaces : left
bar_block : systray : right
bar_block : script : right : clock : 1 : 1 : "date '+%H:%M'"
rule : class : Firefox : workspace 3 floating
```

`bind` launches a shell command. `call` invokes a WM action. `workspace view`
switches workspace and `workspace tag` sends the focused window. `autostart`
runs once at startup and is not run again by configuration reloads.

`bar_block` directives define the built-in bar's blocks in declaration order.
Workspace and `systray` blocks take an alignment. Script blocks additionally
take a name, interval in seconds, timeout in seconds, and a shell command. See
[Built-in bar](bar.md) for limits, failure handling, and security details.

Rules use a substring match against `class`, `instance`, or `title`. Effects are
`workspace N`, `floating`, and `floating true|false`; the first matching rule is
used.

`Super+Shift+r` runs `reload_config`. Reload is atomic: malformed input leaves
the active configuration unchanged.
