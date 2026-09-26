# Virtual screens

Virtual screens let skarwm divide one physical ultrawide monitor into two
independent logical screens. No XRandR monitor needs to be created or changed.

For example, a 3440×1440 `DP-1` can become:

```text
DP-1 (physical monitor)
┌──────────────────────────────┬─────────────┐
│ DP-1:left                    │ DP-1:right  │ 
│ main logical screen          │ side screen │
│ workspace 1                  │ workspace 4 │
└──────────────────────────────┴─────────────┘
```

Each side behaves like a normal skarwm output. It has its own current
workspace, focus history, scrolling viewport, workarea, tiled layout, floating
windows, and fullscreen area. Fullscreen on the left does not cover the right.

## Recommended keybindings

The example configuration uses Mod+F5 through Mod+F8:

```rc
# Make the main screen 15px narrower and the side screen 15px wider.
call : mod + F5 : screen_split_shrink 15

# Return to one logical screen covering the full physical monitor.
call : mod + F6 : screen_split_disable

# Create the default 75/25 main/side split.
call : mod + F7 : screen_split_enable 75

# Make the main screen 15px wider and the side screen 15px narrower.
call : mod + F8 : screen_split_grow 15
```

`screen_split_grow` and `screen_split_shrink` always move the shared boundary
of the active logical screen's physical parent. The two widths still add up to
the physical monitor width, so resizing cannot create a gap or overlap.

Other bindable actions are:

```text
screen_split_toggle [percent]
screen_split_enable [percent]
screen_split_disable
screen_split_grow [pixels]
screen_split_shrink [pixels]
screen_split_ratio <percent>
```

The optional percentage for toggle/enable defaults to 75. Grow and shrink
default to 50 pixels when no amount is supplied. Ratios must be from 10 through
90, and both resulting screens must be at least 160 pixels wide.

## IPC commands

The same operations are available through `skarwm-msg`:

```sh
skarwm-msg screen split toggle
skarwm-msg screen split enable
skarwm-msg screen split disable
skarwm-msg screen split resize -15
skarwm-msg screen split resize +15
skarwm-msg screen split ratio 0.75
```

Commands act on the active logical screen's physical monitor. A rejected ratio
or boundary change leaves the current geometry untouched.

Use the normal output commands to move between the two logical screens:

```sh
skarwm-msg focus output next
skarwm-msg focus output prev
skarwm-msg move output next
skarwm-msg move output prev
```

## Persistent configuration

To start or reload with a split on a named physical output, add:

```rc
virtual_screen : DP-1 : split : 75
```

An optional signed pixel offset adjusts the ratio-derived boundary:

```rc
virtual_screen : DP-1 : split : 75 : -30
```

This makes the main region `75% - 30px` wide and gives the side region the
exact remainder. Find output names with:

```sh
xrandr --listactivemonitors
skarwm-msg get-outputs
```

Profiles for disconnected monitors are remembered and applied when the named
monitor appears. Invalid or duplicate profiles reject the complete config
reload, leaving the running configuration unchanged.

## Split and unsplit behavior

Enabling a split keeps the existing screen and workspace state on the left and
creates the right logical screen. Their stable names are formed from the
physical output name:

```text
DP-1:left
DP-1:right
```

When disabling a split, skarwm:

1. migrates clients and workspace contents from the right screen into matching
   workspace IDs on the left;
2. remembers the right screen's selected workspace ID;
3. expands the surviving screen to the physical monitor's current geometry.

If the split is enabled again, the side screen restores its remembered
workspace selection. Migrated clients remain safely accessible on the main
screen and are never hidden in an inactive internal screen.

When XRandR changes the monitor's resolution or position, skarwm recomputes a
ratio-based split from the new physical geometry. If the new size cannot hold
both minimum widths, it safely falls back to a single logical screen.

## Output information

`skarwm-msg get-outputs` returns one object per logical screen. Virtual-screen
objects include:

- `name` — stable logical name such as `DP-1:right`;
- `physical_output` — parent monitor name such as `DP-1`;
- `virtual` — whether the screen belongs to a split;
- `rect` — X11 root-coordinate geometry;
- `relative_rect` — geometry relative to the physical monitor;
- `workarea` — usable logical geometry after docks and struts.

Active virtual screens are also published as standard RandR 1.5 monitor
objects. Monitor-aware bars and shells therefore see the split through their
ordinary multi-monitor path, just as they do when another display is attached;
no Anush- or toolkit-specific integration is required. The objects use the
same names and rectangles returned by `skarwm-msg get-outputs` and are removed
when the screen is unsplit or skarwm exits.

skarwm keeps physical discovery separate from this projection. Its own
SetMonitor/DeleteMonitor resource notifications are filtered while a projection
is active, and their same-size root `ConfigureNotify` events are ignored. Real
screen-size, CRTC, and output changes still trigger the normal hotplug path.
The root property `_SKARWM_VIRTUAL_MONITORS` records the
owned monitor atoms so a new skarwm process can remove stale objects left by an
unclean previous exit before discovering physical screens.
