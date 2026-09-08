pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// Detailed system snapshot. The inexpensive bar percentages remain in Sys;
// process and hardware details are queried only while this popup is visible.
Popout {
    id: root

    property string cpuModel: "Processor"
    property int cpuCores: 0
    property string loadAverage: "—"
    property real temperature: -1
    property double memoryTotal: 0
    property double memoryUsed: 0
    property double memoryAvailable: 0
    property double swapTotal: 0
    property double swapUsed: 0
    property double diskTotal: 0
    property double diskUsed: 0
    property double diskAvailable: 0
    property var processes: []

    cardWidth: 500
    cardHeight: 600

    onVisibleChanged: {
        if (visible)
            refresh()
    }

    function refresh() {
        if (!detailsQuery.running)
            detailsQuery.running = true
    }

    function bytes(value) {
        const units = ["B", "KiB", "MiB", "GiB", "TiB"]
        let amount = Math.max(0, Number(value) || 0)
        let unit = 0
        while (amount >= 1024 && unit < units.length - 1) {
            amount /= 1024
            unit++
        }
        const digits = amount >= 100 || unit === 0 ? 0 : amount >= 10 ? 1 : 2
        return amount.toFixed(digits) + " " + units[unit]
    }

    function percent(used, total) {
        return total > 0 ? Math.round(100 * used / total) : 0
    }

    Timer {
        interval: 2500
        repeat: true
        running: root.visible
        onTriggered: root.refresh()
    }

    Process {
        id: detailsQuery
        command: ["sh", "-c",
            "awk -F: '/^model name/{sub(/^[ \\t]+/,\"\",$2); print \"MODEL|\" $2; exit}' /proc/cpuinfo; " +
            "printf 'CORES|%s\\n' \"$(getconf _NPROCESSORS_ONLN 2>/dev/null)\"; " +
            "awk '{print \"LOAD|\" $1 \"|\" $2 \"|\" $3}' /proc/loadavg; " +
            "temp=''; for zone in /sys/class/thermal/thermal_zone*/temp; do " +
            "[ -r \"$zone\" ] || continue; temp=$(cat \"$zone\"); " +
            "[ \"${temp:-0}\" -gt 0 ] 2>/dev/null && break; done; " +
            "printf 'TEMP|%s\\n' \"$temp\"; " +
            "free -b 2>/dev/null | awk '/^Mem:/{print \"MEM|\"$2\"|\"$3\"|\"$7} /^Swap:/{print \"SWAP|\"$2\"|\"$3}'; " +
            "df -B1 --output=size,used,avail / 2>/dev/null | tail -n 1 | " +
            "awk '{print \"DISK|\"$1\"|\"$2\"|\"$3}'; " +
            "ps -eo pid=,comm=,%cpu=,%mem= --sort=-%cpu 2>/dev/null | " +
            "awk 'NR<=8 {print \"PROC|\"$1\"|\"$2\"|\"$3\"|\"$4}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                const nextProcesses = []
                for (const line of text.split("\n")) {
                    const fields = line.split("|")
                    switch (fields[0]) {
                    case "MODEL":
                        root.cpuModel = fields.slice(1).join("|") || "Processor"
                        break
                    case "CORES":
                        root.cpuCores = parseInt(fields[1]) || 0
                        break
                    case "LOAD":
                        root.loadAverage = fields.slice(1, 4).join("  ")
                        break
                    case "TEMP": {
                        const raw = Number(fields[1])
                        root.temperature = raw > 0 ? raw / 1000 : -1
                        break
                    }
                    case "MEM":
                        root.memoryTotal = Number(fields[1]) || 0
                        root.memoryUsed = Number(fields[2]) || 0
                        root.memoryAvailable = Number(fields[3]) || 0
                        break
                    case "SWAP":
                        root.swapTotal = Number(fields[1]) || 0
                        root.swapUsed = Number(fields[2]) || 0
                        break
                    case "DISK":
                        root.diskTotal = Number(fields[1]) || 0
                        root.diskUsed = Number(fields[2]) || 0
                        root.diskAvailable = Number(fields[3]) || 0
                        break
                    case "PROC":
                        nextProcesses.push({
                            pid: fields[1],
                            name: fields[2],
                            cpu: Number(fields[3]) || 0,
                            memory: Number(fields[4]) || 0
                        })
                        break
                    }
                }
                root.processes = nextProcesses
            }
        }
    }

    component UsageCard: Rectangle {
        id: card
        required property string cardIcon
        required property string title
        required property string value
        required property string detail
        required property real usage
        required property color accentColor

        width: (parent.width - 12) / 3
        height: 104
        color: Qt.alpha(Theme.fg, 0.05)
        border.width: 1
        border.color: Theme.gray5

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.top: parent.top
            anchors.topMargin: 9
            text: card.cardIcon
            color: card.accentColor
            font.family: Theme.fontFamily
            font.pixelSize: 17
        }
        Text {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.top: parent.top
            anchors.topMargin: 9
            text: card.value
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize + 1
            font.bold: true
        }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.top: parent.top
            anchors.topMargin: 37
            text: card.title
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.bold: true
        }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.top: parent.top
            anchors.topMargin: 57
            text: card.detail
            elide: Text.ElideRight
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 10
            height: 4
            color: Qt.alpha(Theme.fg, 0.12)
            Rectangle {
                width: Math.max(0, Math.min(1, card.usage / 100)) * parent.width
                height: parent.height
                color: card.accentColor
                Behavior on width { NumberAnimation { duration: 300 } }
            }
        }
    }

    Column {
        id: content
        anchors.fill: parent
        spacing: 10

        Text {
            text: "System monitor"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize + 2
            font.bold: true
        }

        Row {
            width: parent.width
            spacing: 6
            UsageCard {
                cardIcon: "󰻠"
                title: "CPU"
                value: Math.round(Sys.cpu) + "%"
                detail: (root.cpuCores > 0 ? root.cpuCores + " cores · " : "")
                    + root.cpuModel
                usage: Sys.cpu
                accentColor: Sys.cpu > 90 ? Theme.red : Theme.orange
            }
            UsageCard {
                cardIcon: "󰍛"
                title: "Memory"
                value: root.percent(root.memoryUsed, root.memoryTotal) + "%"
                detail: root.bytes(root.memoryUsed) + " / " + root.bytes(root.memoryTotal)
                usage: root.percent(root.memoryUsed, root.memoryTotal)
                accentColor: root.percent(root.memoryUsed, root.memoryTotal) > 90
                    ? Theme.red : Theme.blue
            }
            UsageCard {
                cardIcon: "󰋊"
                title: "Storage"
                value: Math.round(Sys.disk) + "%"
                detail: root.bytes(root.diskUsed) + " / " + root.bytes(root.diskTotal)
                usage: Sys.disk
                accentColor: Sys.disk > 90
                    ? Theme.red : Theme.yellow
            }
        }

        Rectangle {
            width: parent.width
            height: 55
            color: Qt.alpha(Theme.fg, 0.04)
            border.width: 1
            border.color: Theme.gray5

            Grid {
                anchors.fill: parent
                anchors.margins: 8
                columns: 2
                columnSpacing: 24
                rowSpacing: 5

                Text {
                    width: (parent.width - 24) / 2
                    text: "Load  " + root.loadAverage
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
                Text {
                    width: (parent.width - 24) / 2
                    text: "Temperature  " + (root.temperature >= 0
                        ? root.temperature.toFixed(0) + "°C" : "unavailable")
                    color: root.temperature >= 85 ? Theme.red : Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
                Text {
                    width: (parent.width - 24) / 2
                    text: "Available RAM  " + root.bytes(root.memoryAvailable)
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
                Text {
                    width: (parent.width - 24) / 2
                    text: root.swapTotal > 0
                        ? "Swap  " + root.bytes(root.swapUsed) + " / " + root.bytes(root.swapTotal)
                        : "Swap  disabled"
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
            }
        }

        Text {
            text: "Top processes"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize + 1
            font.bold: true
        }

        Rectangle {
            width: parent.width
            height: 24
            color: Theme.gray3
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 9
                anchors.verticalCenter: parent.verticalCenter
                text: "PROCESS"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
            Text {
                anchors.right: cpuHeader.left
                anchors.rightMargin: 28
                anchors.verticalCenter: parent.verticalCenter
                text: "PID"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
            Text {
                id: cpuHeader
                width: 55
                anchors.right: memoryHeader.left
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: "CPU"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
            Text {
                id: memoryHeader
                width: 58
                anchors.right: parent.right
                anchors.rightMargin: 9
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: "MEM"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }

        Repeater {
            model: root.processes

            Rectangle {
                id: processRow
                required property var modelData
                required property int index
                width: content.width
                height: 29
                color: index % 2 === 0 ? Qt.alpha(Theme.fg, 0.035) : "transparent"

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 9
                    anchors.right: pidText.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: processRow.modelData.name
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
                Text {
                    id: pidText
                    width: 58
                    anchors.right: cpuText.left
                    anchors.rightMargin: 18
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: processRow.modelData.pid
                    color: Theme.brightBlack
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
                Text {
                    id: cpuText
                    width: 55
                    anchors.right: memoryText.left
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: processRow.modelData.cpu.toFixed(1) + "%"
                    color: processRow.modelData.cpu >= 50 ? Theme.red : Theme.orange
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
                Text {
                    id: memoryText
                    width: 58
                    anchors.right: parent.right
                    anchors.rightMargin: 9
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: processRow.modelData.memory.toFixed(1) + "%"
                    color: Theme.blue
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
            }
        }

        Text {
            visible: root.processes.length === 0
            text: "Process information is unavailable."
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
    }
}
