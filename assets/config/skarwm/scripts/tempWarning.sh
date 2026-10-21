#!/usr/bin/env bash

set -u

threshold="${SKARWM_TEMP_THRESHOLD:-80}"

while sleep 40; do
  temperature="$(
    sensors 2>/dev/null |
      awk '/Package id 0|Tctl|CPU Temperature/ {
        line = $0
        sub(/^.*: *\+?/, "", line)
        sub(/°C.*$/, "", line)
        print int(line)
        exit
      }'
  )"
  [[ "$temperature" =~ ^[0-9]+$ ]] || continue

  if ((temperature >= threshold)); then
    notify-send -u critical "🔥 High Temperature" \
      "CPU temperature is ${temperature}°C"
  fi
done
