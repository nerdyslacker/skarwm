#!/usr/bin/env bash
# skarwm X11 integration smoke test.
#
#   usage: scripts/itest.sh
#
# Owns a private Xvnc on :99, rebuilds the WM when sources changed, runs the
# implemented integration steps and prints PASS/FAIL per step. Exits nonzero if
# any step fails. Pure-logic behaviour (columns/focus/viewport geometry) is
# asserted in depth by tests/core_tests; this file only checks that the wiring
# through X behaves the same way.
#
# Determinism: WM is started with TERMINAL=xterm and the pointer is parked in
# the bottom outer gap so EnterNotify never disturbs the model focus. Spawns
# are asynchronous (xterm can take several seconds to map under a WM), so every
# step waits (polls) for the expected tiled geometry rather than sleeping a
# fixed amount.
#
# Layout under test: "fill up to 2, then scroll" (PAGE_COLS = 2). For a 1280x800
# output with Config{Outer 8, Inner 8, Border 2} the work area is 1264x784 at
# (8,8), and the tiled *client* rectangles (tile inset by the 2px border) are:
#   - one window alone            -> 1260x780+10+10   (fills the work width)
#   - a two-window vertical stack -> 1260x384+10+10 / 1260x384+10+406
#   - a column of a 2+ strip      -> 624x780+10+10 or 624x780+646+10 (col0/col1)
# With a third (or later) column the strip overflows and the viewport pans; the
# focused (newest) column then sits at client X 646 and earlier columns leave
# the left edge (negative X). Hidden/other-workspace windows are parked at
# X = -20000 with full-output width 1280. Predicates below are therefore
# width-agnostic within {1260,624} and treat "tiled" as any such window whose
# X > -10000 (parked windows are 1280 wide, so they never match).

set -u
cd "$(dirname "$0")/.." || exit 2

DISP=":99"
PASS=0
FAIL=0
WM_LOG="${TMPDIR:-/tmp}/skarwm_itest.log"
export SKARWM_SOCKET="${TMPDIR:-/tmp}/skarwm-itest.sock"
# An empty XDG_CONFIG_HOME makes config discovery deterministic: unless an
# explicit -c file is given by the configuration checks, skarwm always falls
# back to its built-in defaults, no matter what config lives in the real $HOME.
XDGC="${TMPDIR:-/tmp}/skarwm_itest_xdg"
export XDG_CONFIG_HOME="$XDGC"

say() { printf '%s\n' "$*"; }
pass() { PASS=$((PASS+1)); say "PASS  $*"; }
fail() { FAIL=$((FAIL+1)); say "FAIL  $*"; }
key() { xdotool key --clearmodifiers "$@" >/dev/null 2>&1; sleep 0.4; }

# xtops -> "id WxH+X+Y" per xterm top-level child of the root.
#  0x40000c "title": ("xterm" "XTerm")  1260x780+10+10  +10+10
xtops() {
  xwininfo -root -tree 2>/dev/null \
    | grep '("xterm" "XTerm")' \
    | sed -nE 's/^[ ]*(0x[0-9a-f]+).*\("xterm" "XTerm"\)[ ]+([0-9]+x[0-9]+\+[-0-9]+\+[-0-9]+).*/\1 \2/p'
}

geom_of() { xtops | awk -v id="$1" '$1==id{print $2; exit}'; }

# Tiled windows are 1260 or 624 px wide; parked (hidden) windows keep the full
# output width (1280) and transient pre-layout windows are not tiled, so neither
# matches. Panning never changes a column's width, so off-screen-left columns
# (negative X) still count as tiled.
count_tiled() { xtops | awk '$2 ~ /^(1260|624)x/{n++} END{print n+0}'; }
first_tiled_id() { xtops | awk '$2 ~ /^(1260|624)x/{print $1; exit}'; }

# geosplit <WxH+X+Y> sets $gw $gh $gx $gy
geosplit() {
  gw=0; gh=0; gx=0; gy=0
  [[ $1 =~ ^([0-9]+)x([0-9]+)\+(-?[0-9]+)\+(-?[0-9]+)$ ]] || return 1
  gw=${BASH_REMATCH[1]}; gh=${BASH_REMATCH[2]}; gx=${BASH_REMATCH[3]}; gy=${BASH_REMATCH[4]}
}

# predicates (exit 0 when true)
two_side_by_side() { xtops | awk '$2=="624x780+10+10"{a++} $2=="624x780+646+10"{b++} END{exit !(a>=1 && b>=1)}'; }
stack_of_two()     { xtops | awk '$2=="1260x384+10+10"{a++} $2=="1260x384+10+406"{b++} END{exit !(a>=1 && b>=1)}'; }
geom_x_lt0() { g=$(geom_of "$1"); geosplit "$g" && [ "$gx" -lt 0 ]; }

