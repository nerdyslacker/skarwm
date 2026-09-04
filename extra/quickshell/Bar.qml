import QtQuick
import Quickshell

// The panel touches all three screen edges. PanelWindow publishes the EWMH
// dock/strut that skarwm uses to reserve the bar's space.
PanelWindow {
    id: root
    property var modelData
    screen: modelData
    anchors { top: true; left: true; right: true }
    implicitHeight: Theme.effectiveBarHeight
    color: Theme.bg
    visible: Theme.barStateReady

    Rectangle {
        id: panel
        anchors.fill: parent
        color: Theme.bg
        radius: 0

        Row {
            id: leftCluster
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Launcher {}
            Tags {}
        }

        // Title lives in the gap between the clusters: screen-centered when
        // it fits, nudged inward when it doesn't, elided to the gap width.
        // (A symmetric clamp goes negative on narrow screens — the right
        // cluster is wide — and a negative-width Text ignores elide.)
        Title {
            anchors.verticalCenter: parent.verticalCenter
            readonly property real gapL: leftCluster.x + leftCluster.width + 24
            readonly property real gapR: rightCluster.x - 24
            width: Math.max(0, Math.min(implicitWidth, gapR - gapL))
            x: Math.max(gapL, Math.min((parent.width - width) / 2, gapR - width))
            visible: width > 40
        }

        Row {
            id: rightCluster
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Media {}
            Weather {}
            Metrics {}
            Volume {}
            Network {}
            Tray {}
            Bell {}
            Clock {}
            MicMute {}
            CapsLock {}
            Screenshot {}
            Commands {}
        }
    }
}
