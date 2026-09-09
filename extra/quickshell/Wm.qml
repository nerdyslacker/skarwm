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
    property var registeredScratchpads: []
    // Highest workspace currently reported by skarwm. Tags.qml combines this
    // with the user's configured minimum, ensuring an active high tag remains
    // reachable without forcing the configured count back to nine.
    property int tagCount: 1
    property string title: ""
    property string activeWinId: ""
    readonly property string msgPath: "skarwm-msg"

    readonly property var layouts: [
        { name: "Tiling", glyph: "󰙀", command: "tiling" },
        { name: "Tabbed", glyph: "󰓩", command: "tabbed" },
        { name: "Floating", glyph: "󰕰", command: "floating" }
    ]
    readonly property var focusedWindow: {
        for (const win of windows)
            if (win.focused && !win.dock) return win
        return null
    }
    readonly property int layoutIndex: focusedWindow?.floating === true ? 2
        : focusedWindow?.column_layout === "tabbed" ? 1 : 0
    property int gaps: 8

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
            tagCount = Math.max(1, highest)
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
            const scratchpads = []
            for (const win of windows) {
                if (win.focused && !win.dock) { focused = win; break }
            }
            for (const win of windows) {
                const registers = Array.isArray(win.scratchpad_registers)
                    ? win.scratchpad_registers
                    : win.scratchpad_register === null || win.scratchpad_register === undefined
                        ? [] : [win.scratchpad_register]
                for (const register of registers) {
                    scratchpads.push({
                        register: Number(register),
                        id: win.id,
                        title: win.title || win.class || win.instance || "Untitled window",
                        className: win.class || win.instance || "",
                        hidden: win.scratchpad === true,
                        workspace: win.workspace,
                        output: win.output
                    })
                }
            }
            scratchpads.sort((a, b) => a.register - b.register)
            registeredScratchpads = scratchpads
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
    function setLayout(index) {
        const layout = layouts[index]
        if (layout)
            Quickshell.execDetached([msgPath, "layout", layout.command])
    }
    function cycleLayout(direction) {
        setLayout((layoutIndex + direction + layouts.length) % layouts.length)
    }
    function setGaps(value, persist) {
        const next = Math.min(40, Math.max(0, Math.round(value)))
        gaps = next
        Quickshell.execDetached([msgPath, "gaps", String(next)])
        if (persist !== false)
            gapState.setText(String(next) + "\n")
    }
    function persistGaps(value) {
        const next = Math.min(40, Math.max(0, Math.round(value)))
        gaps = next
        gapState.setText(String(next) + "\n")
    }
    function toggleScratchpad(register) {
        Quickshell.execDetached([msgPath, "scratchpad", "toggle", String(register)])
    }

    FileView {
        id: gapState
        path: Theme.stateDir + "/window-gap"
        watchChanges: true
        atomicWrites: true
        onFileChanged: reload()
        onLoaded: {
            const saved = parseInt(text())
            if (!isNaN(saved)) {
                root.gaps = Math.min(40, Math.max(0, saved))
                restoreGap.restart()
            }
        }
    }

    Timer {
        id: restoreGap
        interval: 150
        onTriggered: Quickshell.execDetached(
            [root.msgPath, "gaps", String(root.gaps)])
    }
}
