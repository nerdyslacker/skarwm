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
BAR_PID=

say() { printf '%s\n' "$*"; }
pass() { PASS=$((PASS + 1)); say "PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); say "FAIL  $*"; }
cleanup() {
  [ -z "$BAR_PID" ] || kill "$BAR_PID" 2>/dev/null || true
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
# Never inherit the interactive user's configuration: its autostarts (notably
# a desktop shell) and terminal binding make this topology test nondeterministic.
export SKARWM_CONFIG=/dev/null

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
topology=$(./build/skarwm-msg get-topology)
if [[ $topology == *'"generation":'* &&
      $topology == *'"name":"VNC-0"'*'"connected":true,"enabled":true'* &&
      $topology == *'"logical_outputs":['* ]]; then
  pass "reports committed physical and logical topology diagnostics"
else
  fail "committed topology diagnostics"
fi
if ./build/skarwm-msg screen refresh >/dev/null; then
  sleep 0.2
  topology=$(./build/skarwm-msg get-topology)
  if [[ $topology == *'"scheduler":"idle"'* ]]; then
    pass "manual refresh uses the non-blocking topology pipeline"
  else
    fail "manual topology refresh completion"
  fi
else
  fail "manual topology refresh command"
fi

# Keep the primary/active output on LEFT but place the pointer on RIGHT. The
# new client must follow the pointer rather than the previously active output.
xdotool mousemove 960 400 >/dev/null 2>&1
xterm >/dev/null 2>&1 &
wid=
x=
for _ in $(seq 1 45); do
  wid=$(xdotool search --onlyvisible --class XTerm 2>/dev/null | head -1)
  if [ -n "$wid" ]; then
    x=$(xwininfo -id "$wid" 2>/dev/null | awk '/Absolute upper-left X/{print $4}')
  fi
  if [ -n "$x" ] && [ "$x" -ge 640 ]; then break; fi
  sleep 0.3
done
if [ -n "$x" ] && [ "$x" -ge 640 ]; then
  pass "spawns a client on the monitor under the pointer"
else
  fail "spawn on pointer monitor"
fi

if [ -n "$wid" ]; then ./build/skarwm-msg move output previous >/dev/null; fi
x=
for _ in $(seq 1 30); do
  if [ -n "$wid" ]; then x=$(xwininfo -id "$wid" 2>/dev/null | awk '/Absolute upper-left X/{print $4}'); fi
  if [ -n "$x" ] && [ "$x" -lt 640 ]; then break; fi
  sleep 0.3
done
if [ -n "$x" ] && [ "$x" -lt 640 ]; then pass "moves a window to the previous monitor"; else fail "move window to previous monitor"; fi

# Moving a window leaves the source output active. Return focus to LEFT before
# checking that both outputs retain independent current workspaces.
./build/skarwm-msg focus output previous >/dev/null
./build/skarwm-msg focus output next >/dev/null
./build/skarwm-msg workspace 2 >/dev/null
./build/skarwm-msg focus output prev >/dev/null
outputs=$(./build/skarwm-msg get-outputs)
if [[ $outputs == *'"name":"LEFT"'*'"current_workspace":"1"'*'"name":"RIGHT"'*'"current_workspace":"2"'* ]]; then
  pass "keeps independent current workspaces per monitor"
else
  fail "independent monitor workspaces"
fi

./build/skarwm-bar --height 26 --workspaces 8 >"${TMPDIR:-/tmp}/skarwm_randr_bar.log" 2>&1 &
BAR_PID=$!
bar_geometries() {
  xwininfo -root -tree 2>/dev/null \
    | sed -nE '/"skarwm-bar"/s/.* ([0-9]+x[0-9]+\+[-0-9]+\+[-0-9]+).*/\1/p'
}
for _ in $(seq 1 30); do
  [ "$(bar_geometries | wc -l)" -eq 2 ] && break
  sleep 0.2
done
if bar_geometries | grep -q '^640x26+0+0$' &&
   bar_geometries | grep -q '^640x26+640+0$'; then
  pass "built-in bar follows the initial logical outputs"
else
  fail "built-in bar initial logical output geometry"
fi

# A WM-level split creates logical screens and projects them as RandR monitors.
# LEFT is active here and is exactly 640px wide, so 75/25 gives 480/160.
./build/skarwm-msg screen split enable >/dev/null
outputs=$(./build/skarwm-msg get-outputs)
if [[ $outputs == *'"name":"LEFT:left"'*'"rect":{"x":0,"y":0,"width":480,"height":800}'*'"physical_output":"LEFT"'* &&
      $outputs == *'"name":"LEFT:right"'*'"rect":{"x":480,"y":0,"width":160,"height":800}'*'"physical_output":"LEFT"'* ]]; then
  pass "runtime IPC creates a 75/25 logical split"
else
  fail "runtime logical split"
fi
monitors=$(xrandr --listactivemonitors)
if [[ $monitors == *'LEFT:left'* && $monitors == *'LEFT:right'* ]]; then
  pass "publishes virtual screens through RandR 1.5"
else
  fail "RandR virtual-screen publication"
fi
for _ in $(seq 1 30); do
  bars=$(bar_geometries)
  if [ "$(printf '%s\n' "$bars" | grep -c .)" -eq 3 ]; then break; fi
  sleep 0.2
done
if printf '%s\n' "$bars" | grep -q '^480x26+0+0$' &&
   printf '%s\n' "$bars" | grep -q '^160x26+480+0$' &&
   printf '%s\n' "$bars" | grep -q '^640x26+640+0$'; then
  pass "built-in bar creates one window per virtual screen"
else
  fail "built-in bar split geometry"
fi

./build/skarwm-msg screen split resize -20 >/dev/null
outputs=$(./build/skarwm-msg get-outputs)
if [[ $outputs == *'"name":"LEFT:left"'*'"rect":{"x":0,"y":0,"width":460,"height":800}'* &&
      $outputs == *'"name":"LEFT:right"'*'"rect":{"x":460,"y":0,"width":180,"height":800}'* ]]; then
  pass "runtime IPC moves the split boundary without gaps"
else
  fail "runtime split resize"
fi
monitors=$(xrandr --listactivemonitors)
if [[ $monitors == *'LEFT:left'* && $monitors == *'LEFT:right'* ]]; then
  pass "RandR virtual screens survive an in-place resize"
else
  fail "RandR virtual-screen resize publication"
fi
for _ in $(seq 1 30); do
  bars=$(bar_geometries)
  if printf '%s\n' "$bars" | grep -q '^460x26+0+0$' &&
     printf '%s\n' "$bars" | grep -q '^180x26+460+0$'; then break; fi
  sleep 0.2
done
if printf '%s\n' "$bars" | grep -q '^460x26+0+0$' &&
   printf '%s\n' "$bars" | grep -q '^180x26+460+0$'; then
  pass "built-in bars track virtual-screen resize"
else
  fail "built-in bar resized geometry"
fi

./build/skarwm-msg screen split ratio 0.50 >/dev/null
./build/skarwm-msg focus output next >/dev/null
./build/skarwm-msg workspace 4 >/dev/null
outputs=$(./build/skarwm-msg get-outputs)
if [[ $outputs == *'"name":"LEFT:left"'*'"rect":{"x":0,"y":0,"width":320,"height":800}'* &&
      $outputs == *'"name":"LEFT:right"'*'"current_workspace":"4"'* ]]; then
  pass "logical siblings keep independent workspaces and ratio updates"
else
  fail "logical split workspace/ratio"
fi

# Click workspace 3 on LEFT:right. Each bar sends the command with its own
# logical output name, so the sibling's workspace changes independently.
xdotool mousemove 390 10 click 1 >/dev/null 2>&1
for _ in $(seq 1 30); do
  outputs=$(./build/skarwm-msg get-outputs)
  [[ $outputs == *'"name":"LEFT:right"'*'"current_workspace":"3"'* ]] && break
  sleep 0.2
done
if [[ $outputs == *'"name":"LEFT:left"'*'"current_workspace":"1"'*'"name":"LEFT:right"'*'"current_workspace":"3"'* ]]; then
  pass "virtual-screen bar controls its own workspace"
else
  fail "virtual-screen bar workspace targeting"
fi

./build/skarwm-msg screen split disable >/dev/null
outputs=$(./build/skarwm-msg get-outputs)
if [[ $outputs == *'"name":"LEFT"'* && $outputs != *'"name":"LEFT:right"'* ]]; then
  pass "runtime IPC unsplits to the current physical output"
else
  fail "runtime logical unsplit"
fi
monitors=$(xrandr --listactivemonitors)
if [[ $monitors != *'LEFT:left'* && $monitors != *'LEFT:right'* ]]; then
  pass "removes virtual RandR monitors after unsplit"
else
  fail "RandR virtual-screen cleanup"
fi
for _ in $(seq 1 30); do
  [ "$(bar_geometries | wc -l)" -eq 2 ] && break
  sleep 0.2
done
if bar_geometries | grep -q '^640x26+0+0$' &&
   bar_geometries | grep -q '^640x26+640+0$'; then
  pass "built-in bar removes the retired virtual screen"
else
  fail "built-in bar unsplit geometry"
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

# The shell/bar must still receive pointer input after the output teardown.
# Workspace 2 occupies the second slot near x=45 in the left bar.
xdotool mousemove 45 10 click 1 >/dev/null 2>&1
for _ in $(seq 1 30); do
  outputs=$(./build/skarwm-msg get-outputs)
  [[ $outputs == *'"name":"LEFT"'*'"current_workspace":"2"'* ]] && break
  sleep 0.1
done
if [[ $outputs == *'"name":"LEFT"'*'"current_workspace":"2"'* ]]; then
  pass "pointer remains responsive after hot-unplug"
else
  fail "pointer input after hot-unplug"
fi

# Add the monitor back without restarting the WM.  This exercises the same
# resource/root-configure path as enabling a newly connected output inside an
# existing framebuffer.
xrandr --setmonitor RIGHT 640/170x800/210+640+0 none
for _ in $(seq 1 30); do
  outputs=$(./build/skarwm-msg get-outputs)
  [[ $outputs == *'"name":"RIGHT"'* ]] && break
  sleep 0.1
done
if grep -q '"change":"connected","output":"RIGHT"' "${TMPDIR:-/tmp}/skarwm_randr_events.log"; then
  pass "emits an output event after hot-plug"
else
  fail "RandR hot-plug event"
fi
if [[ $outputs == *'"name":"LEFT"'* && $outputs == *'"name":"RIGHT"'* ]]; then
  pass "recognizes a monitor added while running"
else
  fail "running monitor addition reconciliation"
fi

say "== RandR done: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
