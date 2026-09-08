pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property var defaults: ({
        launcher: true,
        tags: true,
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
        stateFile.setText(JSON.stringify(next) + "\n")
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
            } catch (error) {
                console.warn("bar visibility settings:", error)
            }
        }
    }
}
