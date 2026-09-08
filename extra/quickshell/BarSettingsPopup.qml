pragma ComponentBehavior: Bound

import QtQuick

Popout {
    id: root

    readonly property var widgetModel: [
        { key: "launcher", label: "Launcher", icon: "󰀻" },
        { key: "tags", label: "Tags", icon: "󰓹" },
        { key: "title", label: "Window title", icon: "󰖯" },
        { key: "media", label: "Media", icon: "󰎈" },
        { key: "weather", label: "Weather", icon: "󰖐" },
        { key: "metrics", label: "System metrics", icon: "󰍛" },
        { key: "battery", label: "Battery", icon: "󰁹" },
        { key: "brightness", label: "Brightness", icon: "󰃠" },
        { key: "volume", label: "Audio", icon: "󰕾" },
        { key: "micIndicator", label: "Muted mic", icon: "󰍭" },
        { key: "network", label: "Network", icon: "󰤨" },
        { key: "keyboard", label: "Keyboard", icon: "󰌌" },
        { key: "clipboard", label: "Clipboard", icon: "󰅌" },
        { key: "tray", label: "System tray", icon: "󰔚" },
        { key: "notifications", label: "DND indicator", icon: "󰂛" },
        { key: "clock", label: "Clock", icon: "󰥔" },
        { key: "capsLock", label: "Caps Lock", icon: "󰘲" },
        { key: "screenshot", label: "Screenshot", icon: "󰻛" }
    ]

    cardWidth: 430
    cardHeight: content.implicitHeight + 2 * cardPadding
    alignRight: true

    Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 9

        Text {
            text: "Bar widgets"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize + 1
            font.bold: true
        }

        Text {
            text: "Choose which widgets appear on the bar"
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }

        Grid {
            width: parent.width
            columns: 2
            spacing: 6

            Repeater {
                model: root.widgetModel

                Rectangle {
                    id: widgetRow
                    required property var modelData
                    readonly property bool isEnabled: BarVisibility.enabled(modelData.key)

                    width: (parent.width - 6) / 2
                    height: 36
                    color: rowMouse.containsMouse
                        ? Qt.alpha(Theme.fg, 0.08) : "transparent"

                    Text {
                        id: widgetIcon
                        anchors.left: parent.left
                        anchors.leftMargin: 7
                        anchors.verticalCenter: parent.verticalCenter
                        text: widgetRow.modelData.icon
                        color: widgetRow.isEnabled ? Theme.cyan : Theme.brightBlack
                        font.family: Theme.fontFamily
                        font.pixelSize: 15
                    }

                    Text {
                        anchors.left: widgetIcon.right
                        anchors.leftMargin: 7
                        anchors.right: widgetSwitch.left
                        anchors.rightMargin: 7
                        anchors.verticalCenter: parent.verticalCenter
                        text: widgetRow.modelData.label
                        elide: Text.ElideRight
                        color: widgetRow.isEnabled ? Theme.fg : Theme.brightBlack
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }

                    Rectangle {
                        id: widgetSwitch
                        anchors.right: parent.right
                        anchors.rightMargin: 7
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34
                        height: 18
                        color: widgetRow.isEnabled
                            ? Theme.accent : Qt.alpha(Theme.fg, 0.15)
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: widgetRow.isEnabled ? parent.width - width - 2 : 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14
                            height: 14
                            color: widgetRow.isEnabled
                                ? Theme.bg : Qt.alpha(Theme.fg, 0.7)
                            Behavior on x {
                                NumberAnimation {
                                    duration: 150
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: BarVisibility.setEnabled(
                            widgetRow.modelData.key, !widgetRow.isEnabled)
                    }
                }
            }
        }
    }
}
