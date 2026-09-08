pragma ComponentBehavior: Bound

import QtQuick

Popout {
    id: root

    cardWidth: 330
    cardHeight: KeyboardState.switcherAvailable
        ? 44 + KeyboardState.layouts.length * 38 : 100

    Column {
        anchors.fill: parent
        spacing: 6

        Text {
            text: "Keyboard layout"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize + 1
            font.bold: true
        }

        Text {
            visible: !KeyboardState.switcherAvailable
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Install xkb-switch to read and change the active layout."
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }

        Repeater {
            model: KeyboardState.switcherAvailable ? KeyboardState.layouts : []

            Rectangle {
                required property string modelData
                required property int index

                width: parent.width
                height: 32
                readonly property bool active: KeyboardState.currentSpec === KeyboardState.groupSpec(index)
                    || (KeyboardState.currentLayout === modelData
                        && KeyboardState.currentSpec.indexOf("(") === -1)
                color: active ? Theme.accent
                    : (layoutMouse.containsMouse ? Theme.gray3 : Theme.gray2)
                border.width: 1
                border.color: active ? Theme.brightOrange : Theme.gray5

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.right: codeText.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: KeyboardState.layoutName(parent.modelData)
                        + ((KeyboardState.variants[parent.index] ?? "") !== ""
                            ? " (" + KeyboardState.variants[parent.index] + ")" : "")
                    elide: Text.ElideRight
                    color: parent.active ? Theme.selfg : Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: parent.active
                }

                Text {
                    id: codeText
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: parent.modelData.toUpperCase()
                    color: parent.active ? Theme.selfg : Theme.brightBlack
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }

                MouseArea {
                    id: layoutMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        KeyboardState.switchTo(parent.index)
                        root.visible = false
                    }
                }
            }
        }
    }
}
