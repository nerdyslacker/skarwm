package main

// The executable only starts the stateful WM runtime. Pure layout and policy
// live in core/; X11 integration and orchestration live in wm/.

import "wm"

main :: proc() {
    wm.Run()
}
