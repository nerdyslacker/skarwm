#!/usr/bin/env bash

set -u

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/skarwm/wallpaper"
fallback_wall="${SKARWM_DEFAULT_WALLPAPER:-$config_home/skarwm/wallpaper.jpeg}"
wallpaper=""

if [[ -r "$cache_file" ]]; then
  IFS= read -r wallpaper < "$cache_file"
fi

if [[ -z "$wallpaper" || ! -f "$wallpaper" ]]; then
  wallpaper="$fallback_wall"
fi

if [[ ! -f "$wallpaper" ]]; then
  notify-send -u critical "Wallpaper" "Image not found: $wallpaper"
  exit 1
fi

exec feh --no-fehbg --bg-fill "$wallpaper"
