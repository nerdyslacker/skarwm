# Optional Rofi desktop helpers

This directory mirrors the paths below `~/.config`. Copy or symlink the
`rofi` and `skarwm` directories into your configuration directory, then enable
the corresponding bindings in [`../example.rc`](../example.rc).

The scripts use X11-native tools:

- `feh` sets and restores wallpapers.
- Rofi's EWMH mode switches skarwm windows.
- `betterlockscreen` or `i3lock` locks the X11 session.
- `skarwm-msg quit` logs out of skarwm.
- `redshift` adjusts the display colour temperature.
- rc fragments change the skarwm theme.

All bundled menus use `scripts/rofi.sh`. The script preserves a valid session
locale or selects an installed UTF-8 fallback, which prevents Rofi's
`Failed to set locale` error.

The helpers require `bash`, `rofi`, `feh`, `libnotify`, `jq`, and
NetworkManager's `nmcli`. Session helpers use `upower`, `lm_sensors`, and
`redshift`. The power menu needs `systemctl` plus Anush, `betterlockscreen`, or
`i3lock`. Themes use the fontconfig `monospace` family and do not require a
specific Nerd Font.

The bundle includes starter JSON files under `~/.config/skarwm/bookmarks`.
Each file is one category and contains an array such as:

```json
[
  {"title": "skarwm", "url": "https://github.com/nerdyslacker/skarwm"}
]
```

Set `BROWSER` to choose the browser (the default is `firefox`). Put executable
files in `~/.config/skarwm/scripts/executables` to add them to the script
picker. Wallpaper images default to `~/Pictures/backgrounds`; the
fallback restored at login is `~/.config/skarwm/wallpaper.jpeg`.

Srcery is the default dark theme. Nare Light is also included. Enable the theme
import and the `skarwmThemeSwitcher.sh` binding in `example.rc` after copying
the helper bundle. Use `import : config/skarwm/theme.rc` when running the
repository example directly, or `import : theme.rc` in
`~/.config/skarwm/skarwm.rc`.

The picker lists paired themes. Add `name.rc` to
`~/.config/skarwm/themes` and `name.rasi` to `~/.config/rofi/themes`; matching
basenames appear as one menu item. Selecting one updates both active theme
symlinks and reloads skarwm.

The following optional environment variables override those paths:

- `SKARWM_BOOKMARKS_DIR`
- `SKARWM_EXECUTABLES_DIR`
- `SKARWM_WALLPAPER_DIR`
- `SKARWM_DEFAULT_WALLPAPER`
- `SKARWM_LOCK_IMAGE`
- `SKARWM_THEMES_DIR`
- `SKARWM_ROFI_THEMES_DIR`
