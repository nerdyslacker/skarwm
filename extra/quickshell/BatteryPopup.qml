import QtQuick
import Quickshell
import Quickshell.Io

// Power profile, display blanking, and night colour controls live with the
// battery instead of in the general command menu.
Popout {
    id: root

    property string profile: "balanced"
    property bool caffeine: false
    property bool nightLight: false
    readonly property var profileOrder: ["performance", "balanced", "power-saver"]
    readonly property var profileIcons: ({
        performance: "󰃅",
        balanced: "󰾅",
        "power-saver": "󰾆"
    })

    cardWidth: 300
    cardHeight: content.implicitHeight + 2 * cardPadding
    onVisibleChanged: if (visible) stateQuery.running = true

    function cycleProfile() {
        const at = profileOrder.indexOf(profile)
        const next = profileOrder[(Math.max(0, at) + 1) % profileOrder.length]
        profile = next
        Quickshell.execDetached(["powerprofilesctl", "set", next])
    }

    function setCaffeine(enabled) {
        caffeine = enabled
        Quickshell.execDetached(["sh", "-c",
            enabled ? "xset s off -dpms" : "xset s on +dpms"])
    }

    function setNightLight(enabled) {
        nightLight = enabled
        Quickshell.execDetached(["sh", "-c",
            enabled
                ? "redshift -P -O 4500; printf '1\\n' > '" + Theme.stateDir + "/night-light'"
                : "redshift -x; printf '0\\n' > '" + Theme.stateDir + "/night-light'"])
    }

    Process {
        id: stateQuery
        command: ["sh", "-c",
            "printf '%s\\n' \"$(powerprofilesctl get 2>/dev/null)\" " +
            "\"$(xset q 2>/dev/null | awk '/timeout:/{print $2}')\"; " +
            "if [ -r '" + Theme.stateDir + "/night-light' ]; then " +
            "cat '" + Theme.stateDir + "/night-light'; else printf '0\\n'; fi"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.split("\n")
                if (root.profileOrder.indexOf(lines[0]) >= 0)
                    root.profile = lines[0]
                if (lines[1] === "0" || Number(lines[1]) > 0)
                    root.caffeine = lines[1] === "0"
                root.nightLight = lines[2] === "1"
            }
        }
    }

    component SettingButton: Rectangle {
        id: button
        required property string buttonIcon
        required property string title
        required property string detail
        required property bool active
        signal activated()

        width: parent.width
        height: 48
        color: active ? Theme.selbg
            : pointer.containsMouse ? Qt.alpha(Theme.fg, 0.12)
            : Qt.alpha(Theme.fg, 0.05)
        border.width: 1
        border.color: active ? Theme.accent : Theme.gray5
        Behavior on color { ColorAnimation { duration: 120 } }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 11
            anchors.verticalCenter: parent.verticalCenter
            text: button.buttonIcon
            color: button.active ? Theme.selfg : Theme.cyan
            font.family: Theme.fontFamily
            font.pixelSize: 17
        }
        Column {
            anchors.left: parent.left
            anchors.leftMargin: 42
            anchors.right: parent.right
            anchors.rightMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text {
                text: button.title
                color: button.active ? Theme.selfg : Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
            }
            Text {
                text: button.detail
                color: button.active ? Qt.alpha(Theme.selfg, 0.75) : Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }
        MouseArea {
            id: pointer
            anchors.fill: parent
            hoverEnabled: true
            onClicked: button.activated()
        }
    }

    Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 7

        Text {
            text: Sys.batteryCharging ? "Battery · charging" : "Battery"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize + 1
            font.bold: true
        }
        Text {
            text: Math.round(Sys.battery) + "% remaining"
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        Rectangle { width: parent.width; height: 1; color: Theme.gray5 }

        SettingButton {
            buttonIcon: root.profileIcons[root.profile] ?? "󰾅"
            title: "Power profile"
            detail: root.profile
            active: root.profile !== "balanced"
            onActivated: root.cycleProfile()
        }
        SettingButton {
            buttonIcon: "󰅶"
            title: "Keep awake"
            detail: root.caffeine ? "Screen blanking disabled" : "Screen blanking enabled"
            active: root.caffeine
            onActivated: root.setCaffeine(!root.caffeine)
        }
        SettingButton {
            buttonIcon: "󱩌"
            title: "Night mode"
            detail: root.nightLight ? "4500 K" : "Off"
            active: root.nightLight
            onActivated: root.setNightLight(!root.nightLight)
        }
    }
}
