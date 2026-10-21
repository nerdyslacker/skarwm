#!/usr/bin/env bash

set -u

config_directory="${XDG_CONFIG_HOME:-$HOME/.config}/skarwm"
themes_directory="${SKARWM_THEMES_DIR:-$config_directory/themes}"
active_theme="$config_directory/theme.rc"
scripts_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rofi_command="$scripts_directory/rofi.sh"

[[ -d "$themes_directory" ]] || {
  notify-send -u critical "skarwm Themes" \
    "Directory not found: $themes_directory"
  exit 1
}

mapfile -t themes < <(
  find "$themes_directory" -maxdepth 1 -type f -name '*.rc' -printf '%f\n' |
    sed 's/\.rc$//' |
    sort -f
)
((${#themes[@]} > 0)) || {
  notify-send -u critical "skarwm Themes" "No .rc themes found"
  exit 1
}

selected_theme="$(
  printf '%s\n' "${themes[@]}" |
    "$rofi_command" -dmenu -i -p "skarwm Theme"
)"
[[ -n "$selected_theme" ]] || exit 0

selected_path="$themes_directory/$selected_theme.rc"
[[ -f "$selected_path" ]] || exit 1

ln -sfn "$selected_path" "$active_theme"
if ! command -v skarwm-msg >/dev/null 2>&1 || skarwm-msg reload; then
  notify-send "skarwm Theme" "Using $selected_theme"
else
  notify-send -u critical "skarwm Theme" \
    "Could not reload $selected_theme"
  exit 1
fi
