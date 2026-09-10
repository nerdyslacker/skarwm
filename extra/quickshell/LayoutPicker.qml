pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// Layout and appearance controls adapted to skarwm. Layout selection applies
// to the focused window/column; desktop gap and all visual choices persist.
Popout {
    id: root

    readonly property var accents: [
        "orange", "red", "green", "yellow", "blue", "magenta", "cyan",
        "brightOrange", "brightRed", "brightGreen", "brightYellow",
        "brightBlue", "brightMagenta", "brightCyan"
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
            columns: 7
            spacing: 4

            Repeater {
                model: root.accents

                Rectangle {
                    id: swatch
                    required property string modelData
                    readonly property bool current:
                        Theme.accentName === modelData
                    readonly property color swatchColor:
                        Theme.accentColor(modelData)

                    width: (accentGrid.width - accentGrid.spacing * 6) / 7
                    height: 31
                    color: swatchMouse.containsMouse
                        ? Theme.gray3 : Theme.gray2
                    border.width: swatch.current ? 2 : 1
                    border.color: swatch.current
                        ? swatch.swatchColor : Theme.gray5

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: swatch.current ? 5 : 6
                        color: swatch.swatchColor
                        border.width: 1
                        border.color: Qt.alpha(Theme.fg, 0.35)
                    }

                    MouseArea {
                        id: swatchMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: Theme.setAccent(swatch.modelData)
                    }
                }
            }
        }
    }
}
