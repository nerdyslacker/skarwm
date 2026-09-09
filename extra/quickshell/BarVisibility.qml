pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property var catalog: [
        { key: "launcher", label: "Launcher", icon: "󰀻", defaultCluster: "left" },
        { key: "tags", label: "Tags", icon: "󰓹", defaultCluster: "left" },
        { key: "layout", label: "Layout picker", icon: "󰙀", defaultCluster: "left" },
        { key: "title", label: "Window title", icon: "󰖯", defaultCluster: "center" },
        { key: "scratchpads", label: "Scratchpads", icon: "󰆍", defaultCluster: "center" },
        { key: "media", label: "Media", icon: "󰎈", defaultCluster: "right" },
        { key: "weather", label: "Weather", icon: "󰖐", defaultCluster: "right" },
        { key: "metrics", label: "System metrics", icon: "󰍛", defaultCluster: "right" },
        { key: "battery", label: "Battery", icon: "󰁹", defaultCluster: "right" },
        { key: "brightness", label: "Brightness", icon: "󰃠", defaultCluster: "right" },
        { key: "volume", label: "Audio", icon: "󰕾", defaultCluster: "right" },
        { key: "micIndicator", label: "Muted mic", icon: "󰍭", defaultCluster: "right" },
        { key: "network", label: "Network", icon: "󰤨", defaultCluster: "right" },
        { key: "keyboard", label: "Keyboard", icon: "󰌌", defaultCluster: "right" },
        { key: "clipboard", label: "Clipboard", icon: "󰅌", defaultCluster: "right" },
        { key: "tray", label: "System tray", icon: "󰔚", defaultCluster: "right" },
        { key: "notifications", label: "DND indicator", icon: "󰂛", defaultCluster: "right" },
        { key: "clock", label: "Clock", icon: "󰥔", defaultCluster: "right" },
        { key: "capsLock", label: "Caps Lock", icon: "󰘲", defaultCluster: "right" },
        { key: "screenshot", label: "Screenshot", icon: "󰻛", defaultCluster: "right" }
    ]
    readonly property var clusterNames: ["left", "center", "right"]
    readonly property var defaultClusters: ({
        left: ["launcher", "tags", "layout"],
        center: ["title", "scratchpads"],
        right: ["media", "weather", "metrics", "battery", "brightness",
                "volume", "micIndicator", "network", "keyboard", "clipboard",
                "tray", "notifications", "clock", "capsLock", "screenshot"]
    })
    readonly property var defaults: ({
        launcher: true,
        tags: true,
        layout: true,
        title: true,
        scratchpads: true,
        media: true,
        weather: true,
        metrics: true,
        battery: true,
        brightness: true,
        volume: true,
        micIndicator: true,
        network: true,
        keyboard: true,
        clipboard: true,
        tray: true,
        notifications: true,
        clock: true,
        capsLock: true,
        screenshot: true
    })
    property var widgets: defaults
    property var clusters: defaultClusters
    property bool showOnAllMonitors: true
    property string barPosition: "top"
    readonly property bool verticalBar: barPosition === "left"
        || barPosition === "right"

    function metadata(key) {
        for (const entry of catalog)
            if (entry.key === key) return entry
        return null
    }

    function cluster(name) {
        const value = clusters[name]
        return Array.isArray(value) ? value : []
    }

    function enabled(key) {
        return widgets[key] !== false
    }

    function setEnabled(key, enabled) {
        if (defaults[key] === undefined)
            return
        const next = ({})
        for (const name in defaults)
            next[name] = widgets[name] !== false
        next[key] = enabled
        widgets = next
        writeState(next, showOnAllMonitors, clusters)
    }

    function setShowOnAllMonitors(enabled) {
        showOnAllMonitors = enabled
        writeState(widgets, enabled, clusters)
    }

    function setBarPosition(position) {
        const next = ["top", "bottom", "left", "right"].indexOf(position) >= 0
            ? position : "top"
        if (barPosition === next)
            return
        barPosition = next
        writeState(widgets, showOnAllMonitors, clusters)
    }

    function moveWidget(key, targetCluster, targetIndex) {
        if (!metadata(key) || clusterNames.indexOf(targetCluster) < 0)
            return
        const next = ({ left: [], center: [], right: [] })
        let sourceCluster = ""
        let sourceIndex = -1
        for (const name of clusterNames) {
            const values = cluster(name)
            for (let i = 0; i < values.length; ++i) {
                const candidate = values[i]
                if (candidate === key) {
                    sourceCluster = name
                    sourceIndex = i
                }
                if (candidate !== key) next[name].push(candidate)
            }
        }
        let requested = Math.round(targetIndex)
        if (sourceCluster === targetCluster && requested > sourceIndex)
            requested--
        const index = Math.max(0, Math.min(next[targetCluster].length, requested))
        next[targetCluster].splice(index, 0, key)
        clusters = next
        writeState(widgets, showOnAllMonitors, next)
    }

    function normalizedClusters(savedClusters) {
        const next = ({ left: [], center: [], right: [] })
        const seen = ({})
        if (savedClusters && typeof savedClusters === "object") {
            for (const name of clusterNames) {
                const values = savedClusters[name]
                if (!Array.isArray(values)) continue
                for (const key of values) {
                    if (metadata(key) && !seen[key]) {
                        next[name].push(key)
                        seen[key] = true
                    }
                }
            }
        }
        // New widgets and old pre-layout state files retain the intended
        // defaults without disturbing any valid order already saved.
        for (const entry of catalog) {
            if (!seen[entry.key]) {
                next[entry.defaultCluster].push(entry.key)
                seen[entry.key] = true
            }
        }
        return next
    }

    function writeState(widgetState, showAll, clusterState) {
        const saved = ({
            showOnAllMonitors: showAll,
            clusters: clusterState,
            barPosition: root.barPosition
        })
        for (const name in defaults)
            saved[name] = widgetState[name] !== false
        stateFile.setText(JSON.stringify(saved) + "\n")
    }

    function isMainScreen(screen) {
        if (!screen || Quickshell.screens.length === 0)
            return true
        const main = Quickshell.screens[0]
        return screen === main || screen.name === main.name
    }

    function showOnScreen(screen) {
        return showOnAllMonitors || isMainScreen(screen)
    }

    FileView {
        id: stateFile
        path: Theme.stateDir + "/bar-widgets.json"
        watchChanges: true
        atomicWrites: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const saved = JSON.parse(text())
                const next = ({})
                for (const name in root.defaults)
                    next[name] = saved[name] !== false
                root.widgets = next
                root.clusters = root.normalizedClusters(saved.clusters)
                root.showOnAllMonitors = saved.showOnAllMonitors !== false
                root.barPosition = ["top", "bottom", "left", "right"]
                    .indexOf(saved.barPosition) >= 0 ? saved.barPosition : "top"
            } catch (error) {
                console.warn("bar visibility settings:", error)
            }
        }
    }
}
