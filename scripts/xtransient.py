#!/usr/bin/env python3
"""Create a managed X11 dialog/transient window for integration tests."""

import argparse
import signal
import time

from Xlib import X, display


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--id-file", required=True)
    parser.add_argument("--parent", type=lambda value: int(value, 0), default=0)
    parser.add_argument("--dialog-type", action="store_true")
    parser.add_argument("--modal", action="store_true")
    args = parser.parse_args()

    dpy = display.Display()
    root = dpy.screen().root
    win = root.create_window(
        40, 50, 420, 280, 0, dpy.screen().root_depth,
        X.InputOutput, X.CopyFromParent,
        background_pixel=dpy.screen().white_pixel,
        event_mask=X.StructureNotifyMask,
    )
    win.set_wm_name("skarwm portal dialog fixture")
    win.set_wm_class("portal-dialog-fixture", "PortalDialogFixture")
    if args.parent:
        win.change_property(dpy.intern_atom("WM_TRANSIENT_FOR"),
                            dpy.intern_atom("WINDOW"), 32, [args.parent])
    if args.dialog_type:
        win.change_property(dpy.intern_atom("_NET_WM_WINDOW_TYPE"),
                            dpy.intern_atom("ATOM"), 32,
                            [dpy.intern_atom("_NET_WM_WINDOW_TYPE_DIALOG")])
    if args.modal:
        win.change_property(dpy.intern_atom("_NET_WM_STATE"),
                            dpy.intern_atom("ATOM"), 32,
                            [dpy.intern_atom("_NET_WM_STATE_MODAL")])
    win.map()
    dpy.flush()

    with open(args.id_file, "w", encoding="utf-8") as output:
        output.write(hex(win.id))

    running = True

    def stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while running:
        time.sleep(0.1)

    win.destroy()
    dpy.flush()


if __name__ == "__main__":
    main()
