pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Lightweight system metrics: cpu/mem/disk on a 3s tick, network on 10s.
Singleton {
    id: root

    property real cpu: 0
    property real mem: 0
    property real disk: 0
    property bool hasBattery: false
    property real battery: 0
    property bool batteryCharging: false
    property string netName: ""
    property string netType: ""
    property bool vpnOn: false
    property string vpnName: ""

    readonly property string netIcon: vpnOn ? "󰦝"
                                    : netType.indexOf("wireless") !== -1 ? "󰤨"
                                    : netType.indexOf("ethernet") !== -1 ? "󰈀"
                                    : "󰤭"
    readonly property bool online: netName !== ""

    property var _prev: ({ idle: 0, total: 0 })

    Timer {
        interval: 3000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: statProc.running = true
    }

    Process {
        id: statProc
        command: ["sh", "-c",
            "head -1 /proc/stat; grep -E '^(MemTotal|MemAvailable)' /proc/meminfo; df --output=pcent / | tail -1; " +
            "for b in /sys/class/power_supply/BAT*; do [ -r \"$b/capacity\" ] && echo \"BAT $(cat \"$b/capacity\") $(cat \"$b/status\")\" && break; done; true"]
        stdout: StdioCollector {
            onStreamFinished: root.parseStat(text)
        }
    }

    function parseStat(t) {
        const lines = t.trim().split("\n")
        let memTotal = 0, memAvail = 0, foundBattery = false
        for (const line of lines) {
            if (line.startsWith("cpu ")) {
                const f = line.trim().split(/\s+/).slice(1).map(Number)
                const idle = f[3] + (f[4] || 0)
                const total = f.reduce((a, b) => a + b, 0)
                const dIdle = idle - _prev.idle
                const dTotal = total - _prev.total
                if (_prev.total > 0 && dTotal > 0)
                    cpu = Math.max(0, Math.min(100, 100 * (1 - dIdle / dTotal)))
                _prev = { idle: idle, total: total }
            } else if (line.startsWith("MemTotal:")) {
                memTotal = parseInt(line.split(/\s+/)[1])
            } else if (line.startsWith("MemAvailable:")) {
                memAvail = parseInt(line.split(/\s+/)[1])
            } else if (line.startsWith("BAT ")) {
                const parts = line.split(/\s+/)
                foundBattery = true
                battery = parseInt(parts[1])
                batteryCharging = parts[2] === "Charging"
            } else if (line.indexOf("%") !== -1) {
                disk = parseInt(line)
            }
        }
        if (memTotal > 0)
            mem = 100 * (1 - memAvail / memTotal)
        hasBattery = foundBattery
    }

    property bool capsOn: false
    property bool dndOn: false
    property bool dndTarget: false

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshIndicators()
    }

    function restartQuery(proc) {
        proc.running = false
        proc.running = true
    }

    function refreshIndicators() {
        restartQuery(capsProc)
        restartQuery(dndProc)
    }

    Process {
        id: capsProc
        command: ["sh", "-c", "xset q 2>/dev/null | awk '/Caps Lock/{print $4}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                const state = text.trim()
                if (state === "on" || state === "off")
                    root.capsOn = state === "on"
            }
        }
    }

    Process {
        id: dndProc
        command: ["sh", "-c", "dunstctl is-paused 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const state = text.trim()
                if (state === "true" || state === "false")
                    root.dndOn = state === "true"
            }
        }
    }

    Timer {
        id: dndRefresh
        interval: 300
        onTriggered: root.refreshIndicators()
    }

    Process {
        id: dndToggleProc
        stdout: StdioCollector {
            onStreamFinished: {
                const state = text.trim()
                if (state === "true" || state === "false")
                    root.dndOn = state === "true"
            }
        }
        onExited: root.restartQuery(dndProc)
    }

    function toggleDnd() {
        dndTarget = !dndOn
        dndToggleProc.running = false
        dndToggleProc.command = ["sh", "-c",
            "dunstctl set-paused " + (dndTarget ? "true" : "false") +
            " 2>/dev/null && dunstctl is-paused 2>/dev/null"]
        dndToggleProc.running = true
    }
    function popNotification() {
        // replaying must always show something: leave DND first, and say so
        // when the history is empty instead of silently doing nothing
        Quickshell.execDetached(["sh", "-c",
            "dunstctl set-paused false; " +
            "if [ \"$(dunstctl count history)\" -eq 0 ]; then " +
            "notify-send -a dunst -t 2000 'Notifications' 'History is empty'; " +
            "else dunstctl history-pop; fi"])
        dndRefresh.restart()
    }

    Timer {
        interval: 10000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: netProc.running = true
    }

    // primary transport + vpn tracked separately: a vpn/wireguard/tun
    // connection rides ON a transport, it isn't one
    Process {
        id: netProc
        command: ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show", "--active"]
        stdout: StdioCollector {
            onStreamFinished: {
                let name = "", type = "", vName = "", vOn = false
                for (const line of text.trim().split("\n")) {
                    const i = line.lastIndexOf(":")
                    if (i <= 0)
                        continue
                    const n = line.slice(0, i), t = line.slice(i + 1)
                    if (t === "loopback")
                        continue
                    if (t === "vpn" || t === "wireguard" || t === "tun") {
                        vOn = true
                        vName = n
                    } else if (name === "") {
                        name = n
                        type = t
                    }
                }
                root.netName = name
                root.netType = type
                root.vpnOn = vOn
                root.vpnName = vName
            }
        }
    }
}
