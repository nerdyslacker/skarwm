# Configuration migration inventory

This document records the compatibility contract for the transition from the
legacy `config.rc` grammar to the section-based `default.conf` grammar. The
legacy parser remains available during the transition.

The new parser accepts full-line `#` and `;` comments. It does not treat comment
characters inside assignment values as comments. Quoted keys and values decode
only `\"` and `\\`; every other backslash is preserved literally. Unquoted
values retain `:`, `=`, `%`, `$`, `#`, and other shell punctuation.

## Settings

| Legacy key | New assignment | Accepted values / current default |
|---|---|---|
| `mod_key`, `modkey` | `[general] mod_key` | X modifier name; `Mod4` |
| `gap` | `[window] gap` | Integer alias that seeds both gaps; unset (`0`) |
| `outer_gap` | `[window] outer_gap` | Integer; `8` |
| `inner_gap` | `[window] inner_gap` | Integer; `8` |
| `border_width` | `[window] border_width` | `0..4096`; `2` |
| `corner_radius` | `[window] corner_radius` | `0..4096`; `0` |
| `focus_follows_mouse` | `[window] focus_follows_mouse` | Boolean; `true` |
| `preview_hover_delay_ms` | `[scroll] preview_hover_delay_ms` | `0..5000`; `250` |
| `norm_outer_border` | `[window.border] normal` | `#RRGGBB`; `#3A3A3A` |
| `sel_outer_border` | `[window.border] selected` | `#RRGGBB`; `#E0AF68` |
| `decorations_enabled` | `[window.decoration] enabled` | Boolean; `false` |
| `decoration_titlebar_height`, `titlebar_height` | `[window.decoration] titlebar_height` | `16..128`; `20` |
| `decoration_border_width` | `[window.decoration] border_width` | `0..32`; `1` |
| `decoration_resize_hit_width` | `[window.decoration] resize_hit_width` | `1..32`; `4` |
| `decoration_show_title` | `[window.decoration] show_title` | Boolean; `true` |
| `decoration_color_source` | `[window.decoration] color_source` | `active-border`, `accent`, `explicit`; `active-border` |
| `decoration_accent` | `[window.decoration] accent` | `#RRGGBB` |
| `decoration_active_background` | `[window.decoration] active_background` | `#RRGGBB` |
| `decoration_inactive_background` | `[window.decoration] inactive_background` | `#RRGGBB` |
| `decoration_active_foreground` | `[window.decoration] active_foreground` | `#RRGGBB` |
| `decoration_inactive_foreground` | `[window.decoration] inactive_foreground` | `#RRGGBB` |
| `decoration_active_border` | `[window.decoration] active_border` | `#RRGGBB` |
| `decoration_inactive_border` | `[window.decoration] inactive_border` | `#RRGGBB` |
| `animations` | `[animation] enabled` | Boolean; `true` |
| `animation_duration_ms` | `[animation] duration_ms` | `0..5000`; `180` |
| `animation_fps` | `[animation] fps` | `1..240`; `60` |
| `animation_easing` | `[animation] easing` | `linear`, `ease_out_cubic`; `ease_out_cubic` |
| `bar_enabled` | `[bar] enabled` | Boolean; `false` |
| `bar_position` | `[bar] position` | `top`, `bottom`; `top` |
| `bar_height` | `[bar] height` | `1..512`; `26` |
| `bar_font` | `[bar] font` | Non-empty string shorter than 128 bytes; `monospace` |
| `bar_font_size` | `[bar] font_size` | `6..72`; `11` |
| `bar_font_weight` | `[bar] font_weight` | `normal`, `regular`, `medium`, `bold`; `normal` |
| `bar_foreground` | `[bar] foreground` | `#RRGGBB`; `#E6E6E6` |
| `bar_background` | `[bar] background` | `#RRGGBB`; `#1E1E2E` |
| `bar_tag_count`, `bar_workspace_count` | `[bar] tag_count` | `1..64`; `8` |
| `bar_tag_foreground`, `bar_workspace_foreground` | `[bar.tag] foreground` | `#RRGGBB`; `#262626` |
| `bar_tag_background`, `bar_workspace_background` | `[bar.tag] background` | `#RRGGBB`; `#5F87AF` |
| `bar_block_foreground` | `[bar.block] foreground` | `#RRGGBB`; `#262626` |
| `bar_block_background` | `[bar.block] background` | `#RRGGBB`; `#AF5F5F` |

Legacy decorative compatibility keys that are currently accepted and ignored
will remain accepted only by the `.rc` parser. They will not be added to the new
schema because they have no runtime effect.

## Directives and objects

| Legacy form | New form | Preserved behavior |
|---|---|---|
| `bind : COMBO : COMMAND` | `[bind] "COMBO" = "COMMAND"` | Shell execution and generated Shift binding |
| `call : COMBO : ACTION [ARG]` | `[call] "COMBO" = ACTION [ARG]` | Every action accepted by `resolve_bind`, including focus criteria |
| `workspace : COMBO : view/tag ID` | `[workspace.bindings] "COMBO" = view/tag ID` | Dynamic workspace view/tag |
| `rule : FIELD : PATTERN : EFFECTS` | `[rule.NAME]` properties | Ordered substring matching; workspace, floating and decorate effects |
| `autostart : COMMAND` | `[autostart] NAME = COMMAND` | Ordered, named, startup-only execution |
| `bar_block : ...` | `[bar.blocks.NAME]` properties | All ten block kinds, order, alignment, colours, timing and commands |
| `virtual_screen : OUTPUT : split : RATIO [: OFFSET]` | `[virtual_screen.OUTPUT]` properties | `split`, ratio `10..90`, signed offset |
| `workspace-ID : LAYOUT : ICON [: NAME]` | `[workspace.ID]` properties | Layout, icon and hover name |
| `workspace_layout : ID : LAYOUT` | `[workspace.ID] layout` | All five current workspace layouts |
| `mousebind : ...` | No new mapping yet | Legacy parser continues warning and ignoring it; no runtime mouse-action system exists |

Named objects merge by identifier without changing their original position.
Bindings merge by normalized key combination. Across imports, later properties
override earlier properties; newly introduced objects append in declaration
order. Imports remain in the assignment stream so settings before and after
them retain their relative precedence. Strict duplicate diagnostics within a
single section occurrence and repeated named sections within one source file
prevent ambiguous definitions.

Automatic reload tracks the complete normalized import graph. Changes to the
root, nested imports, and creation of a missing optional import all schedule one
debounced atomic reload.

## Discovery and compatibility

The target discovery order is `-c`/`--config`, `SKARWM_CONFIG`, the user
`skarwm/default.conf`, `/etc/skarwm/default.conf`, then built-in defaults.
If `-c`/`--config` or `SKARWM_CONFIG` names a missing or invalid file, startup
fails instead of silently falling back to defaults. A failed reload keeps the
currently active configuration.
Explicit `.rc` paths continue to select the legacy parser and produce a
deprecation warning. Automatic rewriting or deletion of existing files is not
part of the migration.

The runtime currently selects the parser by the `.conf` extension. User and
system `default.conf` files are preferred during discovery, with existing
`config.rc` locations retained as transitional fallbacks.
