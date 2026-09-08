import QtQuick
import Quickshell
import Quickshell.Io

// Shared card-sized shell for every bar popup. Keeping the actual popup
// window at card size prevents an X11 compositor or window manager from
// turning a transparent full-screen click catcher into a desktop-covering
// surface. Escape and clicking the module again close the card. The xinput
// watcher below is a compatibility fallback for Quickshell 0.3.0, whose
// PopupWindow focus grab does not report outside presses reliably on X11.
PopupWindow {
    id: root

    property Item anchorItem
    property real cardWidth: 300
    property real cardHeight: 300
    readonly property real cardPadding: 14
    // right-edge panel mode (control center) instead of centered-under-anchor
    property bool alignRight: false
    // Optional point positioning for keyboard-invoked menus. Coordinates are
    // global X11 coordinates and are clamped to their containing screen.
    property bool positionAtPoint: false
    property real pointX: 0
    property real pointY: 0

    default property alias content: inner.data

    visible: false
    grabFocus: true
    color: "transparent"

    anchor.item: anchorItem
    anchor.rect.x: uOffsetX
    anchor.rect.y: uOffsetY
    implicitWidth: cardWidth
    implicitHeight: cardHeight

    // Window offset from the anchor item, clamped to the screen.
    property real uOffsetX: 0
    property real uOffsetY: (anchorItem?.height ?? 0) + 12

    function showAtAnchor() {
        positionAtPoint = false
        visible = true
    }

    function showAtGlobalPoint(x, y) {
        positionAtPoint = true
        pointX = x
        pointY = y
        visible = true
    }

    onVisibleChanged: {
        if (visible && anchorItem) {
            const p = anchorItem.mapToGlobal(0, 0)
            let target = null
            const locateX = positionAtPoint ? pointX : p.x
            const locateY = positionAtPoint ? pointY : p.y
            for (const candidate of Quickshell.screens) {
                if (locateX >= candidate.x && locateX < candidate.x + candidate.width
                        && locateY >= candidate.y && locateY < candidate.y + candidate.height) {
                    target = candidate
                    break
                }
            }
            if (!target && Quickshell.screens.length)
                target = Quickshell.screens[0]

            const screenX = target ? target.x : 0
            const screenY = target ? target.y : 0
            const screenWidth = target ? target.width : 1920
            const screenHeight = target ? target.height : 1080
            const leftEdge = screenX + 8
            const rightEdge = screenX + screenWidth - cardWidth - 8
            const desiredX = positionAtPoint
                ? Math.min(Math.max(pointX + 12, leftEdge), rightEdge)
                : alignRight ? rightEdge
                : Math.min(Math.max(p.x + anchorItem.width / 2 - cardWidth / 2,
                                    leftEdge), rightEdge)
            uOffsetX = desiredX - p.x
            if (positionAtPoint) {
                const topEdge = screenY + 8
                const bottomEdge = screenY + screenHeight - cardHeight - 8
                const desiredY = Math.min(Math.max(pointY + 12, topEdge), bottomEdge)
                uOffsetY = desiredY - p.y
            } else {
                uOffsetY = anchorItem.height + 12
            }
            inner.forceActiveFocus()
            enterAnim.restart()
        }
    }

    // Newer Quickshell releases close a focus-grabbing PopupWindow on an
    // outside press themselves. On 0.3.0, observe XInput raw presses and then
    // compare the pointer with the card. This does not grab input and therefore
    // lets the original click reach the window beneath the popup.
    Process {
        id: outsideClickWatcher
        running: root.visible
        command: ["xinput", "test-xi2", "--root"]
        stdout: SplitParser {
            onRead: line => {
                if (line.indexOf("(RawButtonPress)") !== -1 && !pointerPosition.running)
                    pointerPosition.running = true
            }
        }
    }

    Process {
        id: pointerPosition
        command: ["xdotool", "getmouselocation", "--shell"]
        stdout: StdioCollector {
            onStreamFinished: {
                const xMatch = text.match(/(?:^|\n)X=(-?\d+)/)
                const yMatch = text.match(/(?:^|\n)Y=(-?\d+)/)
                if (!root.visible || !xMatch || !yMatch)
                    return

                const pointerX = Number(xMatch[1])
                const pointerY = Number(yMatch[1])
                const origin = card.mapToGlobal(0, 0)
                const outside = pointerX < origin.x || pointerY < origin.y
                    || pointerX >= origin.x + card.width
                    || pointerY >= origin.y + card.height
                if (outside)
                    root.visible = false
            }
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
