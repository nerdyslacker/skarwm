# Configuration

skarwm loads the first existing configuration in this order:

1. `skarwm -c FILE`
2. `$SKARWM_CONFIG`
3. `$XDG_CONFIG_HOME/skarwm/config.rc`
4. `~/.config/skarwm/config.rc`

Without a file, built-in settings and bindings are used. Copy
[`assets/example.rc`](../assets/example.rc) for a complete starting point.

## Settings

| Setting | Meaning |
|---|---|
| `mod_key : super` | Modifier represented by `mod` in bindings. |
| `outer_gap : 8` | Space around the output work area. |
| `inner_gap : 8` | Space between columns and stacked windows. |
| `gap : 8` | Convenience value that sets both gaps. |
| `border_width : 2` | Managed-window border width. |
| `corner_radius : 0` | Rounded-corner radius; `0` disables shaping. |
| `norm_outer_border : #504D47` | Unfocused border colour. |
| `sel_outer_border : #FF5F00` | Focused border colour. |
| `focus_follows_mouse : true` | Focus a window when the pointer enters it. |
| `animations : true` | Enable layout transitions. |
| `animation_duration_ms : 180` | Transition duration, `0..5000`. |
| `animation_fps : 60` | Animation target rate, `1..240`. |
| `animation_easing : ease_out_cubic` | `linear` or `ease_out_cubic`. |

## Directives

```rc
bind : mod + Return : "xterm"
call : mod + f : togglefullscreen
workspace : mod + 1 : view 1
workspace : mod + Shift + 1 : tag 1
autostart : "xsetroot -solid '#202020'"
rule : class : Firefox : workspace 3 floating
```

`bind` launches a shell command. `call` invokes a WM action. `workspace view`
switches workspace and `workspace tag` sends the focused window. `autostart`
runs once at startup and is not run again by configuration reloads.

Rules use a substring match against `class`, `instance`, or `title`. Effects are
`workspace N`, `floating`, and `floating true|false`; the first matching rule is
used.

`Super+Shift+r` runs `reload_config`. Reload is atomic: malformed input leaves
the active configuration unchanged.
