pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Shared XKB state for every bar instance. Configuration is applied with
// setxkbmap; xkb-switch supplies the active group that setxkbmap cannot query.
Singleton {
    id: root

    property string layoutsCsv: "us"
    property string variantsCsv: ""
    property string optionsCsv: ""
    property string currentSpec: ""
    property bool switcherAvailable: false
    property bool configLoaded: false
    property var availableLayouts: []
    property string rulesListPath: "/usr/share/X11/xkb/rules/evdev.lst"

    readonly property var layouts: splitCsv(layoutsCsv).filter(value => value !== "")
    readonly property var variants: splitCsv(variantsCsv)
    readonly property string currentLayout: {
        const value = currentSpec.replace(/\([^)]*\)$/, "")
        return value !== "" ? value : (layouts.length > 0 ? layouts[0] : "?")
    }
    readonly property string groupOption: {
        for (const option of splitCsv(optionsCsv)) {
            if (option.startsWith("grp:"))
                return option
        }
        return ""
    }

    function splitCsv(value) {
        return String(value ?? "").split(",").map(part => part.trim())
    }

    function groupSpec(index) {
        const layout = layouts[index] ?? ""
        const variant = variants[index] ?? ""
        return variant === "" ? layout : layout + "(" + variant + ")"
    }

    function layoutName(code) {
        for (const layout of availableLayouts) {
            if (layout.code === code)
                return layout.name
        }
        return String(code).toUpperCase()
    }

    function parseLayoutCatalogue(contents) {
        const result = []
        let inLayouts = false
        for (const line of contents.split("\n")) {
            if (line.match(/^!\s+layout\s*$/)) {
                inLayouts = true
                continue
            }
            if (line.startsWith("!")) {
                if (inLayouts)
                    break
                continue
            }
            if (!inLayouts)
                continue
            const match = line.match(/^\s+(\S+)\s+(.+?)\s*$/)
            if (match)
                result.push({ code: match[1], name: match[2] })
        }
        availableLayouts = result
    }

    function refreshConfiguration() {
        if (!queryProcess.running)
            queryProcess.running = true
    }

    function refreshCurrent() {
        if (switcherAvailable && !currentProcess.running)
            currentProcess.running = true
    }

    function applyCurrentConfiguration() {
        if (layouts.length === 0)
            return

        const command = ["setxkbmap", "-layout", layoutsCsv,
                         "-variant", variantsCsv, "-option", ""]
        for (const option of splitCsv(optionsCsv)) {
            if (option !== "")
                command.push("-option", option)
        }
        applyProcess.command = command
        applyProcess.running = true
    }

    function saveConfiguration(layoutText, variantText, selectedGroupOption) {
        const cleanLayouts = splitCsv(layoutText).filter(value => value !== "")
        if (cleanLayouts.length === 0)
            return false

        layoutsCsv = cleanLayouts.join(",")
        variantsCsv = splitCsv(variantText).slice(0, cleanLayouts.length).join(",")

        const options = splitCsv(optionsCsv).filter(option =>
            option !== "" && !option.startsWith("grp:"))
        const group = String(selectedGroupOption ?? "").trim()
        if (group !== "")
            options.push(group)
        optionsCsv = options.join(",")

        stateFile.setText(JSON.stringify({
            layouts: layoutsCsv,
            variants: variantsCsv,
            options: optionsCsv
        }) + "\n")
        applyCurrentConfiguration()
        return true
    }

    function switchTo(index) {
        if (index < 0 || index >= layouts.length || !switcherAvailable)
            return
        currentSpec = groupSpec(index)
        switchProcess.command = ["xkb-switch", "-s", currentSpec]
        switchProcess.running = true
    }

    FileView {
        id: stateFile
        path: Theme.stateDir + "/keyboard-layout.json"
        watchChanges: true
        atomicWrites: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const saved = JSON.parse(text())
                const configuredLayouts = String(saved.layouts ?? "").trim()
                if (configuredLayouts === "")
                    throw new Error("empty keyboard layout list")
                root.layoutsCsv = configuredLayouts
                root.variantsCsv = String(saved.variants ?? "")
                root.optionsCsv = String(saved.options ?? "")
                if (!root.configLoaded) {
                    root.configLoaded = true
                    root.applyCurrentConfiguration()
                }
            } catch (error) {
                if (!root.configLoaded) {
                    root.configLoaded = true
                    root.refreshConfiguration()
                }
            }
        }
        onLoadFailed: {
            if (!root.configLoaded) {
                root.configLoaded = true
                root.refreshConfiguration()
            }
        }
    }

    FileView {
        path: root.rulesListPath
        onLoaded: root.parseLayoutCatalogue(text())
        onLoadFailed: {
            if (root.rulesListPath.endsWith("/evdev.lst"))
                root.rulesListPath = "/usr/share/X11/xkb/rules/base.lst"
            else
                root.availableLayouts = []
        }
    }

    Process {
        id: queryProcess
        command: ["setxkbmap", "-query"]
        stdout: StdioCollector {
            onStreamFinished: {
                const values = ({})
                for (const line of text.split("\n")) {
                    const match = line.match(/^\s*(layout|variant|options):\s*(.*)$/)
                    if (match)
                        values[match[1]] = match[2].trim()
                }
                if ((values.layout ?? "") !== "")
                    root.layoutsCsv = values.layout
                root.variantsCsv = values.variant ?? ""
                root.optionsCsv = values.options ?? ""
            }
        }
        onRunningChanged: if (!running) root.refreshCurrent()
    }

    Process {
        id: applyProcess
        onRunningChanged: {
            if (!running) {
                root.refreshConfiguration()
                currentRefreshDelay.restart()
            }
        }
    }

    Process {
        id: switcherProbe
        command: ["sh", "-c", "command -v xkb-switch 2>/dev/null"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                root.switcherAvailable = text.trim() !== ""
                if (root.switcherAvailable)
                    root.refreshCurrent()
            }
        }
    }

    Process {
        id: currentProcess
        command: ["xkb-switch", "-p"]
        stdout: StdioCollector {
            onStreamFinished: {
                const value = text.trim()
                if (value !== "")
                    root.currentSpec = value
            }
        }
    }

    Process {
        id: switchProcess
        onRunningChanged: if (!running) currentRefreshDelay.restart()
    }

    Timer {
        id: currentRefreshDelay
        interval: 100
        onTriggered: root.refreshCurrent()
    }

    Timer {
        interval: 750
        repeat: true
        running: root.switcherAvailable
        onTriggered: root.refreshCurrent()
    }
}
