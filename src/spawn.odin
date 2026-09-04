package main

// Child-process launching + terminal detection.
//
// Everything skarwm spawns goes through `/bin/sh -c`, so bindings and the rc
// config can use ordinary shell syntax ("kitty", "foot &", "notify-send …").
//
// Process handling uses core's posix package. A double fork is used:
// the middle child exits at once and the running grandchild is reparented to
// init(1), which reaps it — so the WM never needs SIGCHLD handling and never
// accumulates zombies. The grandchild becomes a session leader with stdio on
// /dev/null, so closing the terminal that launched the WM cannot signal it and
// stray output cannot corrupt the WM's own tty.

import "core:os"
import "core:strings"
import "core:sys/posix"

// Scratch space for the child command line. Copying into a fixed buffer avoids a
// heap allocation that would need to outlive this frame in the child; a fork()
// child sees the exact contents as of the fork, so this is safe even though the
// parent overwrites the buffer on the next spawn.
sh_buf: [1024]byte

spawn_sh :: proc(cmdline: string) {
    if len(cmdline) == 0 || len(cmdline) >= len(sh_buf) {
        log_warn("ignoring spawn (empty or too long)")
        return
    }
    copy(sh_buf[:len(cmdline)], cmdline)
    sh_buf[len(cmdline)] = 0

    pid := posix.fork()
    if pid < 0 {
        log_error("fork failed:", posix.errno())
        return
    }
    if pid == 0 {
        g := posix.fork()
        if g == 0 {
            child_exec_sh()
        }
        posix._exit(0)
    }
    // reap the short-lived middle child; the running child is now init's problem
    posix.waitpid(pid, nil, {})
}

child_exec_sh :: proc() {
    posix.setsid()

    // detach from the WM's tty/stdio
    devnull := posix.open("/dev/null", {.RDWR})
    if devnull >= 0 {
        posix.dup2(devnull, 0)
        posix.dup2(devnull, 1)
        posix.dup2(devnull, 2)
        if devnull > 2 { posix.close(devnull) }
    }

    cmd := cstring(&sh_buf[0])
    argv := [4]cstring{"/bin/sh", "-c", cmd, nil}
    posix.execv("/bin/sh", &argv[0])
    posix._exit(127) // only reached if exec failed
}

// ---------------------------------------------------------------------------
// terminal detection
// ---------------------------------------------------------------------------

// detect_terminal honours $TERMINAL, else the first known emulator on PATH.
// Returns "" when nothing is found (Super+Return then no-ops with a warning).
// The returned string may be owned (env value) or a static literal; the caller
// treats it as a read-only, process-lifetime value (never freed).
detect_terminal :: proc() -> string {
    buf: [512]u8
    env := os.get_env_buf(buf[:], "TERMINAL")
    if env != "" {
        return strings.clone(env) // owned copy out of the stack buffer
    }
    for cand in TERMINAL_CANDIDATES {
        if prog_exists(cand) {
            return cand
        }
    }
    return ""
}

TERMINAL_CANDIDATES := []string{"kitty", "foot", "alacritty", "xfce4-terminal", "xterm", "urxvt", "st"}

prog_exists :: proc(name: string) -> bool {
    dirs := []string{"/usr/local/bin", "/usr/bin", "/bin"}
    for dir in dirs {
        p := strings.concatenate({dir, "/", name})
        found := os.exists(p)
        delete(p)
        if found { return true }
    }
    return false
}
