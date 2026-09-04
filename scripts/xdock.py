#!/usr/bin/env python3
# xdock.py — fabricate an EWMH dock (panel) window for the integration tests.
#
# xdotool cannot *create* windows, and every real panel (Quickshell etc.) maps
# itself before the WM adopts it, so this script stands in for a status bar:
# it creates a plain (non-override-redirect) 1280xN window carrying WM_CLASS
# "XDock", _NET_WM_WINDOW_TYPE_DOCK, _NET_WM_DESKTOP 0xffffffff and a full
# 12-value _NET_WM_STRUT_PARTIAL, maps it, and then stays alive as a keeper
# that mutates the dock on commands read from a FIFO:
#
#     strut-top N   change _NET_WM_STRUT_PARTIAL's top edge to N (live reflow)
#     map / unmap   remap / withdraw the dock (WM releases the strut on unmap)
#     quit          destroy the window and exit
#
# usage:
#     python3 scripts/xdock.py --ctl FIFO --id-file FILE new --top N
#
# Prints the hex window id to --id-file once the window exists. Exits when the
# FIFO closes or on "quit". It is a test harness, not a skarwm feature, and
# needs python-xlib, so it lives outside the build.

import argparse
import sys
import time

from Xlib import X, display
from Xlib.protocol import event

CLS = ("xdock", "XDock")

# 12 CARDINAL: left, right, top, bottom, then the begin/end range pairs that
# EWMH says panels should fill in (skarwm reserves the containing monitor edge).
def strut_partial(top, width):
    return [0, 0, top, 0, 0, 0, 0, 0, 0, width, 0, 0]


class Dock:
    def __init__(self, dpy, x, y, w, h):
        self.dpy = dpy
        self.win = dpy.screen().root.create_window(
            x, y, w, h, 0, dpy.screen().root_depth,
            X.InputOutput, X.CopyFromParent,
            event_mask=X.StructureNotifyMask,
        )
        self.win.set_wm_class(CLS[0], CLS[1])

    def declare(self, width):
        def atom(name):
            return self.dpy.intern_atom(name)

        win = self.win
        win.change_property(atom("_NET_WM_WINDOW_TYPE"), atom("ATOM"), 32,
                            [atom("_NET_WM_WINDOW_TYPE_DOCK")])
        # No _NET_WM_DESKTOP on purpose: skarwm never writes one for a dock
        # (Ws == nil), and the test asserts the property stays absent.
        self.set_strut_top(0, width)

    def set_strut_top(self, top, width):
        dpy, win = self.dpy, self.win
        win.change_property(dpy.intern_atom("_NET_WM_STRUT_PARTIAL"),
                            dpy.intern_atom("CARDINAL"), 32,
                            strut_partial(top, width))

    def map(self):
        self.win.map()
        self.dpy.flush()

    def unmap(self):
        self.win.unmap()
        self.dpy.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ctl", required=True,
                    help="FIFO to read commands from (writer end held by the test)")
    ap.add_argument("--id-file", required=True,
                    help="file to write the hex window id to once created")
    ap.add_argument("--x", type=int, default=0)
    ap.add_argument("--y", type=int, default=0)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("sub", choices=["new"])
    ap.add_argument("--top", type=int, default=24, metavar="N",
                    help="initial top strut (and window height): N px")
    args = ap.parse_args()

    dpy = display.Display()
    dock = Dock(dpy, args.x, args.y, args.width, args.top)
    dock.declare(args.width)
    dock.set_strut_top(args.top, args.width)
    dock.map()
    try:
        with open(args.id_file, "w") as f:
            f.write(hex(dock.win.id))
    except OSError:
        pass

    # Keeper loop: mutate the dock on FIFO commands until the writer end goes
    # away ("quit" or test teardown) — then exit; the server destroys the
    # window and the WM releases the strut on the resulting DestroyNotify.
    with open(args.ctl, "r") as ctl:
        for line in ctl:
            cmd = line.strip().split()
            if not cmd:
                continue
            try:
                if cmd[0] == "strut-top" and len(cmd) == 2:
                    dock.set_strut_top(int(cmd[1]), args.width)
                    dpy.flush()
                elif cmd[0] == "map":
                    dock.map()
                elif cmd[0] == "unmap":
                    dock.unmap()
                elif cmd[0] == "quit":
                    break
            except Exception as exc:  # window already gone: stop quietly
                sys.stderr.write("xdock: %s: %s\n" % (cmd[0], exc))
                break


if __name__ == "__main__":
    main()
