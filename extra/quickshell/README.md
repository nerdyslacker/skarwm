# skarwm Quickshell bar

This is the full skarwm bar, styled with the Srcery palette in `Theme.qml`.
It keeps skarwm's workspace `Tags.qml` and focused-window `Title.qml`, adds the
portable status modules from the previous desktop bar, and integrates with
skarwm through its IPC client.

The bar includes:

- application launcher, workspace tags, and focused-window title;
- media, weather, CPU/RAM/disk/battery metrics, volume, and network state;
- Void Linux update count, system tray, notifications, clock and calendar;
- microphone mute, Caps Lock, screenshots, and a quick-command panel.

The panel and all cards are square. The panel has no outer margin and is
anchored directly to the top, left, and right screen edges. Its EWMH strut is
reserved automatically by skarwm.

## Requirements

Install skarwm first so `skarwm-msg` is available on `PATH`. The bar itself
requires Quickshell and a Nerd Font; `JetBrainsMono Nerd Font` is configured.
Individual modules use these optional programs when available:

- `rofi` for the application launcher and `feh` for wallpaper selection;
- `nmcli` and `nm-connection-editor` for network state and settings;
- PipeWire/PulseAudio-compatible `pactl` and `pavucontrol` for audio;
- an MPRIS-compatible media player for media controls;
- `curl` for weather and `xdg-open` for its web view;
- `xbps-install`, `sudo`, and `xterm` for Void update actions;
- `dunstctl`/`notify-send`, `flameshot`, `brightnessctl`, `powerprofilesctl`,
  `redshift`, and `xset` for their corresponding optional controls.

Missing optional tools only affect their corresponding module or action.

## Run

After `make install-extra`, launch the installed bar with:

```sh
qs -p ~/.config/skarwm/quickshell
```

`Wm.qml` runs the installed `skarwm-msg` command. Set `SKARWM_SOCKET` for both
skarwm and Quickshell if you use a non-default IPC socket path.

## Local settings

The following optional plain-text files live in `~/.config/skarwm/`:

- `bar-height` — bar height in pixels, clamped to 28–80;
- `bar-scale` — module scale, clamped to 0.7–2.0;
- `weather-location` — city, postal code, or other wttr.in location;
- `weather-units` — `c` or `f`;
- `pomodoro` — persisted timer end time and duration.

Put `.png`, `.jpg`, `.jpeg`, or `.webp` images in
`~/.config/skarwm/wallpaper/`.
Right-click the launcher icon to open the thumbnail picker, or middle-click it
to apply a random image. Wallpaper changes do not alter the fixed Srcery
palette.
