pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.SystemTray

// All tray items remain available here, including those removed from the bar.
// The trailing button controls persistent bar/overflow placement.
Popout {
    id: root

    readonly property int rowHeight: Math.round(38 * Theme.barScale)
    readonly property real chromeHeight: heading.implicitHeight
        + divider.height + content.spacing * 3
        + 2 * cardPadding
    cardWidth: 340
    cardHeight: Math.min(320, chromeHeight + list.contentHeight)

    Column {
        id: content
        anchors.fill: parent
        spacing: 8

        Row {
            id: heading
            width: parent.width
            spacing: 8

            Text {
                text: "󰔚"
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: 18
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "System tray"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 1
                font.bold: true
            }
        }

        Rectangle {
            id: divider
            width: parent.width
            height: 1
            color: Qt.alpha(Theme.fg, 0.15)
        }

        ListView {
            id: list
            width: parent.width
            height: Math.max(0, root.cardHeight - root.chromeHeight)
            clip: true
            spacing: 4
            model: SystemTray.items.values

            Controls.ScrollBar.vertical: Controls.ScrollBar {
                id: trayScroll
                width: 8
                policy: list.contentHeight > list.height + 0.5
                    ? Controls.ScrollBar.AlwaysOn
                    : Controls.ScrollBar.AlwaysOff
                interactive: true
                background: Rectangle {
                    color: Theme.gray2
                    border.width: 1
                    border.color: Theme.gray5
                }
                contentItem: Rectangle {
                    implicitWidth: 6
                    implicitHeight: 28
                    color: trayScroll.pressed ? Theme.brightOrange
                        : trayScroll.hovered ? Theme.orange : Theme.gray6
                }
            }

            delegate: Rectangle {
                id: entry
                required property SystemTrayItem modelData
                readonly property bool hidden: TrayState.isHidden(modelData)

                width: list.width
                height: root.rowHeight
                color: entryMouse.containsMouse ? Theme.gray3 : Theme.gray2
                border.width: 1
                border.color: Theme.gray5

                IconImage {
                    id: itemIcon
                    anchors.left: parent.left
                    anchors.leftMargin: 9
                    anchors.verticalCenter: parent.verticalCenter
                    implicitSize: Math.round(18 * Theme.barScale)
                    source: entry.modelData.icon
                }

                Column {
                    anchors.left: itemIcon.right
                    anchors.leftMargin: 9
                    anchors.right: placementButton.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    Text {
                        width: parent.width
                        text: entry.modelData.title || entry.modelData.tooltipTitle
                            || entry.modelData.id || "Tray application"
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        elide: Text.ElideRight
                    }

                    Text {
                        text: entry.hidden ? "overflow" : "on bar"
                        color: entry.hidden ? Theme.brightBlack : Theme.accent
                        font.family: Theme.fontFamily
                        font.pixelSize: Math.max(8, Theme.fontSize - 3)
                    }
                }

                MouseArea {
                    id: entryMouse
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.right: placementButton.left
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

                    QsMenuAnchor {
                        id: menuAnchor
                        menu: entry.modelData.menu
                        anchor.item: entryMouse
                        anchor.rect.y: entryMouse.height
                    }

                    onClicked: mouse => {
                        if (mouse.button === Qt.LeftButton) {
                            if (entry.modelData.onlyMenu && entry.modelData.hasMenu) {
                                menuAnchor.open()
                            } else {
                                entry.modelData.activate()
                                root.visible = false
                            }
                        } else if (mouse.button === Qt.MiddleButton) {
                            entry.modelData.secondaryActivate()
                            root.visible = false
                        } else if (entry.modelData.hasMenu) {
                            menuAnchor.open()
                        }
                    }
                }

                Rectangle {
                    id: placementButton
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.round(52 * Theme.barScale)
                    height: Math.round(24 * Theme.barScale)
                    color: placementMouse.containsMouse ? Theme.gray4 : Theme.gray3
                    border.width: 1
                    border.color: entry.hidden ? Theme.gray5 : Theme.accent

                    Text {
                        anchors.centerIn: parent
                        text: entry.hidden ? "Show" : "Hide"
                        color: entry.hidden ? Theme.fg : Theme.accent
                        font.family: Theme.fontFamily
                        font.pixelSize: Math.max(9, Theme.fontSize - 2)
                    }

                    MouseArea {
                        id: placementMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: TrayState.setHidden(entry.modelData, !entry.hidden)
                    }
                }
            }
        }
    }
}
