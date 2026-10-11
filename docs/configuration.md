# Configuration

skarwm uses section-based `.conf` files. It loads the first existing path in
this order:

1. `skarwm -c FILE`
2. `$SKARWM_CONFIG`
3. `${XDG_CONFIG_HOME:-$HOME/.config}/skarwm/default.conf`
4. `/etc/skarwm/default.conf`

Without a file, built-in settings and bindings are used. Copy
[`assets/default.conf`](../assets/default.conf) and
[`assets/config.d`](../assets/config.d) for a complete starting point.

## Imports and merging

The root file imports modules in declaration order. Relative paths resolve
against the importing file; prefix a path with `?` when it is optional.

```ini
[import]
appearance = config.d/appearance.conf
local = ?config.d/local.conf
```

Imports may be nested. Cycles and missing required files are errors. Later
assignments override earlier scalar values. Named objects merge by identifier
without changing their original order.

Lines beginning with `#` or `;` are comments. Quoted keys and values decode
`\"` and `\\`; unquoted values preserve shell punctuation including `:`, `=`,
`%`, `$`, and `#`.

## Settings

```ini
[general]
mod_key = super

[window]
outer_gap = 8
inner_gap = 8
border_width = 2
corner_radius = 0
focus_follows_mouse = true

[window.border]
normal = #504D47
selected = #FCE8C3

[scroll]
preview_hover_delay_ms = 250

[animation]
enabled = true
duration_ms = 180
fps = 60
easing = ease_out_cubic
```

Decoration settings live under `[window.decoration]`. The complete palette and
defaults are in [`assets/config.d/appearance.conf`](../assets/config.d/appearance.conf).

## Commands and keybindings

`[bind]` launches shell commands. `[call]` invokes WM actions.
`[workspace.bindings]` switches workspaces or sends the focused window.

```ini
[bind]
"mod + Return" = st

[call]
"mod + f" = togglefullscreen
"mod + a" = focus class URxvt title VIM
"mod + m" = focus title "Music Player"

[workspace.bindings]
"mod + 1" = view 1
"mod + Shift + 1" = tag 1
```

See [`assets/config.d/keybindings.conf`](../assets/config.d/keybindings.conf)
for the complete annotated set.

## Named objects

### Workspaces

```ini
[workspace.1]
layout = scrolling-tile
icon = 󰈹
name = Web
```

Layouts are `scrolling-tile`, `vertical-scrolling-tile`, `dwindle`, `monocle`,
and `floating`. `fibonacci` is an alias for `dwindle`.

### Rules

```ini
[rule.firefox]
class = Firefox
workspace = 3
floating = false
decorate = true
```

A rule may match `class`, `instance`, or `title`. Effects are `workspace`,
`floating`, and `decorate`.

### Virtual screens

```ini
[virtual_screen.DP-1]
mode = split
ratio = 75
offset = -30
```

The ratio must be `10..90`; the optional offset adjusts the boundary in pixels.

### Bar blocks

Global block colors use `[bar.block]`; each named block uses
`[bar.block.NAME]`. Named blocks accept `type`, `position`, `foreground`, and
`background`, plus type-specific properties. Omit a color or set it to `_` to
inherit the corresponding global color.

```ini
[bar.block]
foreground = #0E0D0C
background = #C5B088

[bar.block.clock]
type = script
position = right
icon = 󰃭
interval = 1
timeout = 1
foreground = #FCE8C3
background = #3C3836
command = date '+%H:%M'
```

See [`assets/config.d/bar.conf`](../assets/config.d/bar.conf) and
[Built-in bar](bar.md) for every block type and property.

### Autostart

Each assignment under `[autostart]` is a named command. Commands run once at
startup and are not rerun on configuration reload.

```ini
[autostart]
background = xsetroot -solid '#202020'
```

## Reloading

skarwm watches the complete normalized import graph. Changes to the root,
nested imports, or creation of a missing optional import schedule an atomic
reload. `reload_config` performs the same operation on demand. An invalid
reload is reported while the active configuration remains unchanged.
