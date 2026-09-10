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
    readonly property real screenMargin: 8
    // right-edge panel mode (control center) instead of centered-under-anchor
    property bool alignRight: false
    property bool anchorAtRight: alignRight
    // Optional point positioning for keyboard-invoked menus. Coordinates are
    // global X11 coordinates and are clamped to their containing screen.
    property bool positionAtPoint: false
    property bool positionCentered: false
    property real pointX: 0
    property real pointY: 0
    property real centerRectX: 0
    property real centerRectY: 0
    property real centerRectWidth: 0
    property real centerRectHeight: 0
    readonly property string openDirection: positionAtPoint || positionCentered
        ? "free" : BarVisibility.barPosition

    default property alias content: inner.data

    visible: false
    grabFocus: true
    color: "transparent"

    anchor {
        window: root.anchorItem ? root.anchorItem.QsWindow.window : null
        edges: root.openDirection === "bottom" ? Edges.Bottom | Edges.Left
            : root.openDirection === "left" ? Edges.Left | Edges.Top
            : root.openDirection === "right" ? Edges.Right | Edges.Top
            : Edges.Top | Edges.Left
        gravity: root.openDirection === "bottom"
            ? (root.anchorAtRight ? Edges.Top | Edges.Left
                                  : Edges.Top | Edges.Right)
            : root.openDirection === "left"
            ? (root.anchorAtBottom ? Edges.Top | Edges.Right
                                   : Edges.Bottom | Edges.Right)
            : root.openDirection === "right"
            ? (root.anchorAtBottom ? Edges.Top | Edges.Left
                                   : Edges.Bottom | Edges.Left)
            : (root.anchorAtRight ? Edges.Bottom | Edges.Left
                                  : Edges.Bottom | Edges.Right)
        adjustment: PopupAdjustment.None
        onAnchoring: root.updatePlacement()
    }
    implicitWidth: cardWidth
    implicitHeight: cardHeight

    property bool anchorAtBottom: false

    function showAtAnchor() {
        positionAtPoint = false
        positionCentered = false
        visible = true
    }

    function showAtGlobalPoint(x, y) {
        positionAtPoint = true
        positionCentered = false
        pointX = x
        pointY = y
        visible = true
    }

    function showCenteredInRect(x, y, width, height) {
        positionAtPoint = false
        positionCentered = true
        centerRectX = x
        centerRectY = y
        centerRectWidth = width
        centerRectHeight = height
        visible = true
    }

    function updatePlacement() {
        if (!visible || !anchorItem)
            return

        // Mapping all four corners keeps placement correct when a horizontal
        // module is rotated into a left/right vertical bar.
        const p0 = anchorItem.mapToGlobal(0, 0)
        const p1 = anchorItem.mapToGlobal(anchorItem.width, 0)
        const p2 = anchorItem.mapToGlobal(0, anchorItem.height)
        const p3 = anchorItem.mapToGlobal(anchorItem.width, anchorItem.height)
        const anchorLeft = Math.min(p0.x, p1.x, p2.x, p3.x)
        const anchorRight = Math.max(p0.x, p1.x, p2.x, p3.x)
        const anchorTop = Math.min(p0.y, p1.y, p2.y, p3.y)
        const anchorBottom = Math.max(p0.y, p1.y, p2.y, p3.y)
        const anchorCenterX = (anchorLeft + anchorRight) / 2
        const anchorCenterY = (anchorTop + anchorBottom) / 2
        let target = null
        const locateX = positionCentered
            ? centerRectX + centerRectWidth / 2
            : positionAtPoint ? pointX : anchorCenterX
        const locateY = positionCentered
            ? centerRectY + centerRectHeight / 2
            : positionAtPoint ? pointY : anchorCenterY
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
        const leftEdge = screenX + screenMargin
        const rightEdge = screenX + screenWidth - cardWidth - screenMargin
        const topEdge = screenY + screenMargin
        const bottomEdge = screenY + screenHeight - cardHeight - screenMargin
        let requestedX = positionCentered
            ? centerRectX + (centerRectWidth - cardWidth) / 2
            : positionAtPoint ? pointX + 12
            : openDirection === "left" ? anchorRight + 12
            : openDirection === "right" ? anchorLeft - cardWidth - 12
            : alignRight ? rightEdge
            : anchorCenterX - cardWidth / 2
        let requestedY = positionCentered
            ? centerRectY + (centerRectHeight - cardHeight) / 2
            : positionAtPoint ? pointY + 12
            : openDirection === "top" ? anchorBottom + 12
            : openDirection === "bottom" ? anchorTop - cardHeight - 12
            : anchorCenterY - cardHeight / 2
        const desiredX = Math.min(Math.max(requestedX, leftEdge), rightEdge)
        const desiredY = Math.min(Math.max(requestedY, topEdge), bottomEdge)
        anchorAtRight = openDirection !== "left" && openDirection !== "right"
            && (alignRight || requestedX >= rightEdge)
        anchorAtBottom = (openDirection === "left" || openDirection === "right")
            && requestedY >= bottomEdge
        const anchorX = openDirection === "right" || anchorAtRight
            ? desiredX + cardWidth - 1 : desiredX
        const anchorY = openDirection === "bottom" || anchorAtBottom
            ? desiredY + cardHeight - 1 : desiredY

        const windowContent = anchorItem.QsWindow.contentItem
        if (!windowContent)
            return
        const local = windowContent.mapFromGlobal(anchorX, anchorY)
        anchor.rect.x = Math.round(local.x)
        anchor.rect.y = Math.round(local.y)
    }

    // Use a connection instead of the component's onVisibleChanged handler.
    // Derived popups commonly define their own handler to refresh content;
    // that overrides an inherited handler, but does not replace this listener.
    Connections {
        target: root
        function onVisibleChanged() {
            if (root.visible && root.anchorItem) {
                root.updatePlacement()
                inner.forceActiveFocus()
                enterAnim.restart()
            }
        }
    }

    Connections {
        target: BarVisibility
        function onBarPositionChanged() {
            if (root.visible && root.anchorItem) {
                root.updatePlacement()
            }
        }
    }

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
            NumberAnimation { target: slide
                              property: root.openDirection === "left"
                                  || root.openDirection === "right" ? "x" : "y"
                              from: root.openDirection === "bottom"
                                  || root.openDirection === "right" ? 10 : -10
                              to: 0
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
