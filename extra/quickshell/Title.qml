import QtQuick
import QtQuick.Controls

// Focused window title, centered in the available space.
Item {
    id: root

    readonly property bool hasTitle: Wm.title !== ""

    implicitWidth: hasTitle ? (BarVisibility.verticalBar
        ? Theme.moduleHeight : Math.round(220 * Theme.barScale)) : 0
    implicitHeight: Theme.moduleHeight

    Rectangle {
        id: titleBox
        visible: root.hasTitle
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.hasTitle ? parent.width : 0
        radius: 0
        color: Theme.barSurface(0.07)
        border.width: 1
        border.color: Theme.gray5

        Text {
            id: titleText
            anchors.fill: parent
            anchors.leftMargin: BarVisibility.verticalBar
                ? 0 : Math.round(9 * Theme.barScale)
            anchors.rightMargin: BarVisibility.verticalBar
                ? 0 : Math.round(9 * Theme.barScale)
            text: BarVisibility.verticalBar ? "󰖯" : Wm.title
            color: Qt.alpha(Theme.fg, 0.75)
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            Behavior on color { ColorAnimation { duration: 250 } }
        }

        MouseArea {
            id: titleMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
        }

        ToolTip {
            id: titleTooltip
            parent: titleBox
            visible: titleMouse.containsMouse && root.hasTitle
                && (BarVisibility.verticalBar || titleText.truncated)
            text: Wm.title
            delay: 350
            popupType: Popup.Window
            x: BarVisibility.verticalBar
                ? (BarVisibility.barPosition === "left"
                    ? titleBox.width + 6 : -width - 6)
                : (titleBox.width - width) / 2
            y: BarVisibility.verticalBar
                ? (titleBox.height - height) / 2
                : BarVisibility.barPosition === "bottom"
                    ? -height - 6 : titleBox.height + 6
        }
    }

}
