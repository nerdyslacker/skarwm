pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Popout {
    id: root

    property var outputs: []

    cardWidth: 330
    cardHeight: Math.max(100, content.implicitHeight + 2 * cardPadding)
    onVisibleChanged: if (visible) refresh()

    function refresh() {
        outputQuery.running = false
        outputQuery.running = true
    }

    function applyBrightness(output, percent) {
        if (output.backend === "backlight") {
            Quickshell.execDetached([
                "brightnessctl", "-d", output.name, "set",
                Math.round(percent) + "%"
            ])
        } else {
            const value = Math.max(0.1, Math.min(1, percent / 100))
            Quickshell.execDetached([
                "xrandr", "--output", output.name,
                "--brightness", String(value)
            ])
        }
    }

    function updateOutput(index, percent) {
        const next = outputs.slice()
        next[index] = {
            name: next[index].name,
            backend: next[index].backend,
            brightness: Math.round(percent)
        }
        outputs = next
    }

    Process {
        id: outputQuery
        // Hardware backlights provide real brightness control. XRandR remains
        // a fallback for external outputs that do not expose a sysfs device.
        command: ["sh", "-c",
            "brightnessctl -l -c backlight 2>/dev/null | " +
            "sed -n \"s/^Device '\\([^']*\\)'.*/\\1/p\" | " +
            "while IFS= read -r device; do " +
            "brightnessctl -m -d \"$device\" 2>/dev/null | sed 's/^/BACKLIGHT,/' ; " +
            "done; printf '%s\\n' '--XRANDR--'; " +
            "xrandr --current --verbose 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const hardware = []
                const randr = []
                let current = null
                let readingRandr = false
                for (const line of text.split("\n")) {
                    if (line === "--XRANDR--") {
                        readingRandr = true
                        continue
                    }
                    if (!readingRandr && line.startsWith("BACKLIGHT,")) {
                        const fields = line.split(",")
                        const percent = parseInt(fields[4])
                        if (fields.length >= 5 && !isNaN(percent)) {
                            hardware.push({
                                name: fields[1],
                                backend: "backlight",
                                brightness: percent
                            })
                        }
                        continue
                    }
                    if (!readingRandr)
                        continue
                    const connected = line.match(/^(\S+) connected(?:\s|$)/)
                    if (connected) {
                        if (current !== null)
                            randr.push(current)
                        current = {
                            name: connected[1],
                            backend: "xrandr",
                            brightness: 100
                        }
                        continue
                    }
                    if (current !== null) {
                        const level = line.match(/^\s*Brightness:\s*([0-9.]+)/)
                        if (level)
                            current.brightness = Math.round(Number(level[1]) * 100)
                    }
                }
                if (current !== null)
                    randr.push(current)

                // A sysfs backlight normally represents the eDP/LVDS panel.
                // Do not show that same panel twice, but retain other outputs.
                const external = hardware.length === 0 ? randr : randr.filter(
                    output => !/^(eDP|LVDS|DSI)/i.test(output.name))
                root.outputs = hardware.concat(external)
            }
        }
    }

    Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 9

        Row {
            spacing: 8
            Text {
                text: "󰃠"
                color: Theme.yellow
                font.family: Theme.fontFamily
                font.pixelSize: 18
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Display brightness"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 1
                font.bold: true
            }
        }

        Text {
            visible: root.outputs.length === 0
            text: "No connected displays found."
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }

        Repeater {
            model: root.outputs

            Column {
                id: outputControl
                required property var modelData
                required property int index
                width: content.width
                spacing: 2

                Text {
                    text: outputControl.modelData.backend === "backlight"
                        ? outputControl.modelData.name.replace(/_/g, " ")
                        : outputControl.modelData.name
                    color: Theme.brightBlack
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }
                TweakSlider {
                    width: parent.width
                    label: "brightness"
                    from: 10
                    to: 100
                    value: outputControl.modelData.brightness
                    suffix: "%"
                    applyFn: value => root.applyBrightness(
                        outputControl.modelData, value)
                    persistFn: value => {}
                    onCommitted: value => root.updateOutput(outputControl.index, value)
                }
            }
        }
    }
}
