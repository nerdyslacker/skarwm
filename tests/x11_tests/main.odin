package main

import x11 "../../src/x11"
import "core:fmt"
import "core:os"
import "core:sys/posix"

// Runs against the integration harness's private X server. The probe window
// never receives _NET_WM_PID, so only the X-Resource record can name its owner.
main :: proc() {
    conn := x11.xcb_connect(nil, nil)
    if conn == nil || x11.xcb_connection_has_error(conn) != 0 {
        fmt.eprintln("x11: cannot connect; run through scripts/itest.sh")
        os.exit(1)
    }
    defer x11.xcb_disconnect(conn)
    root := x11.xcb_setup_roots_iterator(x11.xcb_get_setup(conn)).data.root
    window := x11.xcb_generate_id(conn)
    cookie := x11.xcb_create_window_checked(
        conn, 0, window, root, 0, 0, 1, 1, 0,
        x11.WINDOW_CLASS_INPUT_OUTPUT, 0, 0, nil,
    )
    if err := x11.xcb_request_check(conn, cookie); err != nil {
        x11.free_libc(err)
        fmt.eprintln("x11: cannot create probe window")
        os.exit(1)
    }
    defer x11.xcb_destroy_window(conn, window)

    expected := u32(posix.getpid())
    pid, ok := x11.client_pid(conn, window)
    if !ok || pid != expected {
        fmt.eprintf("x11: client_pid returned %d (ok %v), want own pid %d\n", pid, ok, expected)
        os.exit(1)
    }
    fmt.printf("x11: client_pid resolves the owning process without _NET_WM_PID (pid %d)\n", pid)
}
