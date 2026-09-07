import QtQuick
import Quickshell

// Native session controls shared by the bar power button and Commands menu.
Popout {
    id: root

    cardWidth: 300
    cardHeight: contentColumn.implicitHeight + 2 * cardPadding

    function run(command) {
        visible = false
        Quickshell.execDetached(command)
    }

    Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 10

        Row {
            width: parent.width
            spacing: 9

            Text {
                text: "⏻"
                color: Theme.red
                font.family: Theme.fontFamily
                font.pixelSize: 18
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Power menu"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 1
                font.bold: true
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Qt.alpha(Theme.fg, 0.15)
        }

        Grid {
            width: parent.width
            columns: 2
            spacing: 7

            Repeater {
                model: [
                    { icon: "󰜉", label: "Reboot", color: Theme.brightOrange,
                      run: () => root.run(["loginctl", "reboot"]) },
                    { icon: "󰍃", label: "Logout", color: Theme.yellow,
                      run: () => root.run([Wm.msgPath, "quit"]) },
                    { icon: "󰐥", label: "Shutdown", color: Theme.red,
                      run: () => root.run(["loginctl", "poweroff"]) },
                    { icon: "󰌾", label: "Lock", color: Theme.cyan,
                      run: () => root.run(["betterlockscreen", "-l"]) },
                    { icon: "󰤄", label: "Suspend", color: Theme.magenta,
                      run: () => root.run(["loginctl", "suspend"]) },
                    { icon: "󰑓", label: "Reload skarwm", color: Theme.brightBlue,
                      run: () => root.run([Wm.msgPath, "reload"]) }
                ]

                delegate: Rectangle {
                    id: button
                    required property var modelData

                    width: (parent.width - 7) / 2
                    height: 48
                    radius: 0
                    color: buttonMouse.containsMouse
                        ? Qt.alpha(button.modelData.color, 0.22)
                        : Qt.alpha(Theme.fg, 0.05)
                    border.width: 1
                    border.color: buttonMouse.containsMouse
                        ? button.modelData.color : Theme.gray5

                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 7

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: button.modelData.icon
                            color: button.modelData.color
                            font.family: Theme.fontFamily
                            font.pixelSize: 16
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: button.modelData.label
                            color: Theme.fg
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                        }
                    }

                    MouseArea {
                        id: buttonMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: button.modelData.run()
                    }
                }
            }
        }
    }
}
