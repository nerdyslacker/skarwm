#!/usr/bin/env bash
# RandR 1.5 multi-monitor integration test on a private Xvnc display.

set -u
cd "$(dirname "$0")/.." || exit 2

DISP=:98
SOCK="${TMPDIR:-/tmp}/skarwm-randr-itest.sock"
PASS=0
FAIL=0
VNC_PID=
WM_PID=
SUB_PID=

say() { printf '%s\n' "$*"; }
pass() { PASS=$((PASS + 1)); say "PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); say "FAIL  $*"; }
cleanup() {
  [ -z "$SUB_PID" ] || kill "$SUB_PID" 2>/dev/null || true
  [ -z "$WM_PID" ] || kill "$WM_PID" 2>/dev/null || true
  [ -z "$VNC_PID" ] || kill "$VNC_PID" 2>/dev/null || true
  rm -f "$SOCK"
}
trap cleanup EXIT

for tool in Xvnc xrandr xdotool xwininfo xterm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    say "FATAL: missing integration-test dependency: $tool"
    exit 1
  fi
done

say "== skarwm RandR integration test (display $DISP) =="
Xvnc "$DISP" -geometry 1280x800 -depth 24 -localhost -SecurityTypes None \
  >"${TMPDIR:-/tmp}/skarwm_randr_xvnc.log" 2>&1 &
VNC_PID=$!
sleep 1
if ! kill -0 "$VNC_PID" 2>/dev/null; then
  say "FATAL: Xvnc failed to start on $DISP"
  sed -n '1,30p' "${TMPDIR:-/tmp}/skarwm_randr_xvnc.log"
  exit 1
fi
export DISPLAY=$DISP
export SKARWM_SOCKET=$SOCK

xrandr --setmonitor LEFT 640/170x800/210+0+0 VNC-0
xrandr --setmonitor RIGHT 640/170x800/210+640+0 none
if [ "$(xrandr --listactivemonitors | sed -n '1s/[^0-9]*//p')" != 2 ]; then
  say "FATAL: X server does not support two RandR 1.5 monitor objects"
  exit 1
fi

TERMINAL=xterm ./build/skarwm >"${TMPDIR:-/tmp}/skarwm_randr_wm.log" 2>&1 &
WM_PID=$!
sleep 1
if ! kill -0 "$WM_PID" 2>/dev/null; then
  say "FATAL: skarwm failed to start"
  cat "${TMPDIR:-/tmp}/skarwm_randr_wm.log"
  exit 1
fi

outputs=$(./build/skarwm-msg get-outputs)
if [[ $outputs == *'"name":"LEFT"'* && $outputs == *'"name":"RIGHT"'* ]]; then
  pass "discovers both RandR monitors"
else
  fail "RandR monitor discovery"
fi
if [[ $outputs == *'"name":"LEFT","active":true,"primary":true,"focused":true'* ]]; then
  pass "selects the primary monitor"
else
  fail "primary monitor selection"
fi

xdotool key --clearmodifiers super+Return >/dev/null 2>&1
wid=
for _ in $(seq 1 45); do
  wid=$(xdotool search --onlyvisible --class XTerm 2>/dev/null | head -1)
  [ -z "$wid" ] || break
  sleep 0.3
done
if [ -n "$wid" ]; then pass "spawns a client on the active monitor"; else fail "spawn on active monitor"; fi

if [ -n "$wid" ]; then ./build/skarwm-msg move output next >/dev/null; fi
x=
for _ in $(seq 1 30); do
  if [ -n "$wid" ]; then x=$(xwininfo -id "$wid" 2>/dev/null | awk '/Absolute upper-left X/{print $4}'); fi
  if [ -n "$x" ] && [ "$x" -ge 640 ]; then break; fi
  sleep 0.3
done
if [ -n "$x" ] && [ "$x" -ge 640 ]; then pass "moves a window to the next monitor"; else fail "move window to next monitor"; fi

./build/skarwm-msg focus output next >/dev/null
./build/skarwm-msg workspace 2 >/dev/null
./build/skarwm-msg focus output prev >/dev/null
outputs=$(./build/skarwm-msg get-outputs)
if [[ $outputs == *'"name":"LEFT"'*'"current_workspace":"1"'*'"name":"RIGHT"'*'"current_workspace":"2"'* ]]; then
  pass "keeps independent current workspaces per monitor"
else
  fail "independent monitor workspaces"
fi

./build/skarwm-msg subscribe output >"${TMPDIR:-/tmp}/skarwm_randr_events.log" 2>&1 &
SUB_PID=$!
sleep 0.5
xrandr --delmonitor RIGHT
sleep 1
if grep -q '"change":"disconnected","output":"RIGHT"' "${TMPDIR:-/tmp}/skarwm_randr_events.log"; then
  pass "emits an output event after hot-unplug"
else
  fail "RandR hot-unplug event"
fi
outputs=$(./build/skarwm-msg get-outputs)
if [[ $outputs == *'"name":"LEFT"'* && $outputs != *'"name":"RIGHT"'* ]]; then
  pass "removes a disconnected monitor from the model"
else
  fail "disconnected monitor reconciliation"
fi

say "== RandR done: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
