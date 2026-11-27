#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

config_root="$test_root/config"
bin_root="$test_root/bin"
mkdir -p "$config_root/skarwm/themes" "$config_root/rofi/themes" "$bin_root"

printf 'dark\n' >"$config_root/skarwm/themes/srcery.rc"
printf 'light\n' >"$config_root/skarwm/themes/nare-light.rc"
printf 'unpaired\n' >"$config_root/skarwm/themes/skarwm-only.rc"
printf 'dark rofi\n' >"$config_root/rofi/themes/srcery.rasi"
printf 'light rofi\n' >"$config_root/rofi/themes/nare-light.rasi"

printf '#!/usr/bin/env bash\ncat >"$THEME_CHOICES"\nprintf "%%s\\n" "$THEME_SELECTION"\n' >"$bin_root/theme-picker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_root/notify-send"
printf '#!/usr/bin/env bash\n[[ "$1" == reload ]]\n' >"$bin_root/skarwm-msg"
chmod +x "$bin_root/theme-picker" "$bin_root/notify-send" "$bin_root/skarwm-msg"

export XDG_CONFIG_HOME="$config_root"
export PATH="$bin_root:$PATH"
export SKARWM_ROFI_COMMAND="$bin_root/theme-picker"
export THEME_CHOICES="$test_root/choices"
export THEME_SELECTION=nare-light

"$repo_root/assets/config/skarwm/scripts/skarwmThemeSwitcher.sh"

[[ "$(readlink "$config_root/skarwm/theme.rc")" == "$config_root/skarwm/themes/nare-light.rc" ]]
[[ "$(readlink "$config_root/rofi/theme.rasi")" == "$config_root/rofi/themes/nare-light.rasi" ]]
grep -qx 'nare-light' "$THEME_CHOICES"
grep -qx 'srcery' "$THEME_CHOICES"
! grep -q 'skarwm-only' "$THEME_CHOICES"

printf 'theme switcher: passed\n'
