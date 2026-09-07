pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// skarwm state/control adapter. Its reusable public properties keep visual
// modules independent of the wire protocol.
Singleton {
    id: root

    property var workspaces: []
    property var windows: []
    property int tagCount: 12
    property string title: ""
    property string activeWinId: ""
    readonly property string msgPath: "skarwm-msg"

    function openLauncher() {
        Quickshell.execDetached(["rofi", "-show", "drun", "-modi", "drun",
            "-show-icons", "-theme", Theme.configDir + "/rofi/config.rasi"])
    }

    function workspaceAt(index) {
        const id = index + 1
        for (const ws of workspaces)
            if (ws.id === id) return ws
        return null
    }
    function isSelected(index) {
        const ws = workspaceAt(index)
        return ws !== null && ws.focused
    }
    function isOccupied(index) {
        const ws = workspaceAt(index)
        return ws !== null && ws.windows > 0
    }
    function isUrgent(index) {
        const ws = workspaceAt(index)
        return ws !== null && ws.urgent
    }

    function refreshWorkspaces() {
        workspaceQuery.running = false
        workspaceQuery.running = true
    }
    function refreshWindows() {
        windowQuery.running = false
        windowQuery.running = true
    }
    function refreshAll() {
        refreshWorkspaces()
        refreshWindows()
    }

    function acceptWorkspaces(line) {
        try {
            const value = JSON.parse(line)
            if (!Array.isArray(value)) return
            workspaces = value
            let highest = 1
            for (const ws of value) highest = Math.max(highest, ws.id)
            tagCount = Math.max(9, highest)
        } catch (e) {
            console.warn("skarwm workspace snapshot:", e)
        }
    }

    function acceptWindows(line) {
        try {
            const value = JSON.parse(line)
            if (!value || !Array.isArray(value.windows)) return
            windows = value.windows
            let focused = null
            for (const win of windows) {
                if (win.focused && !win.dock) { focused = win; break }
            }
            activeWinId = focused ? "0x" + Number(focused.id).toString(16) : ""
            title = focused ? focused.title : ""
        } catch (e) {
            console.warn("skarwm window snapshot:", e)
        }
    }

    Process {
        id: workspaceQuery
        command: [root.msgPath, "get-workspaces"]
        running: true
        stdout: SplitParser { onRead: line => root.acceptWorkspaces(line) }
    }
    Process {
        id: windowQuery
        command: [root.msgPath, "get-windows"]
        running: true
        stdout: SplitParser { onRead: line => root.acceptWindows(line) }
    }
    Process {
        command: [root.msgPath, "subscribe", "workspace", "window", "output"]
        running: true
        stdout: SplitParser {
            onRead: line => {
                // The first line is the subscription acknowledgement. Every
                // later event is a cheap invalidation signal; snapshots keep
                // the QML model deterministic even after event bursts.
                try {
                    const event = JSON.parse(line)
                    if (event && event.change !== undefined) root.refreshAll()
                } catch (e) {
                    console.warn("skarwm event:", e)
                }
            }
        }
    }

    function viewTag(index) {
        Quickshell.execDetached([msgPath, "workspace", String(index + 1)])
    }
    function toggleViewTag(index) { viewTag(index) }
    function sendToTag(index) {
        Quickshell.execDetached([msgPath, "move", "workspace", String(index + 1)])
    }
    function cycleTag(direction) {
        Quickshell.execDetached([msgPath, "workspace", direction > 0 ? "next" : "prev"])
    }
}
