# skarwm Quickshell bar

This is the full skarwm bar, styled with the Srcery palette in `Theme.qml`.
It keeps skarwm's workspace `Tags.qml` and focused-window `Title.qml`, adds the
portable status modules from the previous desktop bar, and integrates with
skarwm through its IPC client.

The bar includes:

- application launcher, workspace tags, focused-window title, and a
  scratchpad-register popup that appears beside the title when needed;
- media, weather, CPU/RAM/disk/battery metrics, volume, and network state;
- Void Linux update count, system tray, notifications, clock and calendar;
- microphone mute, Caps Lock, screenshots, power controls, and a quick-command
  panel.

The panel and all cards are square. The panel has no outer margin and is
anchored directly to the top, left, and right screen edges. Its EWMH strut is
reserved automatically by skarwm.

## Requirements

Install skarwm first so `skarwm-msg` is available on `PATH`. The bar itself
requires Quickshell and a Nerd Font; `JetBrainsMono Nerd Font` is configured.
Individual modules use these optional programs when available:

- `feh` for wallpaper selection; the application launcher is built into
  Quickshell and reads the system's `.desktop` entries directly;
- `nmcli` and `nm-connection-editor` for network state and settings, plus
  `bluetoothctl` for the optional Bluetooth section;
- PipeWire/PulseAudio-compatible `pactl` and `pavucontrol` for audio;
- an MPRIS-compatible media player for media controls;
- `curl` for weather;
- `renCal` to open the full calendar on a clock right-click and Python 3 for
  reading its local Caldir events into the calendar popup;
- `xbps-install`, `sudo`, and `xterm` for Void update actions;
- `dunstctl`/`notify-send`, `flameshot`, `brightnessctl`, `powerprofilesctl`,
  `redshift`, `xset`, `loginctl`, and `betterlockscreen` for their corresponding
  optional controls;
- `xinput` and `xdotool` for outside-click popup dismissal on Quickshell 0.3.0
  (newer releases handle this through `PopupWindow.grabFocus`).

Missing optional tools only affect their corresponding module or action.

## Run

After `make install-extra`, launch the installed bar with:

```sh
qs -p ~/.config/skarwm/quickshell
```

`Wm.qml` runs the installed `skarwm-msg` command. Set `SKARWM_SOCKET` for both
skarwm and Quickshell if you use a non-default IPC socket path.

For a system package, set `SKARWM_EXTRA_DIR` to the installed desktop root and
`SKARWM_STATE_DIR` to a writable directory. `skarwm-session` does this
automatically for `/usr/share/skarwm/extra`.

## Local settings

The following optional plain-text files live in `~/.config/skarwm/` for a
per-user install, or in `$SKARWM_STATE_DIR` when it is set:

- `bar-height` — bar height in pixels, clamped to 28–80;
- `bar-scale` — module scale, clamped to 0.7–2.0;
- `weather-location` — city, postal code, or other wttr.in location;
- `weather-units` — `c` or `f`;
- `pomodoro` — persisted timer end time and duration.

The calendar reads renCal's configured Caldir path automatically. Set
`CALDIR_DIR` only when you want to override that location.
Left-click the clock for the month calendar and upcoming events. Clicking an
event or a highlighted day opens that event in renCal; right-clicking the clock
opens renCal directly.

When skarwm has one or more numbered scratchpad registrations, a terminal icon
appears beside the focused-window title. Click it to see the registered windows
and their hidden/workspace state; clicking a row toggles that scratchpad.

Put `.png`, `.jpg`, `.jpeg`, or `.webp` images in
`~/.config/skarwm/wallpaper/`.
Left-click the launcher icon, type to filter applications, use the arrow keys to
select a result, and press Enter to launch it. The launcher can also be toggled
with `qs -p /path/to/quickshell ipc call launcher toggle`.
Right-click the launcher icon to open the thumbnail picker, or middle-click it
to apply a random image. Wallpaper changes do not alter the fixed Srcery
palette.
