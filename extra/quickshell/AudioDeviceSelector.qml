pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

// Compact dropdown used for both playback and capture devices.
Column {
    id: root

    required property var devices
    required property var currentDevice
    property bool expanded: false
    signal selected(var device)

    spacing: 2

    function deviceName(device) {
        if (!device)
            return "Select a device"
        return device.description || device.nickname || device.name || "Unknown device"
    }

    Rectangle {
        id: selector
        width: root.width
        height: 34
        color: selectorMouse.containsMouse ? Theme.gray3 : Theme.gray2
        border.width: 1
        border.color: root.expanded ? Theme.accent : Theme.gray5

        Text {
            id: selectedLabel
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: arrow.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: root.deviceName(root.currentDevice)
            elide: Text.ElideRight
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }

        Text {
            id: arrow
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: root.expanded ? "󰅀" : "󰅂"
            color: Theme.accent
            font.family: Theme.fontFamily
            font.pixelSize: Theme.iconSize
        }

        MouseArea {
            id: selectorMouse
            anchors.fill: parent
            hoverEnabled: true
            ToolTip.visible: containsMouse && selectedLabel.truncated
            ToolTip.text: selectedLabel.text
            ToolTip.delay: 350
            onClicked: root.expanded = !root.expanded
        }
    }

    Repeater {
        model: root.expanded ? root.devices : []

        Rectangle {
            id: option
            required property var modelData
            readonly property bool current: modelData === root.currentDevice

            width: root.width
            height: 32
            color: current ? Theme.accent
                : (optionMouse.containsMouse ? Theme.gray3 : Theme.gray2)
            border.width: 1
            border.color: current ? Theme.brightOrange : Theme.gray5

            Text {
                id: optionLabel
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: root.deviceName(option.modelData)
                elide: Text.ElideRight
                color: option.current ? Theme.selfg : Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: option.current
            }

            MouseArea {
                id: optionMouse
                anchors.fill: parent
                hoverEnabled: true
                ToolTip.visible: containsMouse && optionLabel.truncated
                ToolTip.text: optionLabel.text
                ToolTip.delay: 350
                onClicked: {
                    root.selected(option.modelData)
                    root.expanded = false
                }
            }
        }
    }
}
