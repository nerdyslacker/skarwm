pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Canonical Srcery palette from SRCERY.md. Semantic colors used by the
// modules below are aliases of this palette, so every component stays in
// the same theme without depending on another desktop configuration.
Singleton {
    id: root

    // config root = parent of the running quickshell directory
    readonly property string configDir: {
        let sd = String(Quickshell.shellDir ?? "")
        if (sd.startsWith("file://"))
            sd = sd.slice(7)
        return sd.substring(0, sd.lastIndexOf("/"))
    }

    property int barHeight: 34
    property real barUserScale: 1.0

    property int _barStateLoads: 0
    readonly property bool barStateReady: _barStateLoads >= 2
    Timer {
        running: !root.barStateReady
        interval: 1000
        onTriggered: root._barStateLoads = 2
    }

    readonly property color black: "#121110"
    readonly property color red: "#EF2F27"
    readonly property color green: "#519F50"
    readonly property color yellow: "#FBB829"
    readonly property color blue: "#2C78BF"
    readonly property color magenta: "#E02C6D"
    readonly property color cyan: "#0AAEB3"
    readonly property color white: "#C5B088"

    readonly property color brightBlack: "#917E6B"
    readonly property color brightRed: "#F75341"
    readonly property color brightGreen: "#98BC37"
    readonly property color brightYellow: "#FED06E"
    readonly property color brightBlue: "#68A8E4"
    readonly property color brightMagenta: "#FF5C8F"
    readonly property color brightCyan: "#2BE4D0"
    readonly property color brightWhite: "#FCE8C3"

    readonly property color darkGreen: "#294229"
    readonly property color darkRed: "#4F2321"
    readonly property color darkBlue: "#1E5181"
    readonly property color dimGreen: "#2E5C2E"
    readonly property color orange: "#FF5F00"
    readonly property color brightOrange: "#FF8700"
    readonly property color teal: "#008080"
    readonly property color gray1: "#1C1B19"
    readonly property color gray2: "#262522"
    readonly property color gray3: "#312F2C"
    readonly property color gray4: "#3B3935"
    readonly property color gray5: "#45433E"
    readonly property color gray6: "#504D47"
    readonly property color hardBlack: "#0E0D0C"

    readonly property color bg: black
    readonly property color altbg: gray2
    readonly property color fg: brightWhite
    readonly property color border: gray4
    readonly property color primary: orange
    readonly property color secondary: brightBlue
    readonly property color alert: red
    readonly property color disabled: gray6

    readonly property color accent: primary
    readonly property color selbg: primary
    readonly property color selfg: hardBlack

    readonly property string fontFamily: "JetBrainsMono Nerd Font"

    readonly property real barScale: barUserScale
    readonly property int fontSize: Math.round(12 * barScale)
    readonly property int iconSize: Math.round(15 * barScale)
    readonly property int moduleHeight: Math.round(28 * barScale)
    readonly property int effectiveBarHeight: Math.max(barHeight, moduleHeight)

    FileView {
        path: root.configDir + "/bar-height"
        watchChanges: true
        onFileChanged: reload()
        onLoadFailed: root._barStateLoads++
        onLoaded: {
            root._barStateLoads++
            const value = parseInt(text())
            if (!isNaN(value))
                root.barHeight = Math.min(Math.max(value, 28), 80)
        }
    }

    FileView {
        path: root.configDir + "/bar-scale"
        watchChanges: true
        onFileChanged: reload()
        onLoadFailed: root._barStateLoads++
        onLoaded: {
            root._barStateLoads++
            const value = parseFloat(text())
            if (!isNaN(value))
                root.barUserScale = Math.min(Math.max(value, 0.7), 2.0)
        }
    }
}
