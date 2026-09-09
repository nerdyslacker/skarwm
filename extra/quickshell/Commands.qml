pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Main right-side menu: identity, focus controls, session actions, and
// commands that do not need their own bar surface.
BarModule {
    id: root

    icon: "󰀄"
    iconColor: pomoDone ? Theme.bg
        : pomoRunning ? Theme.accent : Qt.alpha(Theme.fg, 0.7)
    label: pomoRunning ? fmtPomo(pomoLeft) : pomoDone ? "0:00" : ""
    labelColor: pomoDone ? Theme.bg : Theme.fg
    color: pomoDone ? Theme.red
        : hovered ? Theme.barSurface(0.14) : Theme.barSurface(0.07)
    progress: pomoRunning ? pomoLeft / pomoTotal : -1

    property string userName: String(Quickshell.env("USER") ?? "user")
    property string displayName: userName
    property string avatarPath: ""

    property int pomoMinutes: 25
    readonly property var pomoPresets: [15, 25, 45, 60]
    readonly property int pomoTotal: pomoMinutes * 60
    property double pomoEndMs: 0
    property int pomoLeft: 0
    property bool pomoDone: false
    readonly property bool pomoRunning: pomoEndMs > 0

    onClicked: mouse => {
        if (mouse.button === Qt.RightButton) {
            menu.visible = false
            barSettings.visible = !barSettings.visible
            return
        }
        if (mouse.button !== Qt.LeftButton) return
        barSettings.visible = false
        pomoDone = false
        menu.visible = !menu.visible
    }

    function run(command) {
        menu.visible = false
        Quickshell.execDetached(command)
    }

    function restartDesktop() {
        menu.visible = false
        const script =
            "wm=$1; shell_path=$2; notification_id=991049; " +
            "if ! \"$wm\" reload >/dev/null 2>&1; then " +
            "notify-send -a skarwm -r $notification_id -u critical " +
            "-i dialog-error 'Desktop reload failed' " +
            "'skarwm rejected the configuration; Quickshell was left running.'; " +
            "exit 1; fi; " +
            "notify-send -a skarwm -r $notification_id -t 2000 " +
            "-i system-run 'Reloading desktop' " +
            "'skarwm reloaded; restarting Quickshell…'; " +
            "sleep 0.25; qs kill -n -p \"$shell_path\" >/dev/null 2>&1 || true; " +
            "sleep 0.4; " +
            "if qs --no-duplicate -d -p \"$shell_path\" >/dev/null 2>&1; then " +
            "sleep 0.8; notify-send -a skarwm -r $notification_id -t 2500 " +
            "-i dialog-information 'Desktop reloaded' " +
            "'skarwm and Quickshell restarted successfully.'; " +
            "else notify-send -a skarwm -r $notification_id -u critical " +
            "-i dialog-error 'Quickshell restart failed' " +
            "'skarwm reloaded, but Quickshell could not be started.'; fi"
        Quickshell.execDetached([
            "sh", "-c", script, "skarwm-reload", Wm.msgPath,
            Theme.configDir + "/quickshell"
        ])
    }

    function persistPomo() {
        Quickshell.execDetached(["sh", "-c",
            "printf '%s %s\\n' " + Math.round(pomoEndMs) + " " + pomoMinutes +
            " > '" + Theme.stateDir + "/pomodoro'"])
    }

    function fmtPomo(seconds) {
        return Math.floor(seconds / 60) + ":" +
            String(seconds % 60).padStart(2, "0")
    }

    function togglePomodoro() {
        pomoDone = false
        if (pomoRunning) {
            pomoEndMs = 0
        } else {
            pomoEndMs = Date.now() + pomoTotal * 1000
            pomoLeft = pomoTotal
        }
        persistPomo()
    }

    function cyclePomoPreset() {
        if (pomoRunning)
            return
        pomoMinutes = pomoPresets[(pomoPresets.indexOf(pomoMinutes) + 1)
            % pomoPresets.length]
        persistPomo()
    }

    function nudgePomo(direction) {
        if (pomoRunning)
            return
        pomoMinutes = Math.min(90, Math.max(5, pomoMinutes + direction * 5))
        persistPomo()
    }

    Process {
        running: true
        command: ["sh", "-c",
            "u=$(id -un); entry=$(getent passwd \"$u\"); " +
            "name=$(printf '%s' \"$entry\" | cut -d: -f5 | cut -d, -f1); " +
            "home=$(printf '%s' \"$entry\" | cut -d: -f6); " +
            "avatar=''; for f in \"$home/.face\" \"$home/.face.icon\" " +
            "\"/var/lib/AccountsService/icons/$u\"; do " +
            "[ -r \"$f\" ] && avatar=$f && break; done; " +
            "printf '%s\\n%s\\n%s\\n' \"$u\" \"${name:-$u}\" \"$avatar\""]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.split("\n")
                if ((lines[0] ?? "") !== "") root.userName = lines[0]
                if ((lines[1] ?? "") !== "") root.displayName = lines[1]
                root.avatarPath = lines[2] ?? ""
            }
        }
    }

    FileView {
        path: Theme.stateDir + "/pomodoro"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const parts = text().trim().split(/\s+/)
            const end = parseFloat(parts[0]) || 0
            const minutes = parseInt(parts[1]) || 0
            if (minutes >= 5 && minutes <= 90) root.pomoMinutes = minutes
            if (end > Date.now()) {
                root.pomoEndMs = end
                root.pomoLeft = Math.round((end - Date.now()) / 1000)
            } else if (end === 0) {
                root.pomoEndMs = 0
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.pomoRunning
        onTriggered: {
            root.pomoLeft = Math.max(0,
                Math.round((root.pomoEndMs - Date.now()) / 1000))
            if (root.pomoLeft <= 0) {
                root.pomoEndMs = 0
                root.pomoDone = true
                root.persistPomo()
                Quickshell.execDetached(["paplay", "--volume=40000",
                    "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"])
                Quickshell.execDetached(["notify-send", "-u", "critical",
                    "Pomodoro", "Time's up — take a break"])
            }
        }
    }

    component MenuButton: Rectangle {
        id: button
        required property var modelData
        readonly property bool active: modelData.active === true
        readonly property color accentColor: modelData.color ?? Theme.cyan

        width: (parent.width - 7) / 2
        height: 48
        color: active ? Qt.alpha(accentColor, 0.26)
            : pointer.containsMouse ? Qt.alpha(accentColor, 0.18)
            : Qt.alpha(Theme.fg, 0.05)
        border.width: 1
        border.color: active || pointer.containsMouse ? accentColor : Theme.gray5
        Behavior on color { ColorAnimation { duration: 120 } }
        Behavior on border.color { ColorAnimation { duration: 120 } }

        Row {
            anchors.centerIn: parent
            spacing: 7
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: button.modelData.icon
                color: button.accentColor
                font.family: Theme.fontFamily
                font.pixelSize: 16
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: button.modelData.label
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: button.active
            }
        }

        Rectangle {
            visible: button.modelData.progress !== undefined
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            height: 2
            width: Math.max(0, Math.min(1,
                button.modelData.progress ?? 0)) * parent.width
            color: button.accentColor
        }

        MouseArea {
            id: pointer
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton && button.modelData.altFn)
                    button.modelData.altFn()
                else if (mouse.button === Qt.LeftButton)
                    button.modelData.run()
            }
            onWheel: wheel => button.modelData.onScroll?.(
                wheel.angleDelta.y > 0 ? 1 : -1)
        }
    }

    component CommandRow: Rectangle {
        id: command
        required property var modelData

        width: parent.width
        height: 34
        color: pointer.containsMouse ? Qt.alpha(Theme.fg, 0.12) : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: command.modelData.icon
                color: Theme.cyan
                font.family: Theme.fontFamily
                font.pixelSize: 15
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: command.modelData.label
                color: Qt.alpha(Theme.fg, 0.9)
                font.family: Theme.fontFamily
                font.pixelSize: 13
            }
        }
        MouseArea {
            id: pointer
            anchors.fill: parent
            hoverEnabled: true
            onClicked: command.modelData.run()
        }
    }

    NotifyPopup {
        id: notifHistory
        anchorItem: root
    }

    BarSettingsPopup {
        id: barSettings
        anchorItem: root
    }

    Popout {
        id: menu
        anchorItem: root
        alignRight: true
        cardWidth: 330
        cardHeight: content.implicitHeight + 2 * cardPadding

        IpcHandler {
            target: "commands"
            function toggle(): void { menu.visible = !menu.visible }
        }

        Column {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 7

            Row {
                width: parent.width
                height: 52
                spacing: 11

                Rectangle {
                    width: 48
                    height: 48
                    radius: 24
                    clip: true
                    color: Theme.gray3
                    border.width: 1
                    border.color: Theme.gray5
                    Text {
                        anchors.centerIn: parent
                        text: root.displayName.slice(0, 1).toUpperCase()
                        color: Theme.accent
                        font.family: Theme.fontFamily
                        font.pixelSize: 20
                        font.bold: true
                    }
                    Image {
                        anchors.fill: parent
                        visible: status === Image.Ready
                        source: root.avatarPath
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                    }
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        text: root.displayName
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize + 1
                        font.bold: true
                    }
                    Text {
                        text: "@" + root.userName
                        color: Theme.brightBlack
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: Theme.gray5 }

            Grid {
                width: parent.width
                columns: 2
                spacing: 7
                Repeater {
                    model: [
                        { icon: Sys.dndOn ? "󰂛" : "󰂚",
                          label: "DND", color: Theme.magenta,
                          active: Sys.dndOn,
                          altFn: () => {
                              menu.visible = false
                              notifHistory.visible = true
                          },
                          run: () => Sys.toggleDnd() },
                        { icon: "󰔟", color: Theme.green,
                          label: root.pomoRunning ? root.fmtPomo(root.pomoLeft)
                              : root.pomoMinutes + " min",
                          active: root.pomoRunning,
                          progress: root.pomoRunning
                              ? root.pomoLeft / root.pomoTotal : undefined,
                          altFn: () => root.cyclePomoPreset(),
                          onScroll: direction => root.nudgePomo(direction),
                          run: () => root.togglePomodoro() }
                    ]
                    MenuButton {}
                }
            }

            Text {
                text: "Session"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }

            Grid {
                width: parent.width
                columns: 2
                spacing: 7
                Repeater {
                    model: [
                        { icon: "󰌾", label: "Lock", color: Theme.cyan,
                          run: () => root.run(["betterlockscreen", "-l"]) },
                        { icon: "󰤄", label: "Suspend", color: Theme.magenta,
                          run: () => root.run(["loginctl", "suspend"]) },
                        { icon: "󰍃", label: "Logout", color: Theme.yellow,
                          run: () => root.run([Wm.msgPath, "quit"]) },
                        { icon: "󰑓", label: "Reload desktop", color: Theme.brightBlue,
                          run: () => root.restartDesktop() },
                        { icon: "󰜉", label: "Reboot", color: Theme.brightOrange,
                          run: () => root.run(["loginctl", "reboot"]) },
                        { icon: "󰐥", label: "Shutdown", color: Theme.red,
                          run: () => root.run(["loginctl", "poweroff"]) }
                    ]
                    MenuButton {}
                }
            }

            Rectangle { width: parent.width; height: 1; color: Theme.gray5 }

            Repeater {
                model: [
                    { icon: "󰚰", label: "Check updates",
                      run: () => root.run(["sh", "-c",
                          "if command -v kitty >/dev/null 2>&1; then " +
                          "exec kitty --hold sh -c 'xbps-install -Mun'; " +
                          "else exec xterm -hold -e sh -c 'xbps-install -Mun'; fi"]) },
                    { icon: "󰌌", label: "Keybindings",
                      run: () => root.run([Wm.msgPath, "show-bindings"]) }
                ]
                CommandRow {}
            }
        }
    }
}
