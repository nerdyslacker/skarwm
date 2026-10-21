#!/usr/bin/env bash

# Rofi's window mode uses EWMH on X11. skarwm handles its _NET_ACTIVE_WINDOW
# request and moves focus to the selected window, including across workspaces.
scripts_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

exec "$scripts_directory/rofi.sh" -show window -show-icons -p "Window picker" \
  -theme-str 'window { width: 80%; margin: 10 0 0 10; }'
