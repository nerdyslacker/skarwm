#!/usr/bin/env bash

set -u

scripts_directory="${SKARWM_EXECUTABLES_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/skarwm/scripts/executables}"
helpers_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rofi_command="$helpers_directory/rofi.sh"

[[ -d "$scripts_directory" ]] || {
  notify-send -u critical "Scripts" "Directory not found: $scripts_directory"
  exit 1
}

selected_script="$(
  find "$scripts_directory" -maxdepth 1 -type f -executable ! -name '.*' \
    -printf '%f\n' |
    sort -f |
    "$rofi_command" -dmenu -i -matching fuzzy -p "Scripts"
)"

[[ -n "$selected_script" ]] || exit 0
"$scripts_directory/$selected_script"
