pragma ComponentBehavior: Bound

import QtQuick

Popout {
    id: root

    cardWidth: 790
    cardHeight: content.implicitHeight + 2 * cardPadding
    alignRight: true

    component ToggleSwitch: Rectangle {
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

    component WidgetRow: Rectangle {
        id: widgetRow
        required property string widgetKey
        readonly property var info: BarVisibility.metadata(widgetKey)
        readonly property bool isEnabled: BarVisibility.enabled(widgetKey)
        readonly property bool mandatory: info && info.mandatory === true
        property bool dragging: false

        width: parent.width
        height: 36
        color: dragging
            ? Qt.alpha(Theme.accent, 0.22) : Qt.alpha(Theme.fg, 0.045)
        border.width: 1
        border.color: dragging ? Theme.accent : Theme.gray5
        z: dragging ? 100 : 1
        opacity: dragging ? 0.82 : 1

        DragHandler {
            id: dragHandler
            target: dragProxy
            acceptedButtons: Qt.LeftButton
            onActiveChanged: {
                if (active) {
                    widgetRow.dragging = true
                } else if (widgetRow.dragging) {
                    dragProxy.Drag.drop()
                    widgetRow.dragging = false
                    dragProxy.x = 0
                    dragProxy.y = 0
                }
            }
        }

        // A free-moving proxy keeps the source row in its Column while giving
        // Qt's drag system real scene coordinates across all three sections.
        Item {
            id: dragProxy
            property string widgetKey: widgetRow.widgetKey
            x: 0
            y: 0
            width: widgetRow.width
            height: widgetRow.height
            z: 200

            Drag.active: widgetRow.dragging
            Drag.source: dragProxy
            Drag.keys: ["bar-widget"]
            Drag.hotSpot.x: width / 2
            Drag.hotSpot.y: height / 2
            Drag.supportedActions: Qt.MoveAction

            Rectangle {
                anchors.fill: parent
                visible: widgetRow.dragging
                color: Theme.gray2
                border.width: 2
                border.color: Theme.accent
                Text {
                    anchors.centerIn: parent
                    text: widgetRow.info ? widgetRow.info.label : widgetRow.widgetKey
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
            }
        }

        Text {
            id: handle
            anchors.left: parent.left
            anchors.leftMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            text: "󰇙"
            color: widgetRow.dragging ? Theme.accent : Theme.gray6
            font.family: Theme.fontFamily
            font.pixelSize: 13
        }

        Text {
            id: widgetIcon
            anchors.left: handle.right
            anchors.leftMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            text: widgetRow.info ? widgetRow.info.icon : ""
            color: widgetRow.isEnabled ? Theme.cyan : Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: 15
        }

        Text {
            anchors.left: widgetIcon.right
            anchors.leftMargin: 7
            anchors.right: widgetRow.mandatory ? parent.right : widgetSwitch.left
            anchors.rightMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            text: widgetRow.info ? widgetRow.info.label : widgetRow.widgetKey
            elide: Text.ElideRight
            color: widgetRow.isEnabled ? Theme.fg : Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }

        ToggleSwitch {
            id: widgetSwitch
            anchors.right: parent.right
            anchors.rightMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            checked: widgetRow.isEnabled
            visible: !widgetRow.mandatory
            onToggled: BarVisibility.setEnabled(
                widgetRow.widgetKey, !widgetRow.isEnabled)
        }
    }

    component ClusterSection: Column {
        id: section
        required property string clusterName
        required property string heading
        width: (parent.width - 16) / 3
        spacing: 6

        Row {
            width: parent.width
            height: 24
            spacing: 7
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: section.clusterName === "left" ? "󰁍"
                    : section.clusterName === "center" ? "󰘖" : "󰁔"
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: 15
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: section.heading
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
            }
        }

        Rectangle {
            id: dropPanel
            width: parent.width
            height: Math.max(64, rows.implicitHeight + 8)
            color: dropArea.containsDrag
                ? Qt.alpha(Theme.accent, 0.09) : "transparent"
            border.width: 1
            border.color: dropArea.containsDrag ? Theme.accent : Theme.gray5
            Behavior on color { ColorAnimation { duration: 100 } }
            Behavior on border.color { ColorAnimation { duration: 100 } }

            Column {
                id: rows
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 4
                spacing: 4

                Repeater {
                    model: BarVisibility.cluster(section.clusterName)
                    WidgetRow {
                        required property string modelData
                        widgetKey: modelData
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: rows.children.length === 1
                text: "Drop widgets here"
                color: Theme.gray6
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }

            DropArea {
                id: dropArea
                anchors.fill: parent
                keys: ["bar-widget"]
                onDropped: drop => {
                    const source = drop.source
                    if (!source || source.widgetKey === undefined)
                        return
                    const rowPitch = 40
                    const index = Math.round(Math.max(0, drop.y - 4) / rowPitch)
                    BarVisibility.moveWidget(source.widgetKey,
                        section.clusterName, index)
                    drop.acceptProposedAction()
                }
            }
        }
    }

    Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 9

        Text {
            text: "Bar layout"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize + 1
            font.bold: true
        }

        Text {
            text: "Drag widgets between sections or within a section to reorder them"
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }

        Row {
            id: barOptions
            width: parent.width
            height: 68
            spacing: 8

            Rectangle {
                id: positionPanel
                width: (parent.width - barOptions.spacing) / 2
                height: parent.height
                color: "transparent"
                border.width: 1
                border.color: Theme.gray5

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.top: parent.top
                    anchors.topMargin: 6
                    text: "Position"
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }

                Row {
                    id: positionButtons
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 6
                    height: 36
                    spacing: 5

                    Repeater {
                        model: [
                            { key: "top", label: "Top", icon: "󰁝" },
                            { key: "bottom", label: "Bottom", icon: "󰁅" },
                            { key: "left", label: "Left", icon: "󰁍" },
                            { key: "right", label: "Right", icon: "󰁔" }
                        ]

                        Rectangle {
                            id: positionButton
                            required property var modelData
                            readonly property bool selected:
                                BarVisibility.barPosition === modelData.key
                            width: (positionButtons.width - positionButtons.spacing * 3) / 4
                            height: positionButtons.height
                            color: selected ? Theme.accent
                                : positionMouse.containsMouse ? Theme.gray3 : Theme.gray2
                            border.width: 1
                            border.color: selected ? Theme.brightOrange : Theme.gray5

                            Row {
                                anchors.centerIn: parent
                                height: parent.height
                                spacing: 4
                                Text {
                                    width: 15
                                    height: parent.height
                                    verticalAlignment: Text.AlignVCenter
                                    horizontalAlignment: Text.AlignHCenter
                                    text: positionButton.modelData.icon
                                    color: positionButton.selected ? Theme.selfg : Theme.accent
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 14
                                }
                                Text {
                                    height: parent.height
                                    verticalAlignment: Text.AlignVCenter
                                    text: positionButton.modelData.label
                                    color: positionButton.selected ? Theme.selfg : Theme.fg
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Math.max(9, Theme.fontSize - 2)
                                    font.bold: positionButton.selected
                                }
                            }

                            MouseArea {
                                id: positionMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: BarVisibility.setBarPosition(
                                    positionButton.modelData.key)
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: monitorPanel
                width: (parent.width - barOptions.spacing) / 2
                height: parent.height
                color: "transparent"
                border.width: 1
                border.color: Theme.gray5

                Text {
                    id: monitorIcon
                    anchors.left: parent.left
                    anchors.leftMargin: 9
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰍹"
                    color: Theme.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: 17
                }

                Column {
                    anchors.left: monitorIcon.right
                    anchors.leftMargin: 9
                    anchors.right: monitorSwitch.left
                    anchors.rightMargin: 9
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    Text {
                        text: "Show bar on all monitors"
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                    Text {
                        text: BarVisibility.showOnAllMonitors
                            ? "Every connected monitor" : "Main monitor only"
                        color: Theme.brightBlack
                        font.family: Theme.fontFamily
                        font.pixelSize: Math.max(8, Theme.fontSize - 3)
                    }
                }

                ToggleSwitch {
                    id: monitorSwitch
                    anchors.right: parent.right
                    anchors.rightMargin: 9
                    anchors.verticalCenter: parent.verticalCenter
                    checked: BarVisibility.showOnAllMonitors
                    onToggled: BarVisibility.setShowOnAllMonitors(
                        !BarVisibility.showOnAllMonitors)
                }
            }
        }

        Row {
            id: appearanceControls
            width: parent.width
            height: 40
            spacing: 14

            TweakSlider {
                width: (appearanceControls.width
                    - appearanceControls.spacing * 2) / 3
                label: "Height"
                from: 28
                to: 80
                value: Theme.barHeight
                suffix: " px"
                applyFn: value => Theme.barHeight = value
                persistFn: value => Theme.persistBarHeight(value)
            }

            TweakSlider {
                width: (appearanceControls.width
                    - appearanceControls.spacing * 2) / 3
                label: "Item scale"
                from: 0.7
                to: 2.0
                value: Theme.barUserScale
                isInt: false
                suffix: "×"
                applyFn: value => Theme.barUserScale = value
                persistFn: value => Theme.persistBarScale(value)
            }

            TweakSlider {
                width: (appearanceControls.width
                    - appearanceControls.spacing * 2) / 3
                label: "Background opacity"
                from: 0
                to: 100
                value: Math.round(Theme.barBackgroundOpacity * 100)
                suffix: "%"
                applyFn: value => Theme.barBackgroundOpacity = value / 100
                persistFn: value => Theme.persistBarBackgroundOpacity(value / 100)
            }
        }

        Row {
            width: parent.width
            spacing: 8
            ClusterSection {
                clusterName: "left"
                heading: BarVisibility.verticalBar ? "Top" : "Left"
            }
            ClusterSection { clusterName: "center"; heading: "Center" }
            ClusterSection {
                clusterName: "right"
                heading: BarVisibility.verticalBar ? "Bottom" : "Right"
            }
        }
    }
}
