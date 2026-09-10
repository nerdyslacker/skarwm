pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Persistent placement for StatusNotifier items. IDs come from the SNI
// protocol and remain stable when an application recreates its tray item.
Singleton {
    id: root

    property var hiddenIds: []
    property bool ready: false

    function itemKey(item) {
        if (!item)
            return ""
        const id = String(item.id ?? "")
        if (id !== "")
            return "id:" + id
        return "title:" + String(item.title ?? "")
    }

    function isHidden(item) {
        return hiddenIds.indexOf(itemKey(item)) !== -1
    }

    function setHidden(item, hidden) {
        const key = itemKey(item)
        if (key === "")
            return
        const next = hiddenIds.slice()
        const index = next.indexOf(key)
        if (hidden && index === -1)
            next.push(key)
        else if (!hidden && index !== -1)
            next.splice(index, 1)
        else
            return
        hiddenIds = next
        stateFile.setText(JSON.stringify(next) + "\n")
    }

    FileView {
        id: stateFile
        path: Theme.stateDir + "/tray-hidden.json"
        watchChanges: true
        atomicWrites: true
        onFileChanged: reload()
        onLoadFailed: root.ready = true
        onLoaded: {
            try {
                const saved = JSON.parse(text())
                root.hiddenIds = Array.isArray(saved)
                    ? saved.filter(value => typeof value === "string") : []
            } catch (error) {
                console.warn("tray hidden items:", error)
                root.hiddenIds = []
            }
            root.ready = true
        }
    }
}
