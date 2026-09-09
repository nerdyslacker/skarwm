import QtQuick

Popout {
    id: root

    property int draftCount: TagConfig.count
    property bool draftShowNumbers: TagConfig.showNumbers
    property bool draftDynamicWorkspaces: TagConfig.dynamicWorkspaces

    cardWidth: 270
    cardHeight: content.implicitHeight + 2 * cardPadding

    onVisibleChanged: {
        if (visible) {
            draftCount = TagConfig.count
            draftShowNumbers = TagConfig.showNumbers
            draftDynamicWorkspaces = TagConfig.dynamicWorkspaces
        }
    }

    component StepButton: Rectangle {
        id: step
        required property string symbol
        signal activated()

        width: 30
        height: 28
        color: !enabled ? Qt.alpha(Theme.fg, 0.04)
            : pointer.containsMouse ? Theme.gray4 : Theme.gray2
        border.width: 1
        border.color: !enabled ? Qt.alpha(Theme.gray5, 0.45)
            : pointer.containsMouse ? Theme.accent : Theme.gray5
        Text {
            anchors.centerIn: parent
            text: step.symbol
            color: step.enabled ? Theme.fg : Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize + 2
        }
        MouseArea {
            id: pointer
            anchors.fill: parent
            hoverEnabled: true
            enabled: step.enabled
            onClicked: step.activated()
        }
    }

    component SettingSwitch: Rectangle {
        id: control
        property bool checked: false
        signal toggled()

        width: 34
        height: 18
        color: checked ? Theme.accent : Qt.alpha(Theme.fg, 0.15)
        Behavior on color { ColorAnimation { duration: 150 } }

        Rectangle {
            x: control.checked ? parent.width - width - 2 : 2
            anchors.verticalCenter: parent.verticalCenter
            width: 14
            height: 14
            color: control.checked ? Theme.bg : Qt.alpha(Theme.fg, 0.7)
            Behavior on x {
                NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: control.toggled()
        }
    }

    Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 11

        Text {
            text: "Tag settings"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize + 1
            font.bold: true
        }

        Item {
            width: parent.width
            height: 30

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Dynamic workspaces"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            SettingSwitch {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.draftDynamicWorkspaces
                onToggled: root.draftDynamicWorkspaces =
                    !root.draftDynamicWorkspaces
            }
        }

        Row {
            id: visibleTagsRow
            width: parent.width
            height: 28
            opacity: root.draftDynamicWorkspaces ? 0.42 : 1
            Behavior on opacity { NumberAnimation { duration: 120 } }

            Text {
                width: parent.width - controls.width
                anchors.verticalCenter: parent.verticalCenter
                text: "Visible tags"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }
            Row {
                id: controls
                enabled: !root.draftDynamicWorkspaces
                spacing: 7
                StepButton {
                    symbol: "−"
                    onActivated: root.draftCount = Math.max(1, root.draftCount - 1)
                }
                Text {
                    width: 24
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: root.draftCount
                    color: Theme.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }
                StepButton {
                    symbol: "+"
                    onActivated: root.draftCount = Math.min(20, root.draftCount + 1)
                }
            }
        }

        Item {
            width: parent.width
            height: 30

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Show tag numbers"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            SettingSwitch {
                id: displaySwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.draftShowNumbers
                onToggled: root.draftShowNumbers = !root.draftShowNumbers
            }
        }

        Rectangle {
            width: parent.width
            height: 34
            color: saveMouse.containsMouse ? Theme.brightOrange : Theme.accent
            Text {
                anchors.centerIn: parent
                text: "Apply"
                color: Theme.selfg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
            }
            MouseArea {
                id: saveMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                    TagConfig.save(root.draftCount, root.draftShowNumbers,
                        root.draftDynamicWorkspaces)
                    root.visible = false
                }
            }
        }
    }
}
