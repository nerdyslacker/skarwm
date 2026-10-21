#!/usr/bin/env bash

set -u

scripts_directory="${XDG_CONFIG_HOME:-$HOME/.config}/skarwm/scripts"

run_once() {
  local command="$1"
  if ! pgrep -f -- "$command" >/dev/null; then
    "$command" >/dev/null 2>&1 &
  fi
}

"$scripts_directory/setBackground.sh" &
run_once "$scripts_directory/tempWarning.sh"
run_once "$scripts_directory/batteryWarning.sh"
