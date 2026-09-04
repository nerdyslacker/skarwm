import QtQuick
import Quickshell

// Shared card-sized shell for every bar popup. Keeping the actual popup
// window at card size prevents an X11 compositor or window manager from
// turning a transparent full-screen click catcher into a desktop-covering
// surface. Escape and clicking the module again close the card.
PopupWindow {
    id: root

    property Item anchorItem
    property real cardWidth: 300
    property real cardHeight: 300
    readonly property real cardPadding: 14
    // right-edge panel mode (control center) instead of centered-under-anchor
    property bool alignRight: false

    default property alias content: inner.data

    visible: false
    color: "transparent"

    anchor.item: anchorItem
    anchor.rect.x: uOffsetX
    anchor.rect.y: (anchorItem?.height ?? 0) + 12
    implicitWidth: cardWidth
    implicitHeight: cardHeight

    // Window offset from the anchor item, clamped to the screen.
    property real uOffsetX: 0

    onVisibleChanged: {
        if (visible && anchorItem) {
            const p = anchorItem.mapToGlobal(0, 0)
            const sw = Quickshell.screens.length ? Quickshell.screens[0].width : 1920
            const desired = alignRight ? sw - cardWidth - 8
                : Math.min(Math.max(p.x + anchorItem.width / 2 - cardWidth / 2, 8),
                           sw - cardWidth - 8)
            uOffsetX = desired - p.x
            inner.forceActiveFocus()
            enterAnim.restart()
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.visible = false
    }

    Rectangle {
        id: card
        anchors.fill: parent

        transform: Translate { id: slide; y: 0 }

        ParallelAnimation {
            id: enterAnim
            NumberAnimation { target: slide; property: "y"; from: -10; to: 0
                              duration: 160; easing.type: Easing.OutCubic }
            NumberAnimation { target: card; property: "opacity"; from: 0; to: 1
                              duration: 160 }
        }
        radius: 0
        color: Theme.bg
        border.width: 1
        border.color: Qt.alpha(Theme.accent, 0.4)

        Behavior on color { ColorAnimation { duration: 250 } }

        // Keep clicks inside the card from closing it.
        MouseArea { anchors.fill: parent }

        Item {
            id: inner
            anchors.fill: parent
            anchors.margins: root.cardPadding
            focus: true
            Keys.onEscapePressed: root.visible = false
        }
    }
}
