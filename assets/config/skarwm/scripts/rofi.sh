#!/usr/bin/env bash

# Keep Rofi usable when the X11 session inherited a locale that is not
# installed. Prefer the user's locale, then an installed UTF-8 fallback.
locale_available() {
  LC_ALL=C locale -a 2>/dev/null |
    awk -v requested="$1" '
      function canonical(value) {
        value = tolower(value)
        gsub(/[-_.]/, "", value)
        return value
      }
      canonical($0) == canonical(requested) { found = 1 }
      END { exit !found }
    '
}

for candidate in \
  "${LC_ALL:-}" "${LC_CTYPE:-}" "${LANG:-}" \
  C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 C; do
  [[ -n "$candidate" ]] || continue
  if locale_available "$candidate"; then
    export LC_ALL="$candidate"
    exec rofi "$@"
  fi
done

printf 'rofi: no usable locale is installed\n' >&2
exit 1
