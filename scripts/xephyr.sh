#!/bin/sh
# Run skarwm interactively in a nested Xephyr X server.

set -eu

cd "$(dirname "$0")/.."

mode=${1:-single}
if [ "$#" -gt 0 ]; then
    shift
fi

case "$mode" in
    single|multi) ;;
    *)
        printf 'usage: %s [single|multi] [skarwm arguments...]\n' "$0" >&2
        exit 2
        ;;
esac

# Interactive Xephyr runs exercise the full desktop configuration by default.
# An explicit -c/--config supplied after the mode still takes precedence.
has_config=false
expect_config_path=false
config_path=extra/config.rc
for arg in "$@"; do
    if [ "$expect_config_path" = true ]; then
        config_path=$arg
        has_config=true
        expect_config_path=false
        continue
    fi
    case "$arg" in
        -c|--config) expect_config_path=true ;;
    esac
done
if [ "$expect_config_path" = true ]; then
    printf 'error: -c/--config requires a file path\n' >&2
    exit 2
fi
if [ "$has_config" = false ]; then
    set -- -c extra/config.rc "$@"
fi

for tool in Xephyr xwininfo; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'error: %s is required for Xephyr testing\n' "$tool" >&2
        exit 1
    fi
done
if [ "$mode" = multi ] && ! command -v xrandr >/dev/null 2>&1; then
    printf 'error: xrandr is required for multi-monitor Xephyr testing\n' >&2
    exit 1
fi
if [ -z "${DISPLAY:-}" ]; then
    printf 'error: Xephyr must be started from an existing graphical X11 session\n' >&2
    exit 1
fi

nested_display=${SKARWM_XEPHYR_DISPLAY:-:2}
socket_path=${SKARWM_XEPHYR_SOCKET:-${TMPDIR:-/tmp}/skarwm-xephyr-$$.sock}
log_path=${TMPDIR:-/tmp}/skarwm-xephyr-$$.log
xephyr_pid=
state_dir=${SKARWM_XEPHYR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/skarwm/xephyr}
extra_dir=$(pwd)/extra

stop_quickshell_instance() {
    if command -v qs >/dev/null 2>&1; then
        qs list --all 2>/dev/null | awk \
            -v wanted_path="$extra_dir/quickshell/shell.qml" \
            -v wanted_connection="x11/$nested_display" '
                /^Instance / {
                    pid = ""
                    config_path = ""
                    connection = ""
                }
                /^[[:space:]]+Process ID:/ { pid = $3 }
                /^[[:space:]]+Config path:/ {
                    sub(/^[^:]*:[[:space:]]*/, "")
                    config_path = $0
                }
                /^[[:space:]]+Display connection:/ {
                    sub(/^[^:]*:[[:space:]]*/, "")
                    connection = $0
                    if (pid ~ /^[0-9]+$/ && config_path == wanted_path && connection == wanted_connection)
                        print pid
                }
            ' | while IFS= read -r quickshell_pid; do
                kill -TERM "$quickshell_pid" 2>/dev/null || true
            done
    fi
}

cleanup() {
    stop_quickshell_instance
    if [ -n "$xephyr_pid" ] && kill -0 "$xephyr_pid" 2>/dev/null; then
        kill "$xephyr_pid" 2>/dev/null || true
        wait "$xephyr_pid" 2>/dev/null || true
    fi
    rm -f "$socket_path" "$log_path"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if DISPLAY="$nested_display" xwininfo -root >/dev/null 2>&1; then
    printf 'error: display %s is already in use; set SKARWM_XEPHYR_DISPLAY to another display\n' \
        "$nested_display" >&2
    exit 1
fi

printf 'Starting Xephyr on %s (%s mode)\n' "$nested_display" "$mode"
Xephyr "$nested_display" -screen 1920x1080 -ac -br -noreset >"$log_path" 2>&1 &
xephyr_pid=$!

ready=false
attempt=0
while [ "$attempt" -lt 50 ]; do
    if DISPLAY="$nested_display" xwininfo -root >/dev/null 2>&1; then
        ready=true
        break
    fi
    if ! kill -0 "$xephyr_pid" 2>/dev/null; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "$ready" != true ]; then
    printf 'error: Xephyr did not become ready; log follows:\n' >&2
    sed -n '1,80p' "$log_path" >&2
    exit 1
fi

if [ "$mode" = multi ]; then
    output=$(DISPLAY="$nested_display" xrandr --query |
        awk '$2 == "connected" { print $1; exit }')
    if [ -z "$output" ]; then
        printf 'error: Xephyr did not report a connected RandR output\n' >&2
        exit 1
    fi
    DISPLAY="$nested_display" xrandr \
        --setmonitor LEFT 960/254x1080/286+0+0 "$output"
    DISPLAY="$nested_display" xrandr \
        --setmonitor RIGHT 960/254x1080/286+960+0 none
    printf 'Created RandR monitors LEFT and RIGHT (960x1080 each)\n'
fi

printf 'Launching skarwm; close the Xephyr window or press Ctrl-C here to stop.\n'
printf 'Nested IPC socket: %s\n' "$socket_path"
printf 'Configuration: %s\n' "$config_path"
mkdir -p "$state_dir"
printf 'Persistent state: %s\n' "$state_dir"
DISPLAY="$nested_display" SKARWM_SOCKET="$socket_path" \
    SKARWM_EXTRA_DIR="$extra_dir" SKARWM_STATE_DIR="$state_dir" \
    KITTY_CONFIG_DIRECTORY="$extra_dir/kitty" \
    ./build/skarwm "$@"
