#!/usr/bin/env bash

set -u

while sleep 300; do
  battery_path="$(upower -e | grep '/battery_' | head -n 1)"
  [[ -n "$battery_path" ]] || continue

  state="$(upower -i "$battery_path" | awk '/state/ {print $2; exit}')"
  [[ "$state" == "discharging" ]] || continue

  percentage="$(
    upower -i "$battery_path" |
      awk '/percentage/ {gsub(/%/, "", $2); print $2; exit}'
  )"
  [[ "$percentage" =~ ^[0-9]+$ ]] || continue

  if ((percentage <= 20)); then
    notify-send -u critical "⚡ Need Juice" \
      "Battery is at ${percentage}%"
  elif ((percentage <= 30)); then
    notify-send -u low "⚡ Low Battery" \
      "Battery is at ${percentage}%"
  fi
done
