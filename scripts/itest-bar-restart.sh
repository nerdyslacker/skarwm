#!/bin/sh

: "${SKARWM_BAR_TEST_COUNT_FILE:?set SKARWM_BAR_TEST_COUNT_FILE to an absolute file path}"
case "$SKARWM_BAR_TEST_COUNT_FILE" in
  /*) ;;
  *) printf '%s\n' 'SKARWM_BAR_TEST_COUNT_FILE must be an absolute file path' >&2; exit 2 ;;
esac

printf 'start\n' >>"$SKARWM_BAR_TEST_COUNT_FILE"
[ "$(wc -l <"$SKARWM_BAR_TEST_COUNT_FILE")" -gt 1 ] || exit 1

while kill -0 "$PPID" 2>/dev/null; do sleep 0.1; done
