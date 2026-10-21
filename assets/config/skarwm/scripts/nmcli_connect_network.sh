#!/usr/bin/env bash

set -u

scripts_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rofi_command="$scripts_directory/rofi.sh"

selected_network="$(
  nmcli -t --escape no -f SSID device wifi list |
    sed '/^$/d' |
    sort -fu |
    "$rofi_command" -dmenu -i -matching fuzzy -p "WiFi"
)"
[[ -n "$selected_network" ]] || exit 0

if nmcli -t --escape no -f NAME connection show | grep -Fxq "$selected_network"; then
  if nmcli connection up "$selected_network"; then
    notify-send "WiFi Connected" "Connected to $selected_network"
    exit 0
  fi

  notify-send -u critical "WiFi Connection Failed" \
    "Could not connect to $selected_network"
  exit 1
fi

for attempt in 1 2 3; do
  password="$(
    "$rofi_command" -dmenu -password -no-fixed-num-lines -p "Password ($attempt/3)" \
      -theme-str 'window { width: 30%; margin: 10 0 0 10; }' </dev/null
  )"
  [[ -n "$password" ]] || exit 0

  if nmcli device wifi connect "$selected_network" password "$password"; then
    notify-send "WiFi Connected" "Connected to $selected_network"
    exit 0
  fi
  sleep 0.5
done

notify-send -u critical "WiFi Connection Failed" \
  "Failed to connect to $selected_network"
exit 1
