#!/usr/bin/env bash

set -u

config_directory="${XDG_CONFIG_HOME:-$HOME/.config}/skarwm"
themes_directory="${SKARWM_THEMES_DIR:-$config_directory/themes}"
active_theme="$config_directory/theme.rc"
rofi_config_directory="${XDG_CONFIG_HOME:-$HOME/.config}/rofi"
rofi_themes_directory="${SKARWM_ROFI_THEMES_DIR:-$rofi_config_directory/themes}"
rofi_active_theme="$rofi_config_directory/theme.rasi"
scripts_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rofi_command="${SKARWM_ROFI_COMMAND:-$scripts_directory/rofi.sh}"

[[ -d "$themes_directory" && -d "$rofi_themes_directory" ]] || {
  notify-send -u critical "skarwm Themes" \
    "Theme directories not found"
  exit 1
}

mapfile -t themes < <(
  while IFS= read -r theme; do
    [[ -f "$rofi_themes_directory/$theme.rasi" ]] && printf '%s\n' "$theme"
  done < <(
    find "$themes_directory" -maxdepth 1 -type f -name '*.rc' -printf '%f\n' |
      sed 's/\.rc$//' |
      sort -f
  )
)
((${#themes[@]} > 0)) || {
  notify-send -u critical "skarwm Themes" "No matching skarwm and Rofi themes found"
  exit 1
}

selected_theme="$(
  printf '%s\n' "${themes[@]}" |
    "$rofi_command" -dmenu -i -p "skarwm Theme"
)"
[[ -n "$selected_theme" ]] || exit 0

valid=false
for theme in "${themes[@]}"; do
  if [[ "$selected_theme" == "$theme" ]]; then valid=true; break; fi
done
[[ "$valid" == true ]] || exit 1

selected_path="$themes_directory/$selected_theme.rc"
selected_rofi_path="$rofi_themes_directory/$selected_theme.rasi"
[[ -f "$selected_path" && -f "$selected_rofi_path" ]] || exit 1

ln -sfn "$selected_path" "$active_theme"
ln -sfn "$selected_rofi_path" "$rofi_active_theme"
if ! command -v skarwm-msg >/dev/null 2>&1 || skarwm-msg reload; then
  notify-send "skarwm Theme" "Using $selected_theme"
else
  notify-send -u critical "skarwm Theme" \
    "Could not reload $selected_theme"
  exit 1
fi
