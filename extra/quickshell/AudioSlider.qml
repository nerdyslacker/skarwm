import QtQuick

// Small, dependency-free volume slider shared by the rows in AudioPopup.
Item {
    id: root

    required property var audio
    property color accent: Theme.green

    readonly property real volume: audio?.volume ?? 0
    readonly property real shownVolume: sliderMouse.pressed
        ? sliderMouse.dragVolume : volume

    height: 24

    Rectangle {
        id: track
        anchors.left: parent.left
        anchors.right: percent.left
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        height: 4
        color: Qt.alpha(Theme.fg, 0.14)

        Rectangle {
            width: Math.min(Math.max(root.shownVolume, 0), 1) * parent.width
            height: parent.height
            color: root.accent
        }

        Rectangle {
            readonly property real fraction: Math.min(Math.max(root.shownVolume, 0), 1)
            x: fraction * parent.width - width / 2
            anchors.verticalCenter: parent.verticalCenter
            width: 11
            height: 11
            color: Theme.fg
            border.width: 2
            border.color: Theme.bg
        }
    }

    Text {
        id: percent
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 38
        horizontalAlignment: Text.AlignRight
        text: Math.round(root.shownVolume * 100) + "%"
        color: root.accent
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }

    MouseArea {
        id: sliderMouse
        anchors.left: track.left
        anchors.right: track.right
        anchors.verticalCenter: track.verticalCenter
        height: 22
        property real dragVolume: 0

        function volumeAt(x) {
            return Math.min(Math.max(x / width, 0), 1)
        }

        function apply(x) {
            dragVolume = volumeAt(x)
            if (root.audio)
                root.audio.volume = dragVolume
        }

        onPressed: mouse => apply(mouse.x)
        onPositionChanged: mouse => {
            if (pressed)
                apply(mouse.x)
        }
    }
}
