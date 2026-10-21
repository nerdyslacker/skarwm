# Optional Rofi desktop helpers

This directory mirrors the paths below `~/.config`. Copy or symlink the
`rofi` and `skarwm` directories into your configuration directory, then enable
the corresponding bindings in [`../example.rc`](../example.rc).

The scripts use X11-native tools:

- `feh` sets and restores wallpapers;
- Rofi's EWMH window mode switches skarwm windows;
- `betterlockscreen` or `i3lock` locks the X11 session;
- `skarwm-msg quit` logs out of skarwm;
- `redshift` night-light helper;
- rc theme fragments;

All bundled menus use `scripts/rofi.sh`. It keeps a valid session locale when
available and selects an installed UTF-8 fallback when the X11 session has
inherited a stale locale value, avoiding Rofi's `Failed to set locale` error.

The complete helper set expects `bash`, `rofi`, `feh`, `libnotify`, `jq`, and
NetworkManager's `nmcli`. The complete session helper set also uses `upower`,
`lm_sensors`, and `redshift`. The power menu additionally needs `systemctl`
plus Anush, `betterlockscreen`, or `i3lock`. The themes use the generic
fontconfig `monospace` family, so their geometry does not depend on a specific
Nerd Font being installed.

The bundle includes starter JSON files under `~/.config/skarwm/bookmarks`.
Each file is one category and contains an array such as:

```json
[
  {"title": "skarwm", "url": "https://github.com/nerdyslacker/skarwm"}
]
```

Set `BROWSER` to choose the browser (the default is `firefox`). Executable
files placed directly in `~/.config/skarwm/scripts/executables` appear in the
script picker. Wallpaper images default to `~/Pictures/backgrounds`; the
fallback restored at login is `~/.config/skarwm/wallpaper.jpeg`.

When running `assets/example.rc` directly, its import is
`config/skarwm/theme.rc`, relative to the `assets` directory. After copying the
example to `~/.config/skarwm/skarwm.rc`, change that line to `import : theme.rc`.
The included file starts with the Grimm palette; add more `.rc` fragments to
`~/.config/skarwm/themes` and the picker will discover them automatically.

The following optional environment variables override those paths:

- `SKARWM_BOOKMARKS_DIR`
- `SKARWM_EXECUTABLES_DIR`
- `SKARWM_WALLPAPER_DIR`
- `SKARWM_DEFAULT_WALLPAPER`
- `SKARWM_LOCK_IMAGE`
