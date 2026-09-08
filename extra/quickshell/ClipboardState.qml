pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// clipmenud monitors and stores CLIPBOARD changes. The helper asks clipmenu to
// render its normal launcher stream, keeping this QML independent of the
// daemon's private on-disk format.
Singleton {
    id: root

    property var entries: []
    property bool available: false
    property bool busy: false
    property string errorMessage: ""
    property string rawHistory: ""

    signal popupRequested()

    function helperCommand(action) {
        return "helper=${SKARWM_EXTRA_DIR:-$HOME/.config/skarwm}/scripts/clipboard-history; "
            + "exec \"$helper\" " + action
    }

    function parseHistory(raw) {
        const parsed = []
        const rows = raw.split("\n")
        for (const row of rows) {
            if (row === "")
                continue

            // clipmenu v7 prefixes stable list indexes; v6 emits only the
            // preview. Selection uses display order, so both formats work.
            let preview = row.replace(/^\[\s*\d+\]\s+/, "")
            let lineCount = 1
            const countMatch = preview.match(/ \((\d+) lines\)$/)
            if (countMatch) {
                lineCount = Number(countMatch[1])
                preview = preview.slice(0, preview.length - countMatch[0].length)
            }
            parsed.push({
                row: parsed.length,
                text: preview,
                lineCount: lineCount
            })
        }
        entries = parsed
    }

    function refresh() {
        if (available && !busy && !listProcess.running) {
            busy = true
            listProcess.running = true
        }
    }

    function clear() {
        if (!available || busy)
            return
        busy = true
        clearProcess.running = true
    }

    IpcHandler {
        target: "clipboard"
        // "show" collides with the qs ipc inspection subcommand in
        // Quickshell 0.3. Keep the callable name unambiguous.
        function toggle(): void { root.popupRequested() }
    }

    Process {
        id: toolProbe
        command: ["sh", "-c",
            "command -v clipmenu >/dev/null 2>&1 "
            + "&& command -v clipmenud >/dev/null 2>&1 "
            + "&& command -v clipdel >/dev/null 2>&1"]
        running: true
        onExited: exitCode => {
            root.available = exitCode === 0
            if (root.available)
                root.refresh()
            else
                root.errorMessage = "Install clipmenu to enable clipboard history."
        }
    }

    Process {
        id: listProcess
        command: ["sh", "-c", root.helperCommand("list")]
        stderr: StdioCollector {}
        stdout: StdioCollector {
            onStreamFinished: {
                if (text !== root.rawHistory) {
                    root.rawHistory = text
                    root.parseHistory(text)
                }
                root.errorMessage = ""
            }
        }
        onExited: exitCode => {
            root.busy = false
            if (exitCode !== 0)
                root.errorMessage = "clipmenud is not running yet."
        }
    }

    Process {
        id: clearProcess
        command: ["sh", "-c", root.helperCommand("clear")]
        stderr: StdioCollector {}
        onExited: exitCode => {
            root.busy = false
            if (exitCode !== 0) {
                root.errorMessage = "Could not clear clipboard history."
            } else {
                root.entries = []
                root.errorMessage = ""
            }
            root.rawHistory = ""
            root.refresh()
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.available
        onTriggered: root.refresh()
    }
}
