pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property var defaults: ({
        launcher: true,
        tags: true,
        layout: true,
        title: true,
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
    property bool showOnAllMonitors: true

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
        writeState(next, showOnAllMonitors)
    }

    function setShowOnAllMonitors(enabled) {
        showOnAllMonitors = enabled
        writeState(widgets, enabled)
    }

    function writeState(widgetState, showAll) {
        const saved = ({ showOnAllMonitors: showAll })
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
                root.showOnAllMonitors = saved.showOnAllMonitors !== false
            } catch (error) {
                console.warn("bar visibility settings:", error)
            }
        }
    }
}
