pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// One IPC endpoint fans the request out to the launcher attached to each bar.
// Each instance then checks whether its screen is the focused skarwm output.
Singleton {
    id: root

    signal centeredRequested()

    IpcHandler {
        target: "launcher"
        function toggle(): void { root.centeredRequested() }
        function show(): void { root.centeredRequested() }
        function toggleCentered(): void { root.centeredRequested() }
    }
}
