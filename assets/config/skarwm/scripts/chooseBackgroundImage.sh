#!/usr/bin/env bash

set -u

backgrounds_directory="${SKARWM_WALLPAPER_DIR:-/usr/share/backgrounds}"
theme="${XDG_CONFIG_HOME:-$HOME/.config}/rofi/themes/wallpicker.rasi"
cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/skarwm/wallpaper"
scripts_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rofi_command="$scripts_directory/rofi.sh"
find_depth=()

# `~/Pictures/backgrounds` matches the original Sway setup. A plain
# `~/Pictures` directory is a useful X11 desktop default when it is absent.
if [[ ! -d "$backgrounds_directory" && -d "$HOME/Pictures" ]]; then
  backgrounds_directory="$HOME/Pictures"
  find_depth=(-maxdepth 1)
fi

show_wallpapers() {
  printf '\0keep-selection\x1ftrue\n'

  local file name
  while IFS= read -r -d '' file; do
    name="${file##*/}"
    printf '%s\0icon\x1f%s\n' "$name" "$file"
  done < <(
    find "$backgrounds_directory" "${find_depth[@]}" -type f \
      \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o \
         -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \) \
      -print0 | sort -z
  )
}

set_wallpaper() {
  local selected_wall="$1"
  local wall_path
  [[ -n "$selected_wall" ]] || return 0

  wall_path="$(
    find "$backgrounds_directory" "${find_depth[@]}" -type f -name "$selected_wall" \
      -print -quit
  )"
  [[ -n "$wall_path" ]] || return 0

  mkdir -p "${cache_file%/*}"
  printf '%s\n' "$wall_path" > "$cache_file"
  feh --no-fehbg --bg-fill "$wall_path"
}

if [[ -n "${ROFI_RETV:-}" ]]; then
  case "$ROFI_RETV" in
    0) show_wallpapers ;;
    1)
      set_wallpaper "${1:-}"
      show_wallpapers
      ;;
  esac
  exit 0
fi

if [[ ! -d "$backgrounds_directory" ]] ||
  ! find "$backgrounds_directory" "${find_depth[@]}" -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o \
       -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \) \
    -print -quit | grep -q .; then
  notify-send "Wallpaper Picker" "No wallpapers found in $backgrounds_directory"
  exit 1
fi

exec "$rofi_command" -show walls -modi "walls:$0" -show-icons -theme "$theme"
