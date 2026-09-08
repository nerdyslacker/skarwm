import QtQuick

Popout {
    id: root

    property int draftCount: TagConfig.count
    property bool draftShowNumbers: TagConfig.showNumbers

    cardWidth: 270
    cardHeight: content.implicitHeight + 2 * cardPadding

    onVisibleChanged: {
        if (visible) {
            draftCount = TagConfig.count
            draftShowNumbers = TagConfig.showNumbers
        }
    }

    component StepButton: Rectangle {
        id: step
        required property string symbol
        signal activated()

        width: 30
        height: 28
        color: pointer.containsMouse ? Theme.gray4 : Theme.gray2
        border.width: 1
        border.color: pointer.containsMouse ? Theme.accent : Theme.gray5
        Text {
            anchors.centerIn: parent
            text: step.symbol
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize + 2
        }
        MouseArea {
            id: pointer
            anchors.fill: parent
            hoverEnabled: true
            onClicked: step.activated()
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

        Row {
            width: parent.width
            height: 28

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

            Rectangle {
                id: displaySwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 34
                height: 18
                radius: 0
                color: root.draftShowNumbers
                    ? Theme.accent : Qt.alpha(Theme.fg, 0.15)
                Behavior on color { ColorAnimation { duration: 150 } }

                Rectangle {
                    x: root.draftShowNumbers ? parent.width - width - 2 : 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14
                    height: 14
                    radius: 0
                    color: root.draftShowNumbers
                        ? Theme.bg : Qt.alpha(Theme.fg, 0.7)
                    Behavior on x {
                        NumberAnimation {
                            duration: 150
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.draftShowNumbers = !root.draftShowNumbers
                }
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
                    TagConfig.save(root.draftCount, root.draftShowNumbers)
                    root.visible = false
                }
            }
        }
    }
}
