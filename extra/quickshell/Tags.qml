import QtQuick

Item {
    implicitWidth: row.implicitWidth
    implicitHeight: Theme.moduleHeight

    WheelHandler {
        onWheel: event => Wm.cycleTag(event.angleDelta.y > 0 ? -1 : 1)
    }

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        Repeater {
            model: Wm.tagCount
            Rectangle {
                id: tag
                required property int index
                readonly property bool selected: Wm.isSelected(index)
                readonly property bool occupied: Wm.isOccupied(index)
                readonly property bool urgent: Wm.isUrgent(index)
                width: selected ? 30 : 24
                height: Theme.moduleHeight
                radius: 0
                color: urgent ? Theme.red
                    : selected ? Theme.orange
                    : Qt.alpha(Theme.fg, 0.07)
                border.width: 1
                border.color: urgent ? Theme.red
                    : selected ? Theme.brightOrange
                    : occupied ? Theme.brightBlack
                    : Theme.gray5

                Behavior on width { NumberAnimation { duration: 160 } }
                Behavior on color { ColorAnimation { duration: 160 } }

                Text {
                    anchors.centerIn: parent
                    text: tag.index + 1
                    color: tag.selected ? Theme.hardBlack : Theme.brightWhite
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    font.bold: tag.selected
                }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.MiddleButton) Wm.sendToTag(tag.index)
                        else Wm.viewTag(tag.index)
                    }
                }
            }
        }
    }
}