# pollers: wait up to ~13.5s (45 * 0.3s) for a predicate/condition to hold
wait_for() { local i=0; while [ "$i" -lt 45 ]; do "$@" && return 0; sleep 0.3; i=$((i+1)); done; return 1; }
wait_geom() { local i=0; while [ "$i" -lt 45 ]; do [ "$(geom_of "$1")" = "$2" ] && return 0; sleep 0.3; i=$((i+1)); done; return 1; }
wait_focus() { local i=0; while [ "$i" -lt 30 ]; do [ "$(xdotool getwindowfocus 2>/dev/null | tr -d ' ')" = "$1" ] && return 0; sleep 0.3; i=$((i+1)); done; return 1; }
wait_tiled_n() { local i=0; while [ "$i" -lt 45 ]; do [ "$(count_tiled)" -ge "$1" ] && return 0; sleep 0.3; i=$((i+1)); done; return 1; }
wait_hidden_x() { # window parked off-screen (x <= -10000)
  local i=0; while [ "$i" -lt 30 ]; do
    x=$(xwininfo -id "$1" 2>/dev/null | awk '/Absolute upper-left X/{print $4}')
    if [ -n "$x" ] && [ "$x" -le -10000 ]; then return 0; fi
    sleep 0.3; i=$((i+1))
  done; return 1
}
ipc_window_count() { ./build/skarwm-msg get-windows 2>/dev/null | grep -o '"id":' | wc -l; }
ipc_count_is() { [ "$(ipc_window_count)" -eq "$1" ]; }
all_windows_are_tabs_n() {
  state=$(./build/skarwm-msg get-windows 2>/dev/null) || return 1
  [ "$(printf '%s' "$state" | grep -o '"id":' | wc -l)" -eq "$1" ] &&
    [ "$(printf '%s' "$state" | grep -o "\"tab_count\":$1" | wc -l)" -eq "$1" ]
}

