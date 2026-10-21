#!/usr/bin/env bash

set -u

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
lock_image="${SKARWM_LOCK_IMAGE:-$config_home/walls/lock.png}"
theme="$config_home/rofi/themes/powermenu.rasi"
scripts_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rofi_command="$scripts_directory/rofi.sh"

locker_available() {
  command -v anushctl >/dev/null 2>&1 ||
    command -v betterlockscreen >/dev/null 2>&1 ||
    command -v i3lock >/dev/null 2>&1
}

lock_screen() {
  if command -v anushctl >/dev/null 2>&1; then
    anushctl lock
  elif command -v betterlockscreen >/dev/null 2>&1; then
    betterlockscreen -l
  elif command -v i3lock >/dev/null 2>&1; then
    if [[ -f "$lock_image" ]]; then
      i3lock -i "$lock_image"
    else
      i3lock -c 121110
    fi
  else
    notify-send -u critical "Lock Screen" \
      "Install anush, betterlockscreen, or i3lock"
    return 1
  fi
}

options=("LOCK" "SUSPEND" "LOG-OUT" "RESTART" "POWER-OFF")
chosen="$(
  printf '%s\n' "${options[@]}" |
    "$rofi_command" -dmenu -i -theme "$theme"
)"

case "$chosen" in
  LOCK) lock_screen ;;
  SUSPEND)
    if ! locker_available; then
      notify-send -u critical "Suspend cancelled" \
        "Install anush, betterlockscreen, or i3lock"
      exit 1
    fi
    lock_screen &
    sleep 0.5
    systemctl suspend
    ;;
  LOG-OUT)
    if command -v skarwm-msg >/dev/null 2>&1; then
      skarwm-msg quit
    else
      pkill -x skarwm
    fi
    ;;
  RESTART) systemctl reboot ;;
  POWER-OFF) systemctl poweroff ;;
  *) exit 0 ;;
esac
