import QtQuick
import Quickshell

// The panel touches all three screen edges. PanelWindow publishes the EWMH
// dock/strut that skarwm uses to reserve the bar's space.
PanelWindow {
    id: root
    property var modelData
    readonly property var widgetSources: ({
        launcher: Qt.resolvedUrl("Launcher.qml"),
        tags: Qt.resolvedUrl("Tags.qml"),
        layout: Qt.resolvedUrl("LayoutButton.qml"),
        title: Qt.resolvedUrl("Title.qml"),
        scratchpads: Qt.resolvedUrl("Scratchpads.qml"),
        media: Qt.resolvedUrl("Media.qml"),
        weather: Qt.resolvedUrl("Weather.qml"),
        metrics: Qt.resolvedUrl("Metrics.qml"),
        battery: Qt.resolvedUrl("Battery.qml"),
        brightness: Qt.resolvedUrl("Brightness.qml"),
        volume: Qt.resolvedUrl("Volume.qml"),
        micIndicator: Qt.resolvedUrl("MicMute.qml"),
        network: Qt.resolvedUrl("Network.qml"),
        keyboard: Qt.resolvedUrl("KeyboardLayout.qml"),
        clipboard: Qt.resolvedUrl("Clipboard.qml"),
        tray: Qt.resolvedUrl("Tray.qml"),
        notifications: Qt.resolvedUrl("Bell.qml"),
        clock: Qt.resolvedUrl("Clock.qml"),
        capsLock: Qt.resolvedUrl("CapsLock.qml"),
        screenshot: Qt.resolvedUrl("Screenshot.qml")
    })
    screen: modelData
    anchors { top: true; left: true; right: true }
    implicitHeight: Theme.effectiveBarHeight
    color: Theme.bg
    visible: Theme.barStateReady && BarVisibility.showOnScreen(modelData)

    WindowOverview {
        anchorItem: panel
    }

    component WidgetLoader: Loader {
        required property string widgetKey
        readonly property real naturalWidth: item ? item.implicitWidth : 0

        active: BarVisibility.enabled(widgetKey)
        source: root.widgetSources[widgetKey] ?? ""
        visible: active
        width: active && status === Loader.Ready && item && item.visible
            ? (widgetKey === "title"
            ? Math.min(naturalWidth, root.width * 0.34) : naturalWidth) : 0
        height: item ? item.implicitHeight : Theme.moduleHeight
    }

    component WidgetCluster: Row {
        required property string clusterName
        spacing: 4

        Repeater {
            model: BarVisibility.cluster(parent.clusterName)
            WidgetLoader {
                required property string modelData
                widgetKey: modelData
            }
        }
    }

    Rectangle {
        id: panel
        anchors.fill: parent
        color: Theme.bg
        radius: 0

        WidgetCluster {
            id: leftCluster
            clusterName: "left"
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
        }

        // Keep the center genuinely centered when space permits, then nudge
        // it between the outer clusters on crowded bars.
        WidgetCluster {
            id: centerCluster
            clusterName: "center"
            readonly property real gapLeft: leftCluster.x + leftCluster.width + 12
            readonly property real gapRight: rightCluster.x - 12
            readonly property real availableWidth: Math.max(0, gapRight - gapLeft)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, availableWidth)
            clip: width < implicitWidth
            x: Math.max(gapLeft,
                Math.min((parent.width - width) / 2,
                    gapRight - width))
        }

        Row {
            id: rightCluster
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            WidgetCluster { clusterName: "right" }
            Commands {}
        }
    }
}
