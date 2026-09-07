pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls

// Session scratchpad list. Clicking an entry applies the register's normal
// toggle semantics: hidden/remote windows are summoned to the active workspace,
// while a visible window on the active workspace is stashed.
Popout {
    id: root

    readonly property int rowHeight: Math.round(42 * Theme.barScale)
    cardWidth: 340
    cardHeight: Math.min(360,
        heading.implicitHeight + divider.height + list.contentHeight
        + content.spacing * 2 + 2 * cardPadding)

    Column {
        id: content
        anchors.fill: parent
        spacing: 9

        Row {
            id: heading
            width: parent.width
            spacing: 8

            Text {
                text: "󰆍"
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: 18
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Scratchpads"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 1
                font.bold: true
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: String(Wm.registeredScratchpads.length)
                color: Qt.alpha(Theme.fg, 0.55)
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
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
            height: Math.min(contentHeight, 290)
            clip: true
            spacing: 5
            model: Wm.registeredScratchpads

            delegate: Rectangle {
                id: entry
                required property var modelData

                width: list.width
                height: root.rowHeight
                color: entryMouse.containsMouse
                    ? Qt.alpha(Theme.accent, 0.18)
                    : Qt.alpha(Theme.fg, 0.05)
                border.width: 1
                border.color: entryMouse.containsMouse ? Theme.accent : Theme.gray5

                Text {
                    id: registerLabel
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(entry.modelData.register)
                    color: Theme.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 1
                    font.bold: true
                }

                Column {
                    anchors.left: registerLabel.right
                    anchors.leftMargin: 12
                    anchors.right: statusLabel.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    Text {
                        width: parent.width
                        text: entry.modelData.title
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        visible: entry.modelData.className !== ""
                        text: entry.modelData.className
                        color: Qt.alpha(Theme.fg, 0.48)
                        font.family: Theme.fontFamily
                        font.pixelSize: Math.max(9, Theme.fontSize - 2)
                        elide: Text.ElideRight
                    }
                }

                Text {
                    id: statusLabel
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: entry.modelData.hidden ? "hidden"
                        : entry.modelData.workspace === null ? "visible"
                        : "ws " + entry.modelData.workspace
                    color: entry.modelData.hidden ? Theme.brightBlack : Theme.green
                    font.family: Theme.fontFamily
                    font.pixelSize: Math.max(9, Theme.fontSize - 2)
                }

                MouseArea {
                    id: entryMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        root.visible = false
                        Wm.toggleScratchpad(entry.modelData.register)
                    }
                }
            }

            Controls.ScrollBar.vertical: Controls.ScrollBar {
                policy: list.contentHeight > list.height
                    ? Controls.ScrollBar.AlwaysOn : Controls.ScrollBar.AlwaysOff
            }
        }
    }
}
