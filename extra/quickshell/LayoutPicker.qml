pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// Layout and appearance controls adapted to skarwm. Layout selection applies
// to the focused window/column; desktop gap and all visual choices persist.
Popout {
    id: root

    readonly property var accents: [
        { key: "orange", label: "Orange" },
        { key: "red", label: "Red" },
        { key: "green", label: "Green" },
        { key: "yellow", label: "Yellow" },
        { key: "blue", label: "Blue" },
        { key: "magenta", label: "Magenta" },
        { key: "cyan", label: "Cyan" },
        { key: "brightOrange", label: "Bright orange" },
        { key: "brightRed", label: "Bright red" },
        { key: "brightGreen", label: "Bright green" },
        { key: "brightYellow", label: "Bright yellow" },
        { key: "brightBlue", label: "Bright blue" },
        { key: "brightMagenta", label: "Bright magenta" },
        { key: "brightCyan", label: "Bright cyan" }
    ]

    cardWidth: 360
    cardHeight: content.implicitHeight + 2 * cardPadding

    IpcHandler {
        target: "layouts"
        function toggle(): void { root.visible = !root.visible }
    }

    component SectionLabel: Text {
        color: Theme.accent
        font.family: Theme.fontFamily
        font.pixelSize: 12
        font.bold: true
        topPadding: 5
    }

    Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 7

        SectionLabel { text: "Focused layout" }

        Grid {
            id: layoutGrid
            width: parent.width
            columns: 3
            spacing: 5

            Repeater {
                model: Wm.layouts

                Rectangle {
                    id: layoutTile
                    required property var modelData
                    required property int index
                    readonly property bool current: Wm.layoutIndex === index

                    width: (layoutGrid.width - 10) / 3
                    height: 52
                    color: current ? Theme.selbg
                        : layoutMouse.containsMouse ? Qt.alpha(Theme.fg, 0.12)
                        : Qt.alpha(Theme.fg, 0.05)
                    border.width: 1
                    border.color: current ? Theme.accent : Theme.gray5
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Column {
                        anchors.centerIn: parent
                        spacing: 2
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: layoutTile.modelData.glyph
                            color: layoutTile.current ? Theme.selfg : Theme.cyan
                            font.family: Theme.fontFamily
                            font.pixelSize: 18
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: layoutTile.modelData.name
                            color: layoutTile.current ? Theme.selfg : Theme.fg
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            font.bold: layoutTile.current
                        }
                    }

                    MouseArea {
                        id: layoutMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: Wm.setLayout(layoutTile.index)
                    }
                }
            }
        }

        SectionLabel { text: "Desktop" }

        TweakSlider {
            label: "window gap"
            from: 0
            to: 40
            value: Wm.gaps
            suffix: " px"
            applyFn: value => Wm.setGaps(value, false)
            persistFn: value => Wm.persistGaps(value)
        }

        SectionLabel { text: "Accent color" }

        Grid {
            id: accentGrid
            width: parent.width
            columns: 4
            spacing: 4

            Repeater {
                model: root.accents

                Rectangle {
                    id: swatch
                    required property var modelData
                    readonly property bool current:
                        Theme.accentName === modelData.key
                    readonly property color swatchColor:
                        Theme.accentColor(modelData.key)

                    width: (accentGrid.width - 12) / 4
                    height: 31
                    color: swatchMouse.containsMouse
                        ? Qt.alpha(swatch.swatchColor, 0.22)
                        : Qt.alpha(Theme.fg, 0.04)
                    border.width: swatch.current ? 2 : 1
                    border.color: swatch.current
                        ? swatch.swatchColor : Theme.gray5

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 7
                        anchors.right: parent.right
                        anchors.rightMargin: 5
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 11
                            height: 11
                            color: swatch.swatchColor
                            border.width: 1
                            border.color: Qt.alpha(Theme.fg, 0.35)
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 17
                            text: swatch.modelData.label
                            elide: Text.ElideRight
                            color: swatch.current ? swatch.swatchColor : Theme.fg
                            font.family: Theme.fontFamily
                            font.pixelSize: 9
                            font.bold: swatch.current
                        }
                    }

                    MouseArea {
                        id: swatchMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: Theme.setAccent(swatch.modelData.key)
                    }
                }
            }
        }
    }
}
