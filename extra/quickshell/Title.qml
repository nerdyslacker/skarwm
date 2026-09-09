import QtQuick

// Focused window title, centered in the available space.
Item {
    id: root

    readonly property bool hasTitle: Wm.title !== ""

    implicitWidth: hasTitle
        ? titleText.implicitWidth + Math.round(18 * Theme.barScale) : 0
    implicitHeight: Theme.moduleHeight

    Rectangle {
        id: titleBox
        visible: root.hasTitle
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.hasTitle ? parent.width : 0
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

}
