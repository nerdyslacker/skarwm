#!/usr/bin/env bash

set -u

temperature="${SKARWM_NIGHT_TEMPERATURE:-4000}"
state_file="${XDG_CACHE_HOME:-$HOME/.cache}/skarwm/redshift-enabled"

if [[ -e "$state_file" ]]; then
  redshift -x >/dev/null 2>&1 || true
  unlink "$state_file"
  notify-send "Night Light" "Disabled"
else
  redshift -O "$temperature" >/dev/null 2>&1 || exit 1
  mkdir -p "${state_file%/*}"
  : > "$state_file"
  notify-send "Night Light" "Enabled at ${temperature}K"
fi
