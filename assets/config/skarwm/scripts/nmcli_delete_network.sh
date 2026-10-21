#!/usr/bin/env bash

set -u

scripts_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rofi_command="$scripts_directory/rofi.sh"

saved_network="$(
  nmcli -t --escape no -f NAME connection show |
    sed '/^$/d' |
    sort -fu |
    "$rofi_command" -dmenu -i -p "Remove WiFi"
)"
[[ -n "$saved_network" ]] || exit 0

confirmation="$(
  printf '%s\n' "Yes" "No" |
    "$rofi_command" -dmenu -p "Delete '$saved_network'?"
)"
[[ "$confirmation" == "Yes" ]] || exit 0

if nmcli connection delete "$saved_network"; then
  notify-send "WiFi Deleted" "$saved_network was removed"
else
  notify-send -u critical "WiFi Delete Failed" \
    "Could not remove $saved_network"
  exit 1
fi
