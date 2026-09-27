#!/usr/bin/env bash
# Focused native-decoration smoke test. Uses a private Xvnc, one xterm, and the
# minimal tests/decoration.rc fixture. Run with `make itest-decoration`.

set -u
cd "$(dirname "$0")/.." || exit 2

DISP=":98"
export DISPLAY="$DISP"
export SKARWM_SOCKET="${TMPDIR:-/tmp}/skarwm-decoration-itest.sock"
WM_LOG="${TMPDIR:-/tmp}/skarwm_decoration_itest.log"
PASS=0
FAIL=0
XVNC_PID=""
WM_PID=""
TERM_PID=""
TARGET_PID=""

pass() { PASS=$((PASS+1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*"; }
cleanup() {
  [ -n "$TARGET_PID" ] && kill "$TARGET_PID" 2>/dev/null || true
  [ -n "$TERM_PID" ] && kill "$TERM_PID" 2>/dev/null || true
  [ -n "$WM_PID" ] && kill "$WM_PID" 2>/dev/null || true
  [ -n "$XVNC_PID" ] && kill "$XVNC_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

Xvnc "$DISP" -geometry 1280x800 -depth 24 -localhost -SecurityTypes None >"${TMPDIR:-/tmp}/xvnc-decoration-itest.log" 2>&1 &
XVNC_PID=$!
for _ in $(seq 1 30); do xdpyinfo -display "$DISP" >/dev/null 2>&1 && break; sleep 0.1; done

./build/skarwm -c tests/decoration.rc >"$WM_LOG" 2>&1 &
WM_PID=$!
for _ in $(seq 1 30); do ./build/skarwm-msg get-windows >/dev/null 2>&1 && break; sleep 0.1; done

xterm -title DecorationTest >/dev/null 2>&1 &
TERM_PID=$!
client=""
for _ in $(seq 1 50); do
  windows=$(./build/skarwm-msg get-windows 2>/dev/null)
  client=$(printf '%s\n' "$windows" | sed -nE 's/.*"id":([0-9]+),"title":"DecorationTest".*/\1/p')
  [ -n "$client" ] && break
  sleep 0.1
done
frame=$(xdotool search --name '^skarwm decoration$' 2>/dev/null | head -1)

if [ -n "$client" ] && [ -n "$frame" ]; then
  pass "decorated client and WM-owned frame mapped"
else
  fail "frame lifecycle"
  exit 1
fi
client_geom=$(xwininfo -id "$client" 2>/dev/null | awk '/Width:/{w=$2}/Height:/{h=$2}/Absolute upper-left X:/{x=$4}/Absolute upper-left Y:/{y=$4}END{printf "%sx%s+%s+%s",w,h,x,y}')
frame_geom=$(xwininfo -id "$frame" 2>/dev/null | awk '/Width:/{w=$2}/Height:/{h=$2}/Absolute upper-left X:/{x=$4}/Absolute upper-left Y:/{y=$4}END{printf "%sx%s+%s+%s",w,h,x,y}')
if [ "$client_geom" = "1256x759+12+29" ] && [ "$frame_geom" = "1264x784+8+8" ]; then
  pass "frame/client geometry uses the complete layout tile"
else
  fail "geometry client=$client_geom frame=$frame_geom"
fi

# Maximize button: compact 20px targets at the frame's right edge.
xdotool mousemove 1240 20 click 1 >/dev/null 2>&1
sleep 0.2
state=$(xprop -id "$client" _NET_WM_STATE 2>/dev/null)
if [[ $state == *MAXIMIZED_VERT* && $state == *MAXIMIZED_HORZ* ]]; then pass "maximize button uses real EWMH state"; else fail "maximize button"; fi

# Dragging the maximized tiled client restores it immediately. Releasing the
# ordinary title drag converts it to a normal floater.
xdotool mousemove 640 20 mousedown 1 mousemove 700 400 mouseup 1 >/dev/null 2>&1
sleep 0.2
state=$(xprop -id "$client" _NET_WM_STATE 2>/dev/null)
windows=$(./build/skarwm-msg get-windows 2>/dev/null)
if [[ $state != *MAXIMIZED_VERT* && $windows == *'"floating":true'* ]]; then
  pass "dragging maximized tile restores and undocked release becomes floating"
else
  fail "maximize-to-drag tiled fallback"
fi
read -r undocked_w undocked_h < <(xwininfo -id "$frame" 2>/dev/null | awk '/Width:/{w=$2}/Height:/{h=$2}END{print w,h}')
if [ "$undocked_w" -gt 500 ] && [ "$undocked_h" -gt 300 ]; then
  pass "undocked tile uses normal floating size instead of drag preview"
else
  fail "undocked floating size ${undocked_w}x${undocked_h}"
fi
./build/skarwm-msg toggle-floating >/dev/null 2>&1
sleep 0.2

# Minimize button is the third titlebar target from the right.
xdotool mousemove 1220 20 click 1 >/dev/null 2>&1
sleep 0.2
windows=$(./build/skarwm-msg get-windows 2>/dev/null)
if [[ $windows == *'"scratchpad":true'* && $windows == *'"scratchpad_register":1'* ]]; then pass "minimize button stashes in scratchpad register 1"; else fail "scratchpad minimize"; fi
./build/skarwm-msg scratchpad toggle 1 >/dev/null 2>&1
sleep 0.2
if xwininfo -id "$frame" 2>/dev/null | grep -q 'Map State: IsViewable'; then pass "normal scratchpad toggle restores frame"; else fail "scratchpad restore frame"; fi

./build/skarwm-msg toggle-fullscreen >/dev/null 2>&1
sleep 0.2
fullscreen_geom=$(xwininfo -id "$client" 2>/dev/null | awk '/Width:/{w=$2}/Height:/{h=$2}/Absolute upper-left X:/{x=$4}/Absolute upper-left Y:/{y=$4}END{printf "%sx%s+%s+%s",w,h,x,y}')
if [ "$fullscreen_geom" = "1280x800+0+0" ] && xwininfo -id "$frame" 2>/dev/null | grep -q 'Map State: IsUnMapped'; then
  pass "fullscreen suppresses the complete decoration"
else
  fail "fullscreen decoration suppression"
fi
./build/skarwm-msg toggle-fullscreen >/dev/null 2>&1
sleep 0.2

# Floating title drags reuse the normal move path.
./build/skarwm-msg toggle-floating >/dev/null 2>&1
sleep 0.2
read -r fx fy fw fh < <(xwininfo -id "$frame" 2>/dev/null | awk '/Absolute upper-left X:/{x=$4}/Absolute upper-left Y:/{y=$4}/Width:/{w=$2}/Height:/{h=$2}END{print x,y,w,h}')
xdotool mousemove $((fx+160)) $((fy+14)) mousedown 1 mousemove_relative -- 80 40 mouseup 1 >/dev/null 2>&1
sleep 0.2
read -r moved_x moved_y moved_w moved_h < <(xwininfo -id "$frame" 2>/dev/null | awk '/Absolute upper-left X:/{x=$4}/Absolute upper-left Y:/{y=$4}/Width:/{w=$2}/Height:/{h=$2}END{print x,y,w,h}')
if [ "$moved_x" -eq $((fx+80)) ] && [ "$moved_y" -eq $((fy+40)) ]; then pass "titlebar drag uses floating move path"; else fail "titlebar drag"; fi

# The top-right frame target remains reachable even when a large floater's
# bottom edge extends past the nested display.
xdotool mousemove $((moved_x+moved_w-3)) $((moved_y+2)) mousedown 1 mousemove_relative -- 48 -36 mouseup 1 >/dev/null 2>&1
sleep 0.2
read -r resized_w resized_h < <(xwininfo -id "$frame" 2>/dev/null | awk '/Width:/{w=$2}/Height:/{h=$2}END{print w,h}')
if [ "$resized_w" -gt "$moved_w" ] && [ "$resized_h" -gt "$moved_h" ]; then pass "frame corner uses constrained floating resize path"; else fail "frame corner resize"; fi

# An ordinary floating title drag near a screen edge must remain floating.
read -r snap_x snap_y snap_w snap_h < <(xwininfo -id "$frame" 2>/dev/null | awk '/Absolute upper-left X:/{x=$4}/Absolute upper-left Y:/{y=$4}/Width:/{w=$2}/Height:/{h=$2}END{print x,y,w,h}')
xdotool mousemove $((snap_x+120)) $((snap_y+12)) mousedown 1 mousemove 20 400 mouseup 1 >/dev/null 2>&1
sleep 0.2
windows=$(./build/skarwm-msg get-windows 2>/dev/null)
client_floating=$(printf '%s\n' "$windows" | sed -nE 's/.*"id":'"$client"'[^}]*"floating":(true|false).*/\1/p')
if [ "$client_floating" = "true" ]; then pass "ordinary floating drag near edge does not tile"; else fail "ordinary floating edge drag"; fi

# Alt+title drag uses the same destination-window tiling logic as Super-drag.
xterm -title TileTarget >/dev/null 2>&1 &
TARGET_PID=$!
target=""
for _ in $(seq 1 50); do
  windows=$(./build/skarwm-msg get-windows 2>/dev/null)
  target=$(printf '%s\n' "$windows" | sed -nE 's/.*"id":([0-9]+),"title":"TileTarget".*/\1/p')
  [ -n "$target" ] && break
  sleep 0.1
done
if [ -n "$target" ]; then
  read -r drag_x drag_y drag_w drag_h < <(xwininfo -id "$frame" 2>/dev/null | awk '/Absolute upper-left X:/{x=$4}/Absolute upper-left Y:/{y=$4}/Width:/{w=$2}/Height:/{h=$2}END{print x,y,w,h}')
  read -r target_x target_y target_w target_h < <(xwininfo -id "$target" 2>/dev/null | awk '/Absolute upper-left X:/{x=$4}/Absolute upper-left Y:/{y=$4}/Width:/{w=$2}/Height:/{h=$2}END{print x,y,w,h}')
  # The newly mapped tiled target has focus; activating the floater also
  # restores its normal above-tile stacking before pressing its titlebar.
  xdotool windowactivate --sync "$client" >/dev/null 2>&1
  xdotool mousemove $((drag_x+120)) $((drag_y+12)) keydown Alt_L mousedown 1 mousemove $((target_x+target_w/4)) $((target_y+target_h/2)) mouseup 1 keyup Alt_L >/dev/null 2>&1
  sleep 0.2
  windows=$(./build/skarwm-msg get-windows 2>/dev/null)
  client_floating=$(printf '%s\n' "$windows" | sed -nE 's/.*"id":'"$client"'[^}]*"floating":(true|false).*/\1/p')
  if [ "$client_floating" = "false" ]; then pass "Alt title drag applies normal tiled destination logic"; else fail "Alt title drag tiling"; fi
else
  fail "Alt title drag target setup"
fi

# Close is the rightmost titlebar target and must let xterm process WM_DELETE.
read -r close_x close_y close_w close_h < <(xwininfo -id "$frame" 2>/dev/null | awk '/Absolute upper-left X:/{x=$4}/Absolute upper-left Y:/{y=$4}/Width:/{w=$2}/Height:/{h=$2}END{print x,y,w,h}')
xdotool mousemove $((close_x+close_w-12)) $((close_y+14)) click 1 >/dev/null 2>&1
for _ in $(seq 1 30); do kill -0 "$TERM_PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$TERM_PID" 2>/dev/null; then fail "graceful close button"; else pass "close button exits cooperative client"; fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