die_display() {
  say "FATAL: Xvnc or WM failed to start"
  [ -f /tmp/xvnc_itest.log ] && sed -n '1,20p' /tmp/xvnc_itest.log
  [ -f "$WM_LOG" ] && { say "--- WM log ---"; cat "$WM_LOG"; }
  exit 1
}
cleanup() { pkill -x skarwm 2>/dev/null; pkill -x xterm 2>/dev/null; pkill -x Xvnc 2>/dev/null; rm -f "$SKARWM_SOCKET"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
say "== skarwm integration test (display $DISP) =="

if [ ! -x build/skarwm ] || find src -name '*.odin' -newer build/skarwm | grep -q .; then
  say "rebuilding…"
  odin build src -out:build/skarwm || { say "FATAL: odin build failed"; exit 1; }
fi
if [ ! -x build/skarwm-msg ] || find cmd/skarwm-msg src/core -name '*.odin' -newer build/skarwm-msg | grep -q .; then
  odin build cmd/skarwm-msg -out:build/skarwm-msg || { say "FATAL: skarwm-msg build failed"; exit 1; }
fi

cleanup; sleep 0.7
Xvnc "$DISP" -geometry 1280x800 -depth 24 -localhost -SecurityTypes None >/tmp/xvnc_itest.log 2>&1 &
sleep 1.2
export DISPLAY="$DISP"
xwininfo -root >/dev/null 2>&1 || die_display

rm -f "$WM_LOG"
TERMINAL=xterm nohup ./build/skarwm >"$WM_LOG" 2>&1 &
sleep 1
pgrep -x skarwm >/dev/null || die_display
xdotool mousemove 640 795 >/dev/null 2>&1; sleep 0.3

# ---- 1. spawn first terminal from an empty desktop --------------------------
key super+Return
if wait_tiled_n 1; then pass "spawn first tiled terminal (empty desktop)"; else fail "spawn first terminal"; fi
first=$(first_tiled_id)
if wait_geom "$first" "1260x780+10+10"; then pass "single window fills the work width"; else fail "single-window geometry"; fi

# ---- 2. spawn a second terminal -> two columns, still no scrolling ------------
key super+Return
if wait_tiled_n 2; then pass "spawn second terminal -> 2 columns"; else fail "spawn second terminal"; fi
# fill-up-to-2: both columns fit on screen together and the viewport never pans
if wait_for two_side_by_side; then pass "two columns tile side-by-side on screen (no scroll)"; else fail "two side-by-side"; fi

# ---- 3. move the focused (right) window left -> a vertical two-stack ----------
key super+shift+h
if wait_for stack_of_two; then pass "move left stacks into a single full-width column"; else fail "move left stack"; fi

# identify top/bottom ids by their current screen y
ty=; by=
while read -r id g; do
  y=${g##*+}; y=${y%+*}
  if [ "$y" = "10" ]; then ty=$id; else by=$id; fi
done < <(xtops | awk '$2 ~ /^1260x/')

if [ -n "$ty" ] && [ -n "$by" ] && wait_geom "$ty" "1260x384+10+10" && wait_geom "$by" "1260x384+10+406"; then
  pass "stack split geometry (top y=10, bottom y=406)"
else
  fail "stack split geometry"
fi
ty_dec=$(printf '%d' "$ty")   # XGetInputFocus returns decimal ids
by_dec=$(printf '%d' "$by")

# ---- 4. focus up/down within the stack ----------------------------------------
key super+k
if wait_focus "$ty_dec"; then pass "focus up -> top window"; else fail "focus up -> top"; fi
key super+j
if wait_focus "$by_dec"; then pass "focus down -> bottom window"; else fail "focus down -> bottom"; fi

# ---- 5. move down swaps stack order --------------------------------------------
key super+k
key super+shift+j
if wait_geom "$ty" "1260x384+10+406"; then pass "move down swaps stack order"; else fail "move down swap"; fi

# ---- 6. tabbed column layout ---------------------------------------------------
key super+t
if wait_geom "$ty" "1260x756+10+34" && wait_hidden_x "$by"; then
  pass "tabbed layout shows only the active tab at full column size"
else
  fail "tabbed active geometry"
fi
key super+k
if wait_focus "$by_dec" && wait_geom "$by" "1260x756+10+34" && wait_hidden_x "$ty"; then
  pass "focus up switches the active tab"
else
  fail "tabbed focus switch"
fi
key super+shift+Return
if wait_for all_windows_are_tabs_n 3; then
  pass "implicit Shift spawn opens a new tab"
else
  fail "implicit Shift spawn tab placement"
fi
key super+shift+q
if wait_for ipc_count_is 2; then
  pass "close generated tab before continuing"
else
  fail "close generated tab"
fi
key super+t
if wait_for two_side_by_side; then pass "tabbed toggle restores horizontal columns"; else fail "restore horizontal layout"; fi

# ---- 7. close focused via WM_DELETE ---------------------------------------------
key super+shift+q
if wait_tiled_n 1; then pass "close focused window (WM_DELETE)"; else fail "close focused window"; fi
surv=$(first_tiled_id)
if wait_geom "$surv" "1260x780+10+10"; then pass "survivor recentered after close"; else fail "survivor recenter"; fi

# ---- 8. fullscreen toggle + restore ---------------------------------------------
key super+f
if wait_geom "$surv" "1280x800+0+0"; then pass "fullscreen fills the output"; else fail "fullscreen geometry"; fi
key super+f
if wait_geom "$surv" "1260x780+10+10"; then pass "fullscreen restores tiled rect"; else fail "fullscreen restore"; fi

# ---- 9. workspace switch hides the window; switch back restores it --------------
key super+2
if wait_hidden_x "$surv"; then pass "workspace 2 hides ws-1 window"; else fail "workspace 2 hide"; fi
key super+1
if wait_geom "$surv" "1260x780+10+10"; then pass "workspace 1 restores window"; else fail "workspace 1 restore"; fi

# ---- 10. existing-window adoption on restart ------------------------------------
pkill -x skarwm; pkill -x xterm; sleep 0.7        # drop WM and all current windows
setsid /usr/bin/xterm -geometry 80x24 >/dev/null 2>&1 &
setsid /usr/bin/xterm -geometry 80x24 >/dev/null 2>&1 &
sleep 1.5                                       # clients map with no WM running
rm -f "$WM_LOG"
TERMINAL=xterm nohup ./build/skarwm >"$WM_LOG" 2>&1 &
sleep 1.2
pgrep -x skarwm >/dev/null || die_display
if wait_tiled_n 2; then pass "adopt pre-existing windows on restart"; else fail "adopt existing windows"; fi

# zero_tiled: no tiled window on screen (workspace empty or all windows parked)
zero_tiled() { [ "$(count_tiled)" = 0 ]; }

# ---- 10. scrolling viewport across a wide strip ---------------------------------
pkill -x skarwm; pkill -x xterm; sleep 0.7
rm -f "$WM_LOG"
TERMINAL=xterm nohup ./build/skarwm >"$WM_LOG" 2>&1 &
sleep 1.0
pgrep -x skarwm >/dev/null || die_display
xdotool mousemove 640 795 >/dev/null 2>&1; sleep 0.3

# Strip: page width (1264 - 8) / 2 = 628 tile / 624 client, step 636. Columns 0
# and 1 fill the work area exactly; a 3rd column makes the strip 1900px wide and
# each later spawn lands to the right of the focused (newest) column, panning the
# viewport so the newest column sits at client X 646 and earlier columns leave
# the left edge. (4 columns -> strip 2536, max viewport 1272.)
ok4=true
for n in 1 2 3 4; do
  key super+Return
  wait_tiled_n "$n" || { ok4=false; break; }
done
if [ "$ok4" = true ]; then pass "spawn 4 columns on the strip"; else fail "spawn 4 columns"; fi

# identify leftmost/rightmost windows by current screen x
left_id=; right_id=; left_x=99999; right_x=-99999
while read -r id g; do
  geosplit "$g" || continue
  if [ "$gx" -lt "$left_x" ]; then left_x=$gx; left_id=$id; fi
  if [ "$gx" -gt "$right_x" ]; then right_x=$gx; right_id=$id; fi
done < <(xtops)

# scrolling started with the 3rd column: the 1st (leftmost) column is off-screen
if wait_for geom_x_lt0 "$left_id"; then pass "3rd+ spawn pans the strip (1st column leaves view)"; else fail "strip pan start"; fi

# focus is the newest = rightmost column; viewport clamps at max so the last
# column's right edge sits against the work-area right edge (client x = 646).
if wait_focus "$(printf '%d' "$right_id")"; then pass "newest column focused at far right"; else fail "far-right focus"; fi
if wait_geom "$right_id" "624x780+646+10"; then pass "viewport clamps at strip max (right edge aligned)"; else fail "right clamp geometry"; fi

# walk focus back three columns to the leftmost one: viewport must return to 0
for _ in 1 2 3; do key super+h; done
if wait_focus "$(printf '%d' "$left_id")"; then pass "focus left to the leftmost column"; else fail "focus left walk"; fi
if wait_geom "$left_id" "624x780+10+10"; then pass "viewport returns to 0 at leftmost column"; else fail "left clamp geometry"; fi

# an extra focus-left beyond the edge must be a no-op (no overscroll)
key super+h
if wait_geom "$left_id" "624x780+10+10" && [ "$(xdotool getwindowfocus 2>/dev/null | tr -d ' ')" = "$(printf '%d' "$left_id")" ]; then
  pass "no overscroll past the leftmost column"
else
  fail "overscrolled past leftmost"
fi

# Mod+wheel scrolls the viewport without moving keyboard focus. Wheel down
# reveals columns to the right (content moves left); wheel up returns left.
xdotool keydown super >/dev/null 2>&1
xdotool click 5 >/dev/null 2>&1
xdotool keyup super >/dev/null 2>&1
if wait_geom "$left_id" "624x780+-626+10" && [ "$(xdotool getwindowfocus 2>/dev/null | tr -d ' ')" = "$(printf '%d' "$left_id")" ]; then
  pass "Mod+wheel down scrolls right without changing focus"
else
  fail "Mod+wheel down viewport scroll"
fi
xdotool keydown super >/dev/null 2>&1
xdotool click 4 >/dev/null 2>&1
xdotool keyup super >/dev/null 2>&1
if wait_geom "$left_id" "624x780+10+10"; then
  pass "Mod+wheel up scrolls left"
else
  fail "Mod+wheel up viewport scroll"
fi

# ---- 11. dynamic workspaces ------------------------------------------------------
# ws1 holds the 4 columns; the focused (leftmost) window moves to a fresh ws2.
moved=$(xdotool getwindowfocus 2>/dev/null | tr -d ' ')   # decimal id
key super+shift+2
if wait_tiled_n 3; then pass "move focused window to ws2 (ws1 left with 3)"; else fail "move-to-workspace"; fi

key super+2
moved_hex=$(printf '0x%x' "$moved")   # the window we just moved is the one shown
if wait_geom "$moved_hex" "1260x780+10+10"; then
  f=$(xdotool getwindowfocus 2>/dev/null | tr -d ' ')
  if [ "$f" = "$moved" ]; then pass "ws2 shows the moved window full-width, focused"; else fail "ws2 focus ($f vs $moved)"; fi
else
  fail "ws2 shows the moved window"
fi

key super+1
if wait_tiled_n 3; then pass "ws1 restores its 3 remaining columns"; else fail "ws1 restore after move"; fi

# dynamic next/prev cycle between the two populated workspaces
key super+n
if wait_geom "$moved_hex" "1260x780+10+10"; then pass "workspace next (super+n) lands on ws2"; else fail "workspace next"; fi
key super+p
if wait_tiled_n 3; then pass "workspace prev (super+p) returns to ws1"; else fail "workspace prev"; fi

# jumping to a never-used id creates that workspace on demand and shows it empty
key super+9
if wait_for zero_tiled; then pass "goto fresh workspace 9 (created empty on demand)"; else fail "workspace 9 create"; fi
key super+1
if wait_tiled_n 3; then pass "back to ws1"; else fail "back to ws1"; fi

# ------------------------------------------------------------------------------
# ---- 12. rc config: load, atomic reload, keep-previous-on-error ----------------
# The WM is restarted with an explicit -c rc file. A spawn
# must tile exactly like the built-in defaults; editing outer_gap/border_width and
# pressing super+shift+r (bound in the rc as `call : mod + Shift + r : reload`)
# must reflow the existing window to the new geometry. A deliberately malformed rc
# (unknown action token) must leave the previous settings in force and the WM alive.
say "== rc config: load / reload / keep-previous-on-error =="
rm -rf "$XDGC"; mkdir -p "$XDGC"
RC=/tmp/skarwm_itest.rc
cat > "$RC" <<'RC'
mod_key : super
inner_gap : 8
outer_gap : 8
border_width : 2
focus_follows_mouse : true
bind : mod + Return : "xterm"
call : mod + Shift + r : reload_config
call : mod + Shift + q : close_window
call : mod + f     : togglefullscreen
call : mod + space : togglefloating
call : mod + h : focusleft
call : mod + l : focusright
workspace : mod + 1 : view 1
workspace : mod + 2 : view 2
RC

pkill -x skarwm; pkill -x xterm; sleep 0.7
rm -f "$WM_LOG"
TERMINAL=xterm nohup ./build/skarwm -c "$RC" >"$WM_LOG" 2>&1 &
sleep 1.2
pgrep -x skarwm >/dev/null || die_display
xdotool mousemove 640 795 >/dev/null 2>&1; sleep 0.3

# rc defaults mirror the built-ins, so a first spawn tiles single full-width
key super+Return
if wait_tiled_n 1; then pass "rc config: spawn tiles under -c file"; else fail "rc spawn"; fi
rcwin=$(first_tiled_id)
if wait_geom "$rcwin" "1260x780+10+10"; then pass "rc config: single window geometry (outer 8 / border 2)"; else fail "rc geometry"; fi

# reload with a changed outer_gap/border_width reflows the *existing* window
cat > "$RC" <<'RC'
mod_key : super
outer_gap : 20
inner_gap : 8
border_width : 4
bind : mod + Return : "xterm"
call : mod + Shift + r : reload_config
call : mod + Shift + q : close_window
call : mod + f     : togglefullscreen
call : mod + space : togglefloating
call : mod + h : focusleft
call : mod + l : focusright
workspace : mod + 1 : view 1
workspace : mod + 2 : view 2
RC
key super+shift+r
if wait_geom "$rcwin" "1232x752+24+24"; then pass "rc config: atomic reload reflows to outer 20 / border 4"; else fail "rc reload geometry"; fi

# malformed rc (unknown action token) -> previous config kept, WM alive
printf 'call : mod + x : no_such_action\n' >> "$RC"
pid_before=$(pgrep -x skarwm | head -1)
key super+shift+r
sleep 1
pid_after=$(pgrep -x skarwm | head -1)
if [ -n "$pid_after" ] && [ "$pid_after" = "$pid_before" ] \
   && [ "$(geom_of "$rcwin")" = "1232x752+24+24" ]; then
  pass "rc config: malformed reload keeps previous config and stays alive"
else
  fail "rc config keep-previous-on-error (before=$pid_before after=$pid_after)"
fi

# ------------------------------------------------------------------------------
# 10. EWMH/ICCCM compatibility
#
# Root/client EWMH properties are asserted via xprop; the message *paths* are
# exercised with the tools that produce them: xdotool windowactivate sends
# _NET_ACTIVE_WINDOW to the root, and wmctrl (when installed) provides the
# _NET_WM_STATE / _NET_CURRENT_DESKTOP / _NET_CLOSE_WINDOW messages. Without
# wmctrl those steps are skipped, not failed.
# ------------------------------------------------------------------------------
say "== 10. ewmh/icccm =="

# xprop value helpers: xp_val prints the value token(s) after '= ', xp_hex the
# first window id in "# 0x…" form (both empty when the property is absent).
xp_val() { xprop "$@" 2>/dev/null | sed -nE 's/^.*= //p' | tr '\n' ' ' | sed 's/ $//'; }
xp_hex() { xprop "$@" 2>/dev/null | sed -nE 's/.*# (0x[0-9a-fA-F]+).*/\1/p' | tr 'A-F' 'a-f' | head -1; }
wait_xp() { local want="$1"; shift; local i=0; while [ "$i" -lt 30 ]; do
  [ "$(xp_val "$@")" = "$want" ] && return 0; sleep 0.3; i=$((i+1)); done; return 1; }
wait_xp_hex() { local want="$1"; shift; local i=0; while [ "$i" -lt 30 ]; do
  [ "$(xp_hex "$@")" = "$want" ] && return 0; sleep 0.3; i=$((i+1)); done; return 1; }

ew="$rcwin" # configuration-test window: 1232x752+24+24 on workspace 1, focused

# root advertises the WM (check window + names + supported subset)
if xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id"; then
  pass "ewmh: _NET_SUPPORTING_WM_CHECK on root"
else
  fail "ewmh: _NET_SUPPORTING_WM_CHECK on root"
fi
checkwin=$(xp_hex -root _NET_SUPPORTING_WM_CHECK)
if [ -n "$checkwin" ] && xprop -id "$checkwin" _NET_WM_NAME 2>/dev/null | grep -q '"skarwm"'; then
  pass "ewmh: check window names the WM (skarwm)"
else
  fail "ewmh: check window name (checkwin=$checkwin)"
fi
if xprop -root _NET_WM_NAME | grep -q '"skarwm"'; then
  pass "ewmh: root _NET_WM_NAME"
else
  fail "ewmh: root _NET_WM_NAME"
fi
sup=$(xprop -root _NET_SUPPORTED 2>/dev/null)
if [ -n "$sup" ] && echo "$sup" | grep -q _NET_CLIENT_LIST \
   && echo "$sup" | grep -q _NET_ACTIVE_WINDOW \
   && echo "$sup" | grep -q _NET_WM_STATE_FULLSCREEN; then
  pass "ewmh: _NET_SUPPORTED claims the implemented subset"
else
  fail "ewmh: _NET_SUPPORTED subset"
fi

# managed clients carry _NET_WM_DESKTOP and ICCCM WM_STATE Normal
if wait_xp "0" -id "$ew" _NET_WM_DESKTOP; then
  pass "ewmh: client _NET_WM_DESKTOP = workspace id - 1"
else
  fail "ewmh: client _NET_WM_DESKTOP ($(xp_val -id "$ew" _NET_WM_DESKTOP))"
fi
if xprop -id "$ew" WM_STATE 2>/dev/null | grep -q Normal; then
  pass "ewmh: client WM_STATE = Normal"
else
  fail "ewmh: client WM_STATE"
fi
if wait_xp_hex "$ew" -root _NET_ACTIVE_WINDOW; then
  pass "ewmh: _NET_ACTIVE_WINDOW tracks the focused client"
else
  fail "ewmh: _NET_ACTIVE_WINDOW ($(xp_hex -root _NET_ACTIVE_WINDOW))"
fi
if xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -q "$ew"; then
  pass "ewmh: client appears in _NET_CLIENT_LIST"
else
  fail "ewmh: _NET_CLIENT_LIST"
fi

# workspace switch keeps root desktop properties in sync; the hidden window
# stays advertised but loses focus (active window = None)
key super+2
if wait_xp "1" -root _NET_CURRENT_DESKTOP; then
  pass "ewmh: workspace switch updates _NET_CURRENT_DESKTOP"
else
  fail "ewmh: _NET_CURRENT_DESKTOP after switch ($(xp_val -root _NET_CURRENT_DESKTOP))"
fi
if wait_xp "2" -root _NET_NUMBER_OF_DESKTOPS; then
  pass "ewmh: _NET_NUMBER_OF_DESKTOPS grows with the workspace list"
else
  fail "ewmh: _NET_NUMBER_OF_DESKTOPS ($(xp_val -root _NET_NUMBER_OF_DESKTOPS))"
fi
if wait_xp_hex "0x0" -root _NET_ACTIVE_WINDOW; then
  pass "ewmh: no active window on an empty workspace (None)"
else
  fail "ewmh: _NET_ACTIVE_WINDOW None on empty workspace"
fi
if wait_hidden_x "$ew"; then
  pass "ewmh: window parked while its workspace is inactive"
else
  fail "ewmh: window parked on inactive workspace"
fi
if xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -q "$ew"; then
  pass "ewmh: _NET_CLIENT_LIST spans all workspaces"
else
  fail "ewmh: _NET_CLIENT_LIST across workspaces"
fi

# activation request (_NET_ACTIVE_WINDOW client message from xdotool)
xdotool windowactivate "$ew" >/dev/null 2>&1
if wait_xp "0" -root _NET_CURRENT_DESKTOP && wait_xp_hex "$ew" -root _NET_ACTIVE_WINDOW; then
  pass "ewmh: _NET_ACTIVE_WINDOW message activates a window on another workspace"
else
  fail "ewmh: activation via client message"
fi
if wait_geom "$ew" "1232x752+24+24"; then
  pass "ewmh: activated window re-shown and laid out"
else
  fail "ewmh: activated window geometry"
fi

# fullscreen state round-trip through the keybinding: geometry + _NET_WM_STATE
key super+f
if wait_geom "$ew" "1280x800+0+0"; then
  pass "ewmh: fullscreen covers the output"
else
  fail "ewmh: fullscreen geometry ($(geom_of "$ew"))"
fi
if xprop -id "$ew" _NET_WM_STATE 2>/dev/null | grep -q FULLSCREEN; then
  pass "ewmh: client _NET_WM_STATE carries FULLSCREEN"
else
  fail "ewmh: client _NET_WM_STATE FULLSCREEN"
fi
key super+f
if wait_geom "$ew" "1232x752+24+24"; then
  pass "ewmh: leaving fullscreen restores geometry"
else
  fail "ewmh: fullscreen restore"
fi
if ! xprop -id "$ew" _NET_WM_STATE 2>/dev/null | grep -q FULLSCREEN; then
  pass "ewmh: _NET_WM_STATE cleared when fullscreen ends"
else
  fail "ewmh: _NET_WM_STATE not cleared"
fi

# message-driven paths need wmctrl; skip cleanly when absent
if command -v wmctrl >/dev/null 2>&1; then
  wmctrl -i -r "$ew" -b add,fullscreen
  if wait_geom "$ew" "1280x800+0+0"; then
    pass "ewmh: _NET_WM_STATE message (wmctrl) enters fullscreen"
  else
    fail "ewmh: wmctrl fullscreen add"
  fi
  wmctrl -i -r "$ew" -b remove,fullscreen
  if wait_geom "$ew" "1232x752+24+24"; then
    pass "ewmh: _NET_WM_STATE message leaves fullscreen"
  else
    fail "ewmh: wmctrl fullscreen remove"
  fi
  wmctrl -s 1
  if wait_xp "1" -root _NET_CURRENT_DESKTOP; then
    pass "ewmh: _NET_CURRENT_DESKTOP message (wmctrl) switches workspace"
  else
    fail "ewmh: wmctrl -s"
  fi
  wmctrl -i -a "$ew"
  if wait_xp "0" -root _NET_CURRENT_DESKTOP && wait_geom "$ew" "1232x752+24+24"; then
    pass "ewmh: _NET_ACTIVE_WINDOW message (wmctrl) reactivates"
  else
    fail "ewmh: wmctrl activate"
  fi
  wmctrl -i -c "$ew"
  if wait_for sh -c "! xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -q '$ew'"; then
    pass "ewmh: _NET_CLOSE_WINDOW message closes the client"
  else
    fail "ewmh: wmctrl close"
  fi
else
  say "SKIP  ewmh message-path steps (_NET_WM_STATE/_NET_CURRENT_DESKTOP/_NET_CLOSE_WINDOW): wmctrl not installed"
fi

# ------------------------------------------------------------------------------
# ---- 13. docks and struts ------------------------------------------------------
# An EWMH dock (panel) window fabricated with python-xlib (scripts/xdock.py):
# classified by _NET_WM_WINDOW_TYPE, never focused, visible on every workspace,
# stacked above windows (fullscreen included), and its _NET_WM_STRUT_PARTIAL
# shrinks the tiling work area live. Work-area numbers below assume the built-in
# defaults (outer 8 / border 2): baseline client 1260x780+10+10; a 24 px top
# strut pushes it to 1260x764+10+26; a 48 px strut to 1260x740+10+50; the root
# _NET_WORKAREA is "8, 24, 1264, 768" repeated per desktop.
say "== 13. docks and struts =="
pkill -x skarwm; pkill -x xterm; sleep 0.7
rm -f "$WM_LOG"
TERMINAL=xterm nohup ./build/skarwm >"$WM_LOG" 2>&1 &
sleep 1.2
pgrep -x skarwm >/dev/null || die_display
xdotool mousemove 640 795 >/dev/null 2>&1; sleep 0.3

# dock_geo reports "WxH+X+Y" for any window id (xtops only matches xterms)
dock_geo() {
  local info; info=$(xwininfo -id "$1" 2>/dev/null) || return 1
  local x y w h
  w=$(printf '%s\n' "$info" | awk '/Width:/{print $2; exit}')
  h=$(printf '%s\n' "$info" | awk '/Height:/{print $2; exit}')
  x=$(printf '%s\n' "$info" | awk '/Absolute upper-left X/{print $4; exit}')
  y=$(printf '%s\n' "$info" | awk '/Absolute upper-left Y/{print $4; exit}')
  [ -n "$x" ] && printf '%sx%s+%s+%s\n' "$w" "$h" "$x" "$y"
}
wait_abs_geom() { local i=0; while [ "$i" -lt 45 ]; do
  [ "$(dock_geo "$1")" = "$2" ] && return 0; sleep 0.3; i=$((i+1)); done; return 1; }
# tree_pos: line number of a window in xwininfo -root -tree (children are
# listed top-most first, so a lower line = stacked above)
tree_pos() { xwininfo -root -tree 2>/dev/null | grep -n "$1" | head -1 | cut -d: -f1; }

DOCK_DIR="${TMPDIR:-/tmp}/skarwm_itest_dock"
rm -rf "$DOCK_DIR"; mkdir -p "$DOCK_DIR"; mkfifo "$DOCK_DIR/ctl"
python3 scripts/xdock.py --ctl "$DOCK_DIR/ctl" --id-file "$DOCK_DIR/id" new --top 24 >"$DOCK_DIR/log" 2>&1 &
dock_pid=$!
exec 9>"$DOCK_DIR/ctl"   # hold the write end: the keeper exits when we close it

DOCK=""
i=0; while [ -z "$DOCK" ] && [ "$i" -lt 30 ]; do
  DOCK=$(cat "$DOCK_DIR/id" 2>/dev/null); sleep 0.2; i=$((i+1))
done
if [ -n "$DOCK" ] && wait_abs_geom "$DOCK" "1280x24+0+0"; then
  pass "dock: panel mapped at its own rect, borderless geometry"
else
  fail "dock: fabricated panel not adopted ($DOCK)"
fi
if xprop -id "$DOCK" _NET_WM_DESKTOP 2>/dev/null | grep -q "not found"; then
  pass "dock: never gains a _NET_WM_DESKTOP (Ws == nil)"
else
  fail "dock: got a _NET_WM_DESKTOP ($(xprop -id "$DOCK" _NET_WM_DESKTOP 2>/dev/null))"
fi
if xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -q "$DOCK"; then
  pass "dock: listed in _NET_CLIENT_LIST like any managed client"
else
  fail "dock: absent from _NET_CLIENT_LIST"
fi
if xprop -root _NET_SUPPORTED 2>/dev/null | grep -q _NET_WM_STRUT_PARTIAL \
   && xprop -root _NET_SUPPORTED 2>/dev/null | grep -q _NET_WORKAREA; then
  pass "dock: root _NET_SUPPORTED advertises struts + workarea"
else
  fail "dock: _NET_SUPPORTED missing strut/workarea atoms"
fi

# the dock's 24 px top strut shrinks the work area for tiled windows
key super+Return
if wait_tiled_n 1; then pass "dock: window spawns while the panel is up"; else fail "dock: spawn"; fi
xt=$(first_tiled_id)
if wait_geom "$xt" "1260x764+10+26"; then
  pass "dock: top strut shrinks the work area (y=26, h=764)"
else
  fail "dock: strut geometry ($(geom_of "$xt"))"
fi

# hovering the panel must not steal focus (docks are unfocusable)
xdotool mousemove 640 10 >/dev/null 2>&1; sleep 0.5
f=$(xdotool getwindowfocus 2>/dev/null | tr -d ' ')
if [ "$f" = "$(printf '%d' "$xt")" ]; then
  pass "dock: EnterNotify over the panel never steals focus"
else
  fail "dock: focus stolen by hover (focused=$f)"
fi
xdotool mousemove 640 795 >/dev/null 2>&1; sleep 0.3

# workarea root property mirrors the current work rect (one desktop so far)
if wait_xp "8, 24, 1264, 768" -root _NET_WORKAREA; then
  pass "dock: _NET_WORKAREA = work rect (8,24,1264,768)"
else
  fail "dock: _NET_WORKAREA ($(xp_val -root _NET_WORKAREA))"
fi

# workspace switch parks the window but the panel stays (output-level)
key super+2
if wait_hidden_x "$xt"; then pass "dock: ws switch parks the tiled window"; else fail "dock: park"; fi
if wait_abs_geom "$DOCK" "1280x24+0+0"; then
  pass "dock: panel visible on every workspace"
else
  fail "dock: panel hidden by ws switch"
fi
if wait_xp "8, 24, 1264, 768, 8, 24, 1264, 768" -root _NET_WORKAREA; then
  pass "dock: workarea repeated per desktop (2 desktops now)"
else
  fail "dock: workarea multi-desktop ($(xp_val -root _NET_WORKAREA))"
fi
key super+1
if wait_geom "$xt" "1260x764+10+26"; then pass "dock: back on ws1 the window retiles below"; else fail "dock: ws1 restore"; fi

# fullscreen covers the output; the panel stays visible and stacked above
key super+f
if wait_geom "$xt" "1280x800+0+0"; then pass "dock: window fullscreens over the work area"; else fail "dock: fullscreen"; fi
if wait_abs_geom "$DOCK" "1280x24+0+0"; then
  pass "dock: panel survives fullscreen"
else
  fail "dock: panel hidden by fullscreen"
fi
dp=$(tree_pos "$DOCK"); xp=$(tree_pos "$xt")
if [ -n "$dp" ] && [ -n "$xp" ] && [ "$dp" -lt "$xp" ]; then
  pass "dock: stacked above the fullscreen window"
else
  fail "dock: stacking order (dock line $dp vs window line $xp)"
fi
key super+f
if wait_geom "$xt" "1260x764+10+26"; then pass "dock: fullscreen exit retiles below the panel"; else fail "dock: fs exit"; fi

# a WM restart re-adopts the still-mapped panel: strut + geometry come back
pkill -x skarwm; sleep 0.7
rm -f "$WM_LOG"
TERMINAL=xterm nohup ./build/skarwm >"$WM_LOG" 2>&1 &
sleep 1.2
pgrep -x skarwm >/dev/null || die_display
xdotool mousemove 640 795 >/dev/null 2>&1; sleep 0.3
if wait_geom "$xt" "1260x764+10+26" && wait_abs_geom "$DOCK" "1280x24+0+0"; then
  pass "dock: WM restart re-adopts panel + strut"
else
  fail "dock: restart adoption ($(geom_of "$xt"))"
fi

# live strut change: PropertyNotify -> Update_Reserved -> reflow of the window
echo "strut-top 48" >&9
if wait_geom "$xt" "1260x740+10+50"; then
  pass "dock: live strut update (24 -> 48) reflows the window"
else
  fail "dock: live strut change ($(geom_of "$xt"))"
fi

# withdrawing the panel releases its reservation
echo "unmap" >&9
if wait_geom "$xt" "1260x780+10+10"; then
  pass "dock: panel unmap releases the strut (back to baseline)"
else
  fail "dock: unmap release ($(geom_of "$xt"))"
fi

# teardown: close the FIFO (keeper exits, server drops its windows)
exec 9>&-
kill "$dock_pid" 2>/dev/null
rm -rf "$DOCK_DIR"

# ------------------------------------------------------------------------------
# ---- 14. IPC command/query/event round trip ---------------------------------
say "== 14. ipc =="
if build/skarwm-msg get-workspaces | grep -q '"focused":true'; then
  pass "ipc: GET_WORKSPACES returns focused workspace JSON"
else
  fail "ipc: GET_WORKSPACES"
fi
if build/skarwm-msg get-windows | grep -q '"windows":\['; then
  pass "ipc: GET_WINDOWS returns window snapshot JSON"
else
  fail "ipc: GET_WINDOWS"
fi

IPC_LOG="${TMPDIR:-/tmp}/skarwm_itest_ipc_events.log"
rm -f "$IPC_LOG"
timeout 5 build/skarwm-msg subscribe workspace window >"$IPC_LOG" 2>&1 &
sub_pid=$!
sleep 0.4
if build/skarwm-msg workspace 2 | grep -q '"success":true' \
   && wait_xp "1" -root _NET_CURRENT_DESKTOP; then
  pass "ipc: RUN_COMMAND switches workspace"
else
  fail "ipc: RUN_COMMAND workspace 2"
fi
sleep 0.4
kill "$sub_pid" 2>/dev/null
wait "$sub_pid" 2>/dev/null || true
if grep -q '"change":"focus"' "$IPC_LOG"; then
  pass "ipc: subscribed workspace focus event delivered"
else
  fail "ipc: workspace subscription ($(cat "$IPC_LOG" 2>/dev/null))"
fi
build/skarwm-msg workspace 1 >/dev/null 2>&1 || true
rm -f "$IPC_LOG"

# ------------------------------------------------------------------------------
say "== done: $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ] && exit 0 || exit 1
