#!/usr/bin/env bash

set -u

bookmarks_directory="${SKARWM_BOOKMARKS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/skarwm/bookmarks}"
browser="${BROWSER:-firefox}"
browser_mode="${1:-tab}"
selection_mode="${2:-all}"
scripts_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rofi_command="$scripts_directory/rofi.sh"

notify_error() {
  notify-send -u critical "Bookmarks" "$1" 2>/dev/null || true
}

if [[ ! -d "$bookmarks_directory" ]]; then
  notify_error "Directory not found: $bookmarks_directory"
  exit 1
fi

case "$browser_mode" in
  tab) browser_args=(--new-tab) ;;
  window) browser_args=(--new-window) ;;
  private) browser_args=(--private-window) ;;
  *)
    notify_error "Invalid mode '$browser_mode' (use tab, window, or private)"
    exit 1
    ;;
esac

choose_bookmark() {
  local json="$1"
  local prompt="$2"
  local selected

  selected="$(
    printf '%s\n' "$json" |
      jq -r '.[].title' |
      sort -fu |
      "$rofi_command" -dmenu -i -p "$prompt" \
        -theme-str 'window { width: 30%; margin: 10 0 0 10; }'
  )"
  [[ -n "$selected" ]] || return 1

  printf '%s\n' "$json" |
    jq -r --arg title "$selected" \
      '.[] | select(.title == $title) | .url' |
    head -n 1
}

if [[ "$selection_mode" == "all" ]]; then
  shopt -s nullglob
  bookmark_files=("$bookmarks_directory"/*.json)
  ((${#bookmark_files[@]} > 0)) || {
    notify_error "No JSON bookmark files found"
    exit 1
  }

  bookmarks_json="$(jq -s 'add' "${bookmark_files[@]}" 2>/dev/null)"
  [[ -n "$bookmarks_json" && "$bookmarks_json" != "null" ]] || exit 0
  url="$(choose_bookmark "$bookmarks_json" "Bookmarks")" || exit 0
else
  mapfile -t categories < <(
    find "$bookmarks_directory" -maxdepth 1 -type f -name '*.json' \
      -printf '%f\n' | sed 's/\.json$//' | sort -f
  )
  ((${#categories[@]} > 0)) || exit 0

  selected_category="$(
    printf '%s\n' "${categories[@]}" |
      "$rofi_command" -dmenu -i -p "Categories" \
        -theme-str 'window { width: 30%; margin: 10 0 0 10; }'
  )"
  [[ -n "$selected_category" ]] || exit 0

  selected_file="$bookmarks_directory/$selected_category.json"
  bookmarks_json="$(jq '.' "$selected_file" 2>/dev/null)" || {
    notify_error "Invalid JSON: $selected_file"
    exit 1
  }
  url="$(choose_bookmark "$bookmarks_json" "$selected_category")" || exit 0
fi

[[ -n "$url" && "$url" != "null" ]] || exit 1
setsid "$browser" "${browser_args[@]}" "$url" >/dev/null 2>&1 &
