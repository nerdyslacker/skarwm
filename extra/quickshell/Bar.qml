import QtQuick
import Quickshell

// The panel touches all three screen edges. PanelWindow publishes the EWMH
// dock/strut that skarwm uses to reserve the bar's space.
PanelWindow {
    id: root
    property var modelData
    readonly property bool vertical: BarVisibility.verticalBar
    readonly property real longExtent: vertical ? height : width
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
    anchors {
        top: BarVisibility.barPosition === "top" || root.vertical
        bottom: BarVisibility.barPosition === "bottom" || root.vertical
        left: BarVisibility.barPosition === "left" || !root.vertical
        right: BarVisibility.barPosition === "right" || !root.vertical
    }
    implicitWidth: Theme.effectiveBarHeight
    implicitHeight: Theme.effectiveBarHeight
    // Be explicit: Quickshell otherwise derives the X11 reservation from the
    // panel's height, which is the full screen dimension for side bars. The WM
    // adds its configured outer gap outside this physical reservation.
    exclusiveZone: Math.round(root.vertical ? root.width : root.height)
    color: Qt.alpha(Theme.bg, Theme.barBackgroundOpacity)
    visible: Theme.barStateReady && BarVisibility.showOnScreen(modelData)

    WindowOverview {
        anchorItem: panel
    }

    // Modules provide their own compact upright representation on side bars.
    component WidgetLoader: Item {
        id: widgetSlot
        required property string widgetKey
        readonly property real naturalWidth: moduleLoader.item
            ? moduleLoader.item.implicitWidth : 0
        readonly property real naturalHeight: moduleLoader.item
            ? moduleLoader.item.implicitHeight : Theme.moduleHeight
        readonly property real moduleWidth: widgetKey === "title"
            ? Math.min(naturalWidth, root.longExtent * 0.34) : naturalWidth
        readonly property bool itemShown: moduleLoader.status === Loader.Ready
            && moduleLoader.item && moduleLoader.item.visible

        // Stay visible while reading the loaded item's own visibility. Making
        // the parent depend on child.visible creates a false visibility loop.
        visible: moduleLoader.active
        width: itemShown ? moduleWidth : 0
        height: itemShown ? naturalHeight : 0

        Loader {
            id: moduleLoader
            anchors.centerIn: parent
            active: BarVisibility.enabled(widgetSlot.widgetKey)
            source: root.widgetSources[widgetSlot.widgetKey] ?? ""
            width: widgetSlot.moduleWidth
            height: widgetSlot.naturalHeight
        }
    }

    component WidgetCluster: Item {
        id: cluster
        required property string clusterName
        readonly property var entries: BarVisibility.cluster(clusterName)
        implicitWidth: root.vertical
            ? verticalLayout.implicitWidth : horizontalLayout.implicitWidth
        implicitHeight: root.vertical
            ? verticalLayout.implicitHeight : horizontalLayout.implicitHeight
        width: implicitWidth
        height: implicitHeight

        Row {
            id: horizontalLayout
            visible: !root.vertical
            spacing: 4

            Repeater {
                model: horizontalLayout.visible ? cluster.entries : []
                WidgetLoader {
                    required property string modelData
                    widgetKey: modelData
                }
            }
        }

        Column {
            id: verticalLayout
            visible: root.vertical
            spacing: 4

            Repeater {
                model: verticalLayout.visible ? cluster.entries : []
                WidgetLoader {
                    required property string modelData
                    widgetKey: modelData
                }
            }
        }
    }

    Rectangle {
        id: panel
        anchors.fill: parent
        color: Qt.alpha(Theme.bg, Theme.barBackgroundOpacity)
        radius: 0

        WidgetCluster {
            id: leftCluster
            clusterName: "left"
            x: root.vertical ? (parent.width - width) / 2 : 6
            y: root.vertical ? 6 : (parent.height - height) / 2
        }

        // Keep the middle group genuinely centered when space permits, then
        // nudge it between the start/end groups on crowded bars.
        WidgetCluster {
            id: centerCluster
            clusterName: "center"
            readonly property real gapStart: root.vertical
                ? leftCluster.y + leftCluster.height + 12
                : leftCluster.x + leftCluster.width + 12
            readonly property real gapEnd: root.vertical
                ? endCluster.y - 12 : endCluster.x - 12
            readonly property real availableLength: Math.max(0, gapEnd - gapStart)
            width: root.vertical ? childrenRect.width
                : Math.min(childrenRect.width, availableLength)
            height: root.vertical ? Math.min(childrenRect.height, availableLength)
                : childrenRect.height
            clip: root.vertical ? height < childrenRect.height
                : width < childrenRect.width
            x: root.vertical ? (parent.width - width) / 2
                : Math.max(gapStart, Math.min((parent.width - width) / 2,
                                             gapEnd - width))
            y: root.vertical
                ? Math.max(gapStart, Math.min((parent.height - height) / 2,
                                             gapEnd - height))
                : (parent.height - height) / 2
        }

        Item {
            id: endCluster
            implicitWidth: root.vertical
                ? Math.max(rightCluster.implicitWidth, commandButton.implicitWidth)
                : rightCluster.implicitWidth + 4 + commandButton.implicitWidth
            implicitHeight: root.vertical
                ? rightCluster.implicitHeight + 4 + commandButton.implicitHeight
                : Math.max(rightCluster.implicitHeight, commandButton.implicitHeight)
            width: implicitWidth
            height: implicitHeight
            x: root.vertical ? (parent.width - width) / 2
                : parent.width - width - 6
            y: root.vertical ? parent.height - height - 6
                : (parent.height - height) / 2
            WidgetCluster {
                id: rightCluster
                clusterName: "right"
                x: root.vertical ? (parent.width - width) / 2 : 0
                y: root.vertical ? 0 : (parent.height - height) / 2
            }

            Commands {
                id: commandButton
                x: root.vertical ? (parent.width - width) / 2
                    : rightCluster.width + 4
                y: root.vertical ? rightCluster.height + 4
                    : (parent.height - height) / 2
            }
        }
    }
}
