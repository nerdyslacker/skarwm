# skarwm Quickshell bar

This is the full skarwm bar, styled with the Srcery palette in `Theme.qml`.
It keeps skarwm's workspace `Tags.qml` and focused-window `Title.qml`, adds the
portable status modules from the previous desktop bar, and integrates with
skarwm through its IPC client.

The bar includes:

- application launcher, workspace tags, focused-window title, and a
  scratchpad-register popup that appears beside the title when needed;
- media, weather, CPU/RAM/disk metrics, battery controls, per-display
  brightness, volume, and network state; the
  volume popup selects output/input devices, controls their global levels, and
  controls each playback stream, while clicking the metrics module opens a
  detailed system monitor with load, temperature, memory/swap/storage totals,
  and the top processes by CPU use;
- Void Linux update count, keyboard-layout switching, clipboard history,
  system tray, notifications, clock and calendar;
- Caps Lock, screenshots, and a user/session command panel with DND, pomodoro,
  and power controls.

The panel and all cards are square. The panel has no outer margin and is
anchored directly to the selected screen edge. Its EWMH strut is reserved
automatically by skarwm.

## Requirements

Install skarwm first so `skarwm-msg` is available on `PATH`. The bar itself
requires Quickshell and a Nerd Font; `JetBrainsMono Nerd Font` is configured.
Individual modules use these optional programs when available:

- `feh` and ImageMagick for per-monitor wallpaper selection; the application launcher is built into
  Quickshell and reads the system's `.desktop` entries directly;
- `nmcli` and `nm-connection-editor` for network state and settings, plus
  `bluetoothctl` for the network popup's optional Bluetooth section;
- PipeWire/PulseAudio-compatible `pactl` and `pavucontrol` for audio;
- an MPRIS-compatible media player for media controls;
- `curl` for weather;
- `renCal` to open the full calendar on a clock right-click and Python 3 for
  reading its local Caldir events into the calendar popup;
- `xbps-install`, `sudo`, and `xterm` for Void update actions;
- `dunstctl`/`notify-send`, `flameshot`, `brightnessctl`, `xrandr`, `powerprofilesctl`,
  `redshift`, `xset`, `loginctl`, and `betterlockscreen` for their corresponding
  optional controls;
- `xinput` and `xdotool` for outside-click popup dismissal on Quickshell 0.3.0
  (newer releases handle this through `PopupWindow.grabFocus`);
- `setxkbmap` to read and apply keyboard layouts and `xkb-switch` to report and
  select the active XKB group;
- `clipmenud`, `clipmenu`, and `clipdel` for text clipboard history, plus
  `xdotool` to place the keyboard-invoked popup and paste into the previously
  focused window.

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
- `bar-transparent` — bar-background opacity from `0` (transparent) to `1`
  (opaque); module cards keep their normal colors;
- `weather-location` — city, postal code, or other wttr.in location;
- `weather-units` — `c` or `f`;
- `pomodoro` — persisted timer end time and duration;
- `keyboard-layout.json` — layouts, aligned variants, and XKB options saved by
  the keyboard settings popup;
- `tags.json` — visible tag count and number/dot display preference.
- `bar-widgets.json` — enabled state, ordering, and top/bottom bar placement.
- `tray-hidden.json` — tray application IDs assigned to the overflow popup.

The keyboard module shows the active layout. Left-click it to select any
configured layout; right-click it to search the system XKB language catalogue
and select layouts in order. Variants remain aligned to those selections, and
the same popup configures the group-switch shortcut. For example, selecting
English (US), Armenian, and Russian, setting variants
`,phonetic,phonetic`, and choosing `Alt+Shift` applies the equivalent of:

```sh
setxkbmap -layout us,am,ru -variant ,phonetic,phonetic \
  -option grp:alt_shift_toggle
```

Other existing XKB options are preserved when the group shortcut changes.

Right-click any workspace tag to set the minimum number of visible tags and
choose between numbered tags and dot indicators. A currently active workspace
above the configured count remains visible.

The clipboard module reads clipmenu's daemon-backed text history. Left-click
its bar module to open the searchable history below the bar; `Super+V` opens
the same popup beside the pointer. Click an entry to paste it, or use the arrow
keys and Enter. The bundled autostart sets `CM_SELECTIONS=clipboard`, which
records explicit clipboard copies but ignores text that was merely selected
into X11 PRIMARY. It uses a skarwm-specific store, so a separately managed
default clipmenud cannot add PRIMARY entries to the popup. Images and pinning
are not supported by this backend.

Left-click the weather module for the forecast. Right-click it for the native
location and unit settings popup; Save updates the watched state files above.

The battery is a separate module from CPU/RAM/disk. Left-click it to switch the
power profile, keep the display awake, or toggle night mode. The neighbouring
sun icon opens one slider per hardware backlight, plus independent XRandR
controls for additional external displays.

The rightmost command menu shows the current account name and avatar (from
`~/.face` or AccountsService), followed by DND, pomodoro, and the session power
buttons. Right-click the command module to choose which other widgets are
visible on the bar, arrange their order, and place the bar on any screen edge.
Left/right bars use compact upright buttons and treat the three layout groups
as top/center/bottom. Popups always open inward from the selected edge.
Microphone mute is controlled from the audio popup's input section; a compact
warning appears beside Audio while the microphone is muted, and clicking it
unmutes the input.

The calendar reads renCal's configured Caldir path automatically. Set
`CALDIR_DIR` only when you want to override that location.
Left-click the clock for the month calendar and upcoming events. Clicking an
event or a highlighted day opens that event in renCal; right-clicking the clock
opens renCal directly.

The system tray's trailing arrow opens its overflow popup. Click an application
row to activate it, right-click for its native menu, or use Hide/Show to choose
whether its icon occupies space on the bar. This placement persists across
restarts.

When skarwm has one or more numbered scratchpad registrations, a terminal icon
appears beside the focused-window title. Click it to see the registered windows
and their hidden/workspace state; clicking a row toggles that scratchpad.

Put `.png`, `.jpg`, `.jpeg`, or `.webp` images in
`~/.config/skarwm/wallpaper/`.
Left-click the launcher icon, type to filter applications, use the arrow keys to
select a result, and press Enter to launch it. The launcher can also be toggled
with `qs -p /path/to/quickshell ipc call launcher toggle`.
`Super+A` opens it centered on skarwm's currently focused monitor.
Right-click the launcher icon to open the thumbnail picker, or middle-click it
to apply a random image. Wallpaper changes do not alter the fixed Srcery
palette.
