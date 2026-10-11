#!/usr/bin/env bash
# End-to-end tests for modular configuration loading and atomic graph reloads.

set -u
cd "$(dirname "$0")/.." || exit 2

DISPLAY_ID=${SKARWM_CONFIG_TEST_DISPLAY:-:97}
export DISPLAY="$DISPLAY_ID"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/skarwm-config-itest.XXXXXX")
export SKARWM_SOCKET="$TEST_DIR/skarwm.sock"
WM_LOG="$TEST_DIR/wm.log"
PASS=0
FAIL=0
XVNC_PID=""
WM_PID=""
TERM_PID=""

pass() { PASS=$((PASS+1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*"; }
cleanup() {
  [ -n "$TERM_PID" ] && kill "$TERM_PID" 2>/dev/null || true
  [ -n "$WM_PID" ] && kill "$WM_PID" 2>/dev/null || true
  [ -n "$XVNC_PID" ] && kill "$XVNC_PID" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

for tool in Xvnc xdotool xwininfo; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'error: %s is required\n' "$tool" >&2; exit 2; }
done

mkdir -p "$TEST_DIR/config.d"
cat >"$TEST_DIR/default.conf" <<'CONF'
[import]
base = config.d/base.conf
local = ?config.d/local.conf
CONF
cat >"$TEST_DIR/config.d/base.conf" <<'CONF'
[general]
mod_key = super
[window]
outer_gap = 8
inner_gap = 8
border_width = 2
[animation]
enabled = false
[bind]
"mod + Return" = xterm
[call]
"mod + Shift + r" = reload_config
CONF

Xvnc "$DISPLAY_ID" -geometry 1280x800 -depth 24 -localhost -SecurityTypes None >"$TEST_DIR/xvnc.log" 2>&1 &
XVNC_PID=$!
for _ in $(seq 1 40); do xdpyinfo -display "$DISPLAY_ID" >/dev/null 2>&1 && break; sleep 0.1; done

if env -u SKARWM_CONFIG TERMINAL=xterm timeout 3 ./build/skarwm --config >"$WM_LOG" 2>&1; then
  fail "--config without a path unexpectedly started"
elif grep -q -- '--config requires a file path' "$WM_LOG"; then
  pass "--config requires a path"
else
  fail "missing --config argument diagnostic"
fi

if env -u SKARWM_CONFIG TERMINAL=xterm timeout 3 ./build/skarwm --config "$TEST_DIR/missing.conf" >"$WM_LOG" 2>&1; then
  fail "missing explicit CLI config unexpectedly started"
elif grep -q 'config file not found:' "$WM_LOG"; then
  pass "--config missing file is a startup error"
else
  fail "missing explicit CLI config diagnostic"
fi

if SKARWM_CONFIG="$TEST_DIR/missing-env.conf" TERMINAL=xterm timeout 3 ./build/skarwm >"$WM_LOG" 2>&1; then
  fail "missing SKARWM_CONFIG unexpectedly started"
elif grep -q 'SKARWM_CONFIG file not found:' "$WM_LOG"; then
  pass "missing SKARWM_CONFIG is a startup error"
else
  fail "missing SKARWM_CONFIG diagnostic"
fi

TERMINAL=xterm ./build/skarwm -c "$TEST_DIR/default.conf" >"$WM_LOG" 2>&1 &
WM_PID=$!
for _ in $(seq 1 40); do ./build/skarwm-msg get-windows >/dev/null 2>&1 && break; sleep 0.1; done

if grep -q 'config applied: load' "$WM_LOG"; then pass "modular root and relative import load"; else fail "initial modular load"; fi

xdotool key --clearmodifiers super+Return >/dev/null 2>&1
for _ in $(seq 1 50); do
  CLIENT=$(./build/skarwm-msg get-windows 2>/dev/null | sed -nE 's/.*"id":([0-9]+),"title":"xterm".*/\1/p')
  [ -n "${CLIENT:-}" ] && break
  sleep 0.1
done
TERM_PID=$(pgrep -n xterm || true)

geometry() {
  xwininfo -id "$CLIENT" 2>/dev/null | awk '/Width:/{w=$2}/Height:/{h=$2}/Absolute upper-left X:/{x=$4}/Absolute upper-left Y:/{y=$4}END{printf "%sx%s+%s+%s",w,h,x,y}'
}
wait_geometry() {
  local wanted=$1
  for _ in $(seq 1 40); do [ "$(geometry)" = "$wanted" ] && return 0; sleep 0.1; done
  return 1
}

if wait_geometry "1260x780+10+10"; then pass "initial imported settings apply"; else fail "initial geometry: $(geometry)"; fi

sed -i 's/outer_gap = 8/outer_gap = 20/' "$TEST_DIR/config.d/base.conf"
if wait_geometry "1236x756+22+22"; then pass "editing imported file hot-reloads"; else fail "import reload geometry: $(geometry)"; fi

sed -i '/border_width = 2/a unknown_property = true' "$TEST_DIR/config.d/base.conf"
sleep 0.8
if [ "$(geometry)" = "1236x756+22+22" ] && kill -0 "$WM_PID" 2>/dev/null; then
  pass "invalid imported file rolls back atomically"
else
  fail "invalid import rollback"
fi

sed -i '/unknown_property/d; s/outer_gap = 20/outer_gap = 12/' "$TEST_DIR/config.d/base.conf"
if wait_geometry "1252x772+14+14"; then pass "valid correction recovers automatically"; else fail "recovery geometry: $(geometry)"; fi

cat >"$TEST_DIR/config.d/local.conf" <<'CONF'
[window]
outer_gap = 30
CONF
if wait_geometry "1216x736+32+32"; then pass "creating optional import triggers reload"; else fail "optional import creation: $(geometry)"; fi

cat >>"$TEST_DIR/default.conf" <<'CONF'
required = config.d/missing.conf
CONF
sleep 0.8
if [ "$(geometry)" = "1216x736+32+32" ] && kill -0 "$WM_PID" 2>/dev/null; then
  pass "missing required import preserves live configuration"
else
  fail "required import rollback"
fi

kill "$WM_PID" 2>/dev/null || true
wait "$WM_PID" 2>/dev/null || true
WM_PID=""

cat >"$TEST_DIR/environment.conf" <<'CONF'
[general]
mod_key = super
[animation]
enabled = false
CONF
SKARWM_CONFIG="$TEST_DIR/environment.conf" TERMINAL=xterm ./build/skarwm >"$WM_LOG" 2>&1 &
WM_PID=$!
for _ in $(seq 1 40); do ./build/skarwm-msg get-windows >/dev/null 2>&1 && break; sleep 0.1; done
if grep -q "config applied: load from $TEST_DIR/environment.conf" "$WM_LOG"; then
  pass "SKARWM_CONFIG selects a valid modular root"
else
  fail "SKARWM_CONFIG selection"
fi

kill "$WM_PID" 2>/dev/null || true
wait "$WM_PID" 2>/dev/null || true
WM_PID=""
TERMINAL=xterm ./build/skarwm --config tests/decoration.conf >"$WM_LOG" 2>&1 &
WM_PID=$!
for _ in $(seq 1 40); do ./build/skarwm-msg get-windows >/dev/null 2>&1 && break; sleep 0.1; done
if grep -q 'config applied: load' "$WM_LOG"; then
  pass "explicit modular configuration loads"
else
  fail "explicit modular configuration"
  sed -n '1,20p' "$WM_LOG"
fi

kill "$WM_PID" 2>/dev/null || true
wait "$WM_PID" 2>/dev/null || true
WM_PID=""
TERMINAL=xterm SKARWM_BAR=/bin/true ./build/skarwm --config assets/default.conf >"$WM_LOG" 2>&1 &
WM_PID=$!
for _ in $(seq 1 40); do ./build/skarwm-msg get-windows >/dev/null 2>&1 && break; sleep 0.1; done
if grep -q 'config applied: load' "$WM_LOG"; then
  pass "modular example configuration loads"
else
  fail "modular example configuration"
  sed -n '1,20p' "$WM_LOG"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
