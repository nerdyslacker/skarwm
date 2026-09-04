import QtQuick
import Quickshell
import Quickshell.Io

// Pending Void Linux updates, polled hourly. Middle click checks now;
// another click opens the system upgrade in a terminal.
BarModule {
    id: root

    property int count: 0
    visible: count > 0
    icon: "󰚰"
    iconColor: Theme.accent
    label: String(count)

    Process {
        id: checkProc
        command: ["sh", "-c",
            "xbps-install -Mun 2>/dev/null | sed '/^$/d' | wc -l"]
        stdout: StdioCollector {
            onStreamFinished: root.count = parseInt(text.trim()) || 0
        }
    }

    Timer {
        interval: 3600 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: checkProc.running = true
    }

    // the upgrade runs in a detached terminal — recheck a few minutes
    // after it was opened so the pill clears without waiting out the hour
    Timer {
        id: recheck
        interval: 5 * 60 * 1000
        onTriggered: checkProc.running = true
    }

    onClicked: mouse => {
        if (mouse.button === Qt.MiddleButton) {
            checkProc.running = true
        } else {
            Quickshell.execDetached(["xterm", "-e", "sh", "-c",
                "sudo xbps-install -Su; " +
                "printf '\\ndone - press enter to close '; read _"])
            recheck.restart()
        }
    }
}
