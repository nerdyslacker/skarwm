#!/usr/bin/env bash

set -u

terminal="${TERMINAL:-st}"
[[ $# -gt 0 ]] || exit 2

base_command="${1##*/}"
if pgrep -x "$base_command" >/dev/null; then
  notify-send -u low "$base_command is already running"
  exit 0
fi

setsid "$terminal" -e "$@" >/dev/null 2>&1 &
