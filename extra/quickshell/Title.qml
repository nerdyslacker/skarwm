import QtQuick

// Focused window title, centered in the available space.
Item {
    id: root

    readonly property bool hasScratchpads: Wm.registeredScratchpads.length > 0
    readonly property bool hasTitle: Wm.title !== ""
    readonly property int scratchButtonSize: Theme.moduleHeight
    readonly property int scratchGap: Math.round(4 * Theme.barScale)

    implicitWidth: (hasTitle ? titleText.implicitWidth + Math.round(18 * Theme.barScale) : 0)
        + (hasScratchpads ? scratchButtonSize + scratchGap : 0)
    implicitHeight: Theme.moduleHeight

    Rectangle {
        id: titleBox
        visible: root.hasTitle
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.hasTitle ? Math.max(0, parent.width - (root.hasScratchpads
            ? root.scratchButtonSize + root.scratchGap : 0)) : 0
        radius: 0
        color: Qt.alpha(Theme.fg, 0.07)
        border.width: 1
        border.color: Theme.gray5

        Text {
            id: titleText
            anchors.fill: parent
            anchors.leftMargin: Math.round(9 * Theme.barScale)
            anchors.rightMargin: Math.round(9 * Theme.barScale)
            text: Wm.title
            color: Qt.alpha(Theme.fg, 0.75)
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            Behavior on color { ColorAnimation { duration: 250 } }
        }
    }

    Rectangle {
        id: scratchButton
        visible: root.hasScratchpads
        width: root.scratchButtonSize
        height: root.scratchButtonSize
        anchors.left: titleBox.right
        anchors.leftMargin: root.hasTitle ? root.scratchGap : 0
        anchors.verticalCenter: parent.verticalCenter
        color: scratchMouse.containsMouse
            ? Qt.alpha(Theme.accent, 0.24) : Qt.alpha(Theme.accent, 0.10)
        border.width: 1
        border.color: scratchMouse.containsMouse ? Theme.accent : Theme.gray5

        Text {
            anchors.centerIn: parent
            text: "󰆍"
            color: Theme.accent
            font.family: Theme.fontFamily
            font.pixelSize: Theme.iconSize
        }

        MouseArea {
            id: scratchMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: scratchpads.visible = !scratchpads.visible
        }
    }

    ScratchpadsPopup {
        id: scratchpads
        anchorItem: scratchButton
    }
}
