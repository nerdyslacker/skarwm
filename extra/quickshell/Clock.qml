import QtQuick
import Quickshell
import Quickshell.Io

// Date + 12-hour time, with the calendar popup on left click and renCal on
// right click when it is installed.
BarModule {
    id: root

    property bool hasRenCal: false

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    label: Qt.formatDateTime(clock.date, "ddd MMM d") + "  " + Qt.formatDateTime(clock.date, "h:mm AP")

    onClicked: mouse => {
        if (mouse.button === Qt.RightButton && hasRenCal)
            Quickshell.execDetached(["rencal"])
        else
            calendar.visible = !calendar.visible
    }

    Process {
        command: ["sh", "-c", "command -v rencal 2>/dev/null"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root.hasRenCal = text.trim() !== ""
        }
    }

    CalendarPopup {
        id: calendar
        anchorItem: root
    }
}
