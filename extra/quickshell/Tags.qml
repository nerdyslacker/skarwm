pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root
    readonly property int visibleTagCount: TagConfig.dynamicWorkspaces
        ? Wm.dynamicTagCount : Math.max(TagConfig.count, Wm.tagCount)

    implicitWidth: BarVisibility.verticalBar ? Theme.moduleHeight : tagGrid.implicitWidth
    implicitHeight: BarVisibility.verticalBar ? tagGrid.implicitHeight : Theme.moduleHeight

    WheelHandler {
        onWheel: event => Wm.cycleTag(event.angleDelta.y > 0 ? -1 : 1)
    }

    Grid {
        id: tagGrid
        anchors.centerIn: parent
        columns: BarVisibility.verticalBar ? 1
            : root.visibleTagCount
        spacing: 4

        Repeater {
            model: root.visibleTagCount
            Rectangle {
                id: tag
                required property int index
                readonly property bool selected: Wm.isSelected(index)
                readonly property bool occupied: Wm.isOccupied(index)
                readonly property bool urgent: Wm.isUrgent(index)
                width: BarVisibility.verticalBar ? Theme.moduleHeight
                    : selected ? 30 : 24
                height: Theme.moduleHeight
                radius: 0
                color: urgent ? Theme.red
                    : selected ? Theme.accent
                    : Theme.barSurface(occupied ? 0.12 : 0.07)
                border.width: 1
                border.color: urgent ? Theme.red
                    : selected ? Theme.accent
                    : Theme.gray5

                Behavior on width { NumberAnimation { duration: 160 } }
                Behavior on color { ColorAnimation { duration: 160 } }

                Text {
                    anchors.centerIn: parent
                    visible: TagConfig.showNumbers
                    text: tag.index + 1
                    color: tag.selected ? Theme.hardBlack : Theme.brightWhite
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    font.bold: tag.selected
                }

                Rectangle {
                    visible: !TagConfig.showNumbers
                    anchors.centerIn: parent
                    width: tag.selected || tag.urgent ? 5 : 4
                    height: width
                    radius: width / 2
                    color: tag.selected || tag.urgent
                        ? Theme.hardBlack
                        : Qt.alpha(Theme.fg, tag.occupied ? 0.55 : 0.28)
                }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) {
                            settings.visible = !settings.visible
                        } else if (mouse.button === Qt.MiddleButton) {
                            Wm.sendToTag(tag.index)
                        } else {
                            Wm.viewTag(tag.index)
                        }
                    }
                }
            }
        }
    }

    TagSettingsPopup {
        id: settings
        anchorItem: root
    }
}
