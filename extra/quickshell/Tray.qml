import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.SystemTray

// StatusNotifierItem tray (SNI over DBus, works fine on X11). Icons assigned
// to overflow remain available from the trailing button.
Rectangle {
    id: root

    readonly property var visibleItems: SystemTray.items.values.filter(
        item => !TrayState.isHidden(item))

    visible: BarVisibility.enabled("tray") && TrayState.ready
        && SystemTray.items.values.length > 0
    implicitWidth: trayRow.implicitWidth + Math.round(14 * Theme.barScale)
    implicitHeight: Theme.moduleHeight
    radius: 0
    color: Qt.alpha(Theme.fg, 0.07)
    border.width: 1
    border.color: Theme.gray5

    Row {
        id: trayRow
        anchors.centerIn: parent
        spacing: 4

        Repeater {
            model: root.visibleItems

            MouseArea {
                id: trayItem
                required property SystemTrayItem modelData

                width: Math.round(20 * Theme.barScale)
                height: Theme.moduleHeight
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

                IconImage {
                    anchors.centerIn: parent
                    implicitSize: Math.round(16 * Theme.barScale)
                    source: trayItem.modelData.icon
                }

                QsMenuAnchor {
                    id: menuAnchor
                    menu: trayItem.modelData.menu
                    anchor.item: trayItem
                    anchor.rect.y: trayItem.height + 8
                }

                onClicked: m => {
                    if (m.button === Qt.LeftButton) {
                        if (modelData.onlyMenu && modelData.hasMenu)
                            menuAnchor.open()
                        else
                            modelData.activate()
                    } else if (m.button === Qt.MiddleButton) {
                        modelData.secondaryActivate()
                    } else if (modelData.hasMenu) {
                        menuAnchor.open()
                    }
                }
            }
        }

        Rectangle {
            visible: root.visibleItems.length > 0
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: Math.round(16 * Theme.barScale)
            color: Theme.gray5
        }

        MouseArea {
            id: overflowButton
            anchors.verticalCenter: parent.verticalCenter
            width: overflowLabel.implicitWidth + Math.round(8 * Theme.barScale)
            height: Theme.moduleHeight
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton

            Rectangle {
                anchors.fill: parent
                color: overflowButton.containsMouse ? Theme.gray3 : "transparent"
            }

            Text {
                id: overflowLabel
                anchors.centerIn: parent
                text: "󰅀"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            onClicked: overflowPopup.visible = !overflowPopup.visible
        }
    }

    TrayPopup {
        id: overflowPopup
        anchorItem: overflowButton
    }
}
