pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import Quickshell.Io

// Network — a small connectivity front-end (nmcli + bluetoothctl
// underneath) in a popup anchored to the bar. Device status + wifi radio
// toggle up top, bluetooth power + paired devices, and a scannable wifi list
// below. Device/network rows expand to expose their actions; new secured wifi
// connections add an inline password field. "Pair new" handles PIN-less
// devices — anything needing a PIN is blueman's job. The bluetooth section
// only renders when an adapter exists.
Popout {
        id: win

        cardWidth: 430
        cardHeight: 640

        onVisibleChanged: {
            if (visible)
                refresh(false)
            else {
                pwFor = ""
                expandedWifi = ""
                expandedBluetooth = ""
            }
        }

        property var devices: []    // {dev, type, state, conn}
        property bool wifiOn: false
        property var nets: []       // {inUse, signal, security, ssid}
        property var savedWifi: []  // saved connection names
        property bool scanning: false
        property bool busy: false
        property string status: ""
        property string pwFor: ""   // ssid currently asking for a password
        property string expandedWifi: ""

        readonly property string wifiDev: {
            for (const d of devices)
                if (d.type === "wifi") return d.dev
            return ""
        }

        property bool btPresent: false
        property bool btOn: false
        property var btDevices: []  // {mac, name, connected}
        property var btFound: []    // {mac, name} — unpaired, from a scan
        property bool btScanning: false
        property string expandedBluetooth: ""

        function refresh(rescan) {
            devProc.running = true
            radioProc.running = true
            savedProc.running = true
            btShowProc.running = true
            btDevsProc.running = true
            scanning = true
            scanProc.command = ["sh", "-c",
                "nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID dev wifi list --rescan "
                + (rescan ? "yes" : "no")]
            scanProc.running = true
        }

        function connectTo(net) {
            if (net.inUse) {
                run(["nmcli", "d", "disconnect", wifiDev], "disconnecting…")
            } else if (savedWifi.indexOf(net.ssid) !== -1) {
                run(["nmcli", "c", "up", "id", net.ssid], "connecting to " + net.ssid + "…")
            } else if (net.security === "" || net.security === "--") {
                run(["nmcli", "dev", "wifi", "connect", net.ssid],
                    "connecting to " + net.ssid + "…")
            } else {
                pwFor = net.ssid
            }
        }

        function connectPw(ssid, pw) {
            pwFor = ""
            run(["nmcli", "dev", "wifi", "connect", ssid, "password", pw],
                "connecting to " + ssid + "…")
        }

        property var _err: []
        function run(cmd, msg) {
            if (busy)
                return
            statusClear.stop()
            busy = true
            status = msg
            _err = []
            actProc.command = cmd
            actProc.running = true
        }

        Process {
            id: actProc
            stderr: SplitParser {
                onRead: line => { if (line.trim() !== "") win._err.push(line.trim()) }
            }
            onExited: code => {
                win.busy = false
                win.status = code === 0 ? "done"
                    : (win._err.length ? win._err[win._err.length - 1] : "failed")
                win.refresh(false)
                statusClear.restart()
            }
        }

        Timer {
            id: statusClear
            interval: 5000
            onTriggered: {
                if (!win.busy)
                    win.status = ""
            }
        }

        // --- state readers (accumulate lines, publish on exit) ---

        property var _devs: []
        Process {
            id: devProc
            command: ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "d"]
            stdout: SplitParser {
                onRead: line => {
                    const p = line.split(":")
                    if (p.length >= 3 && (p[1] === "ethernet" || p[1] === "wifi"))
                        win._devs.push({ dev: p[0], type: p[1], state: p[2],
                                         conn: p.slice(3).join(":") })
                }
            }
            onRunningChanged: {
                if (running) win._devs = []
                else win.devices = win._devs
            }
        }

        Process {
            id: radioProc
            command: ["nmcli", "radio", "wifi"]
            stdout: SplitParser {
                onRead: line => win.wifiOn = (line.trim() === "enabled")
            }
        }

        property var vpns: []   // {name, active}
        property var _saved: []
        property var _vpns: []
        Process {
            id: savedProc
            command: ["nmcli", "-t", "-f", "NAME,TYPE,ACTIVE", "c", "show"]
            stdout: SplitParser {
                onRead: line => {
                    const p = line.split(":")
                    if (p.length < 3)
                        return
                    const active = p[p.length - 1] === "yes"
                    const type = p[p.length - 2]
                    const name = p.slice(0, p.length - 2).join(":")
                    if (type.indexOf("wireless") !== -1)
                        win._saved.push(name)
                    else if (type === "vpn" || type === "wireguard")
                        win._vpns.push({ name: name, active: active,
                                         external: false })
                    // a "tun" connection is an auto-generated profile for an
                    // externally managed device (tailscale etc.): shown, but
                    // read-only — nmcli can down it but never bring it back
                    else if (type === "tun")
                        win._vpns.push({ name: name, active: active,
                                         external: true })
                }
            }
            onRunningChanged: {
                if (running) {
                    win._saved = []
                    win._vpns = []
                } else {
                    win.savedWifi = win._saved
                    win.vpns = win._vpns
                }
            }
        }

        property var _nets: []
        Process {
            id: scanProc
            stdout: SplitParser {
                onRead: line => {
                    const p = line.split(":")
                    if (p.length < 4)
                        return
                    const ssid = p.slice(3).join(":").replace(/\\:/g, ":")
                    if (ssid === "")
                        return
                    win._nets.push({ inUse: p[0] === "*", signal: parseInt(p[1]) || 0,
                                     security: p[2], ssid: ssid })
                }
            }
            onRunningChanged: {
                if (running) {
                    win._nets = []
                } else {
                    // dedup by ssid, keep strongest AP
                    const best = {}
                    for (const n of win._nets)
                        if (!best[n.ssid] || n.signal > best[n.ssid].signal
                            || n.inUse)
                            best[n.ssid] = n
                    win.nets = Object.values(best)
                        .sort((a, b) => (b.inUse - a.inUse) || (b.signal - a.signal))
                    win.scanning = false
                }
            }
        }

        function sigGlyph(s) {
            return s < 20 ? "󰤯" : s < 45 ? "󰤟" : s < 70 ? "󰤢" : s < 88 ? "󰤥" : "󰤨"
        }

        // --- live per-device throughput (only while the window is open) ---

        property var _netPrev: ({})
        property var netRates: ({})   // {dev: {down, up}} in bytes/s

        Timer {
            interval: 1000
            running: win.visible
            repeat: true
            onTriggered: speedProc.running = true
        }
        Process {
            id: speedProc
            command: ["cat", "/proc/net/dev"]
            stdout: StdioCollector {
                onStreamFinished: {
                    const now = Date.now()
                    const prev = win._netPrev
                    const next = {}
                    const rates = {}
                    for (const line of text.split("\n")) {
                        const m = line.trim().match(/^(\S+):\s*(.*)$/)
                        if (!m || m[1] === "lo")
                            continue
                        const f = m[2].trim().split(/\s+/)
                        const rx = parseInt(f[0]) || 0
                        const tx = parseInt(f[8]) || 0
                        next[m[1]] = { rx: rx, tx: tx, t: now }
                        if (prev[m[1]]) {
                            const dt = (now - prev[m[1]].t) / 1000
                            if (dt > 0)
                                rates[m[1]] = {
                                    down: Math.max(0, (rx - prev[m[1]].rx) / dt),
                                    up: Math.max(0, (tx - prev[m[1]].tx) / dt) }
                        }
                    }
                    win._netPrev = next
                    win.netRates = rates
                }
            }
        }

        function fmtRate(b) {
            return b < 1024 ? Math.round(b) + " B/s"
                 : b < 1048576 ? (b / 1024).toFixed(b < 102400 ? 1 : 0) + " K/s"
                 : (b / 1048576).toFixed(1) + " M/s"
        }
        // keyed by interface name — vpn rows match only when the profile
        // name IS the device (tun/tailscale0), which is exactly right
        function rateText(dev) {
            const r = netRates[dev]
            return r ? "↓ " + fmtRate(r.down) + "  ↑ " + fmtRate(r.up) : ""
        }

        // --- bluetooth (bluetoothctl underneath) ---

        Process {
            id: btShowProc
            command: ["sh", "-c", "bluetoothctl show 2>/dev/null"]
            property bool sawController: false
            stdout: SplitParser {
                onRead: line => {
                    if (line.indexOf("Controller ") === 0)
                        btShowProc.sawController = true
                    if (line.trim().indexOf("Powered:") === 0)
                        win.btOn = line.indexOf("yes") !== -1
                }
            }
            onRunningChanged: {
                if (running) sawController = false
                else {
                    win.btPresent = sawController
                    if (!sawController)
                        win.btOn = false
                    Sys.bluetoothOn = win.btPresent && win.btOn
                    if (!Sys.bluetoothOn)
                        Sys.bluetoothConnected = false
                }
            }
        }

        // "Device <mac> <name…>" lines; a === marker splits paired from
        // connected so one process covers both
        property var _btPaired: []
        property var _btConn: []
        property bool _btPastMark: false
        Process {
            id: btDevsProc
            command: ["sh", "-c",
                "bluetoothctl devices Paired 2>/dev/null; echo ===; " +
                "bluetoothctl devices Connected 2>/dev/null"]
            stdout: SplitParser {
                onRead: line => {
                    if (line.trim() === "===") { win._btPastMark = true; return }
                    const p = line.trim().split(" ")
                    if (p[0] !== "Device" || p.length < 3) return
                    const d = { mac: p[1], name: p.slice(2).join(" ") }
                    if (win._btPastMark) win._btConn.push(d.mac)
                    else win._btPaired.push(d)
                }
            }
            onRunningChanged: {
                if (running) {
                    win._btPaired = []
                    win._btConn = []
                    win._btPastMark = false
                } else {
                    win.btDevices = win._btPaired.map(d => ({
                        mac: d.mac, name: d.name,
                        connected: win._btConn.indexOf(d.mac) !== -1 }))
                    Sys.bluetoothConnected = win.btOn
                        && win._btConn.length > 0
                }
            }
        }

        // scan for new devices: discover for 8s, then list everything and
        // keep the named, unpaired ones (nameless MACs are noise)
        property var _btAll: []
        Process {
            id: btScanProc
            command: ["sh", "-c",
                "bluetoothctl --timeout 8 scan on >/dev/null 2>&1; " +
                "bluetoothctl devices 2>/dev/null"]
            stdout: SplitParser {
                onRead: line => {
                    const p = line.trim().split(" ")
                    if (p[0] === "Device" && p.length >= 3)
                        win._btAll.push({ mac: p[1], name: p.slice(2).join(" ") })
                }
            }
            onRunningChanged: {
                if (running) {
                    win._btAll = []
                } else {
                    const paired = win.btDevices.map(d => d.mac)
                    win.btFound = win._btAll.filter(d =>
                        paired.indexOf(d.mac) === -1
                        && !/^([0-9A-F]{2}-){5}[0-9A-F]{2}$/i.test(d.name))
                    win.btScanning = false
                }
            }
        }

        function btScan() {
            if (btScanning) return
            btScanning = true
            btFound = []
            btScanProc.running = true
        }

        function btToggleDevice(d) {
            run(["bluetoothctl", d.connected ? "disconnect" : "connect", d.mac],
                (d.connected ? "disconnecting " : "connecting ") + d.name + "…")
        }

        function btForgetDevice(d) {
            expandedBluetooth = ""
            run(["bluetoothctl", "remove", d.mac], "forgetting " + d.name + "…")
        }

        // PIN-less pair+trust+connect; devices that want a PIN fail here
        // and belong in blueman
        function btPairNew(d) {
            run(["sh", "-c", "bluetoothctl pair " + d.mac +
                 " && bluetoothctl trust " + d.mac +
                 " && bluetoothctl connect " + d.mac],
                "pairing " + d.name + "…")
            btFound = btFound.filter(f => f.mac !== d.mac)
        }

        component ActionButton: Rectangle {
            id: actionButton
            required property string buttonText
            property color accentColor: Theme.accent
            property bool filled: true
            signal activated()

            implicitWidth: actionLabel.implicitWidth + 24
            height: 28
            color: !enabled ? Theme.gray2
                : filled ? (actionMouse.containsMouse
                    ? Qt.lighter(accentColor, 1.12) : accentColor)
                : actionMouse.containsMouse ? Qt.alpha(accentColor, 0.20)
                : Qt.alpha(accentColor, 0.09)
            border.width: 1
            border.color: enabled ? accentColor : Theme.gray5
            Behavior on color { ColorAnimation { duration: 120 } }

            Text {
                id: actionLabel
                anchors.centerIn: parent
                text: actionButton.buttonText
                color: !actionButton.enabled ? Theme.disabled
                    : actionButton.filled ? Theme.selfg : actionButton.accentColor
                font.family: Theme.fontFamily
                font.pixelSize: 11
                font.bold: true
            }

            MouseArea {
                id: actionMouse
                anchors.fill: parent
                enabled: actionButton.enabled
                hoverEnabled: true
                onClicked: actionButton.activated()
            }
        }

        // --- UI ---

        Column {
            anchors.fill: parent
            spacing: 8

            // Escape: cancel an open password prompt first, close otherwise.
            // Keys on the content root, not a Shortcut (those never fire in
            // this window) — unhandled keys bubble up here from the focused
            // password field, and this holds focus the rest of the time.
            focus: true
            Keys.onEscapePressed: {
                if (win.pwFor !== "")
                    win.pwFor = ""
                else
                    win.visible = false
            }

            // header
            Item {
                width: parent.width
                height: 26

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Network"
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: 16
                    font.bold: true
                }

                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 84
                    height: 24
                    radius: 0
                    color: Qt.alpha(Theme.fg, scanMa.containsMouse ? 0.18 : 0.1)
                    Text {
                        anchors.centerIn: parent
                        text: win.scanning ? "scanning…" : "rescan"
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: scanMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: win.refresh(true)
                    }
                }
            }

            // devices
            Repeater {
                model: win.devices

                Rectangle {
                    id: devRow
                    required property var modelData
                    width: parent.width
                    height: 30
                    radius: 0
                    color: devRow.modelData.state === "connected"
                        ? Qt.alpha(Theme.accent, 0.16) : Theme.gray2
                    border.width: 1
                    border.color: Theme.gray5

                    Text {
                        id: devName
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: (devRow.modelData.type === "wifi" ? "󰖩  " : "󰈀  ")
                            + devRow.modelData.dev
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                    }

                    Text {
                        visible: devRow.modelData.state === "connected"
                        anchors.left: devName.right
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: win.rateText(devRow.modelData.dev)
                        color: Theme.disabled
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }

                    Text {
                        anchors.right: devRow.modelData.type === "wifi" ? radioPill.left : parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: devRow.modelData.state === "connected"
                            ? devRow.modelData.conn
                            : devRow.modelData.state
                        color: devRow.modelData.state === "connected"
                            ? Theme.green : Theme.disabled
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }

                    Rectangle {
                        id: radioPill
                        visible: devRow.modelData.type === "wifi"
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34
                        height: 18
                        radius: 0
                        color: win.wifiOn ? Theme.accent : Qt.alpha(Theme.fg, 0.15)
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: win.wifiOn ? parent.width - width - 2 : 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14
                            height: 14
                            radius: 0
                            color: win.wifiOn ? Theme.bg : Qt.alpha(Theme.fg, 0.7)
                            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: win.run(["nmcli", "radio", "wifi",
                                win.wifiOn ? "off" : "on"],
                                win.wifiOn ? "wifi off" : "wifi on")
                        }
                    }
                }
            }

            // VPN connections — shield row per saved vpn/wireguard profile
            Rectangle {
                visible: win.vpns.length > 0
                width: parent.width
                height: 1
                color: Qt.alpha(Theme.fg, 0.1)
            }

            Text {
                visible: win.vpns.length > 0
                text: "VPN"
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: 12
                font.bold: true
            }

            Repeater {
                model: win.vpns

                Rectangle {
                    id: vpnRow
                    required property var modelData
                    width: parent.width
                    height: 30
                    radius: 0
                    color: vpnRow.modelData.active
                        ? Qt.alpha(Theme.green, 0.14) : Theme.gray2
                    border.width: 1
                    border.color: Theme.gray5

                    Text {
                        id: vpnName
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰦝  " + vpnRow.modelData.name
                        color: vpnRow.modelData.active ? Theme.green : Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                    }

                    Text {
                        visible: vpnRow.modelData.active
                        anchors.left: vpnName.right
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: win.rateText(vpnRow.modelData.name)
                        color: Theme.disabled
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }

                    Text {
                        visible: vpnRow.modelData.external
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: vpnRow.modelData.active ? "on · external" : "external"
                        color: vpnRow.modelData.active ? Theme.green : Theme.disabled
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }

                    Rectangle {
                        visible: !vpnRow.modelData.external
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34
                        height: 18
                        radius: 0
                        color: vpnRow.modelData.active ? Theme.green : Qt.alpha(Theme.fg, 0.15)
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: vpnRow.modelData.active ? parent.width - width - 2 : 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14; height: 14; radius: 0
                            color: vpnRow.modelData.active ? Theme.bg : Qt.alpha(Theme.fg, 0.7)
                            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: win.run(["nmcli", "c",
                                vpnRow.modelData.active ? "down" : "up",
                                "id", vpnRow.modelData.name],
                                (vpnRow.modelData.active ? "disconnecting " : "connecting ")
                                + vpnRow.modelData.name + "…")
                        }
                    }
                }
            }

            // Bluetooth — hidden entirely on machines without an adapter
            Rectangle {
                visible: win.btPresent
                width: parent.width
                height: 1
                color: Qt.alpha(Theme.fg, 0.1)
            }

            Item {
                visible: win.btPresent
                width: parent.width
                height: 26

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Bluetooth"
                    color: Theme.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    font.bold: true
                }

                Rectangle {
                    visible: win.btOn
                    anchors.right: btPill.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 74
                    height: 24
                    radius: 0
                    color: Qt.alpha(Theme.fg, btScanMa.containsMouse ? 0.18 : 0.1)
                    Text {
                        anchors.centerIn: parent
                        text: win.btScanning ? "scanning…" : "pair new"
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: btScanMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: win.btScan()
                    }
                }

                Rectangle {
                    id: btPill
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 34
                    height: 18
                    radius: 0
                    color: win.btOn ? Theme.accent : Qt.alpha(Theme.fg, 0.15)
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Rectangle {
                        x: win.btOn ? parent.width - width - 2 : 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 14
                        height: 14
                        radius: 0
                        color: win.btOn ? Theme.bg : Qt.alpha(Theme.fg, 0.7)
                        Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: win.run(["bluetoothctl", "power",
                            win.btOn ? "off" : "on"],
                            win.btOn ? "bluetooth off" : "bluetooth on")
                    }
                }
            }

            Flickable {
                id: btListView
                visible: win.btPresent && win.btOn && btList.implicitHeight > 0
                width: parent.width
                height: Math.min(btList.implicitHeight, 150)
                contentWidth: width
                contentHeight: btList.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: btList
                    width: parent.width
                    spacing: 2

                    Repeater {
                        model: win.btDevices

                        Rectangle {
                            id: btRow
                            required property var modelData
                            readonly property bool expanded:
                                win.expandedBluetooth === modelData.mac
                            width: parent.width
                            height: 30 + (expanded ? 40 : 0)
                            clip: true
                            color: Theme.gray2
                            Behavior on height {
                                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                            }

                            Column {
                                anchors.fill: parent
                                spacing: 0

                                Rectangle {
                                    width: parent.width
                                    height: 30
                                    color: btRow.modelData.connected
                                        ? Qt.alpha(Theme.accent, 0.22)
                                        : btMa.containsMouse ? Theme.gray3 : Theme.gray2

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.right: btState.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "󰂯  " + btRow.modelData.name
                                        color: btRow.modelData.connected
                                            ? Theme.accent : Theme.fg
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 12
                                        font.bold: btRow.modelData.connected
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        id: btState
                                        anchors.right: parent.right
                                        anchors.rightMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: (btRow.modelData.connected
                                            ? "connected" : "paired")
                                            + (btRow.expanded ? "  󰅀" : "  󰅂")
                                        color: btRow.modelData.connected
                                            ? Theme.green : Theme.disabled
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 11
                                    }
                                    MouseArea {
                                        id: btMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: win.expandedBluetooth = btRow.expanded
                                            ? "" : btRow.modelData.mac
                                    }
                                }

                                Item {
                                    width: parent.width
                                    height: 40

                                    Row {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 5
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 7

                                        ActionButton {
                                            buttonText: "Forget"
                                            accentColor: Theme.red
                                            filled: false
                                            enabled: !win.busy
                                            onActivated: win.btForgetDevice(btRow.modelData)
                                        }

                                        ActionButton {
                                            buttonText: btRow.modelData.connected
                                                ? "Disconnect" : "Connect"
                                            accentColor: btRow.modelData.connected
                                                ? Theme.brightOrange : Theme.green
                                            enabled: !win.busy
                                            onActivated: win.btToggleDevice(btRow.modelData)
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                z: 2
                                color: "transparent"
                                border.width: 1
                                border.color: btRow.expanded
                                    || btRow.modelData.connected
                                    ? Theme.accent : Theme.gray5
                            }
                        }
                    }

                    Repeater {
                        model: win.btFound

                        Rectangle {
                            id: btNewRow
                            required property var modelData
                            readonly property bool expanded:
                                win.expandedBluetooth === modelData.mac
                            width: parent.width
                            height: 30 + (expanded ? 40 : 0)
                            clip: true
                            color: Theme.gray2
                            Behavior on height {
                                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                            }

                            Column {
                                anchors.fill: parent
                                spacing: 0

                                Rectangle {
                                    width: parent.width
                                    height: 30
                                    color: btNewMa.containsMouse
                                        ? Theme.gray3 : Theme.gray2

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.right: btNewTag.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "󰂱  " + btNewRow.modelData.name
                                        color: Qt.alpha(Theme.fg, 0.7)
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        id: btNewTag
                                        anchors.right: parent.right
                                        anchors.rightMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "new  "
                                            + (btNewRow.expanded ? "󰅀" : "󰅂")
                                        color: Theme.disabled
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 11
                                    }
                                    MouseArea {
                                        id: btNewMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: win.expandedBluetooth
                                            = btNewRow.expanded
                                            ? "" : btNewRow.modelData.mac
                                    }
                                }

                                Item {
                                    width: parent.width
                                    height: 40

                                    ActionButton {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 5
                                        anchors.verticalCenter: parent.verticalCenter
                                        buttonText: "Pair and connect"
                                        accentColor: Theme.green
                                        enabled: !win.busy
                                        onActivated: win.btPairNew(btNewRow.modelData)
                                    }
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                z: 2
                                color: "transparent"
                                border.width: 1
                                border.color: btNewRow.expanded
                                    ? Theme.accent : Theme.gray5
                            }
                        }
                    }
                }

                Controls.ScrollBar.vertical: Controls.ScrollBar {
                    id: btScroll
                    width: 8
                    policy: btListView.contentHeight > btListView.height + 0.5
                        ? Controls.ScrollBar.AlwaysOn
                        : Controls.ScrollBar.AlwaysOff
                    interactive: true
                    background: Rectangle {
                        color: Theme.gray2
                        border.width: 1
                        border.color: Theme.gray5
                    }
                    contentItem: Rectangle {
                        implicitWidth: 6
                        implicitHeight: 28
                        color: btScroll.pressed ? Theme.brightOrange
                             : btScroll.hovered ? Theme.orange : Theme.gray6
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Qt.alpha(Theme.fg, 0.1)
            }

            Text {
                text: "Wi-Fi networks"
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: 12
                font.bold: true
            }

            Flickable {
                id: wifiListView
                width: parent.width
                height: Math.max(0, win.implicitHeight - y - 60)
                contentHeight: netCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: netCol
                    width: parent.width
                    spacing: 2

                    Text {
                        visible: win.nets.length === 0
                        text: win.scanning ? "scanning…"
                            : win.wifiOn ? "no networks found" : "wifi is off"
                        color: Theme.disabled
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        topPadding: 8
                    }

                    Repeater {
                        model: win.nets

                        Rectangle {
                            id: netRow
                            required property var modelData
                            readonly property bool asking: win.pwFor === modelData.ssid
                            readonly property bool expanded:
                                win.expandedWifi === modelData.ssid
                            width: netCol.width
                            height: 34 + (expanded ? 40 : 0) + (asking ? 38 : 0)
                            clip: true
                            color: Theme.gray2
                            Behavior on height {
                                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                            }

                            Column {
                                anchors.fill: parent
                                spacing: 0

                                Rectangle {
                                    width: parent.width
                                    height: 34
                                    radius: 0
                                    color: netRow.modelData.inUse ? Qt.alpha(Theme.accent, 0.22)
                                         : netMa.containsMouse ? Theme.gray3 : Theme.gray2

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.right: lockT.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: win.sigGlyph(netRow.modelData.signal) + "  "
                                            + netRow.modelData.ssid
                                            + (netRow.modelData.inUse ? "  󰄬" : "")
                                        color: netRow.modelData.inUse ? Theme.accent : Theme.fg
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 12
                                        font.bold: netRow.modelData.inUse
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        id: lockT
                                        anchors.right: parent.right
                                        anchors.rightMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: (win.savedWifi.indexOf(netRow.modelData.ssid) !== -1
                                            ? "saved  " : "")
                                            + (netRow.modelData.security !== ""
                                               && netRow.modelData.security !== "--" ? "󰌾  " : "")
                                            + (netRow.expanded ? "󰅀" : "󰅂")
                                        color: Theme.disabled
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 11
                                    }

                                    MouseArea {
                                        id: netMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: {
                                            if (netRow.expanded) {
                                                win.expandedWifi = ""
                                                if (netRow.asking)
                                                    win.pwFor = ""
                                            } else {
                                                win.expandedWifi = netRow.modelData.ssid
                                                win.pwFor = ""
                                            }
                                        }
                                    }
                                }

                                Item {
                                    width: parent.width
                                    height: 40

                                    ActionButton {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 5
                                        anchors.verticalCenter: parent.verticalCenter
                                        buttonText: netRow.modelData.inUse
                                            ? "Disconnect" : "Connect"
                                        accentColor: netRow.modelData.inUse
                                            ? Theme.brightOrange : Theme.green
                                        enabled: !win.busy
                                        onActivated: win.connectTo(netRow.modelData)
                                    }
                                }

                                // inline password entry for new secured networks
                                Item {
                                    visible: netRow.asking
                                    width: parent.width
                                    height: visible ? 38 : 0

                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.margins: 4
                                        radius: 0
                                        color: Qt.alpha(Theme.fg, 0.08)

                                        TextInput {
                                            id: pwInput
                                            anchors.left: parent.left
                                            anchors.right: goBtn.left
                                            anchors.leftMargin: 10
                                            anchors.verticalCenter: parent.verticalCenter
                                            echoMode: TextInput.Password
                                            color: Theme.fg
                                            font.family: Theme.fontFamily
                                            font.pixelSize: 12
                                            focus: netRow.asking
                                            onAccepted: win.connectPw(netRow.modelData.ssid, text)

                                            Text {
                                                visible: pwInput.text === ""
                                                text: "password"
                                                color: Theme.disabled
                                                font: pwInput.font
                                            }
                                        }

                                        Rectangle {
                                            id: goBtn
                                            anchors.right: parent.right
                                            anchors.rightMargin: 4
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 64
                                            height: 24
                                            radius: 0
                                            color: Theme.accent
                                            Text {
                                                anchors.centerIn: parent
                                                text: "join"
                                                color: Theme.bg
                                                font.family: Theme.fontFamily
                                                font.pixelSize: 11
                                                font.bold: true
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: win.connectPw(netRow.modelData.ssid, pwInput.text)
                                            }
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                z: 2
                                color: "transparent"
                                border.width: 1
                                border.color: netRow.expanded
                                    || netRow.modelData.inUse
                                    ? Theme.accent : Theme.gray5
                            }
                        }
                    }
                }

                Controls.ScrollBar.vertical: Controls.ScrollBar {
                    id: wifiScroll
                    width: 8
                    policy: wifiListView.contentHeight > wifiListView.height + 0.5
                        ? Controls.ScrollBar.AlwaysOn
                        : Controls.ScrollBar.AlwaysOff
                    interactive: true
                    background: Rectangle {
                        color: Theme.gray2
                        border.width: 1
                        border.color: Theme.gray5
                    }
                    contentItem: Rectangle {
                        implicitWidth: 6
                        implicitHeight: 28
                        color: wifiScroll.pressed ? Theme.brightOrange
                             : wifiScroll.hovered ? Theme.orange : Theme.gray6
                    }
                }
            }

            // status line
            Text {
                width: parent.width
                text: win.busy ? win.status : win.status
                visible: win.status !== ""
                color: win.status.indexOf("fail") !== -1
                    || win.status.indexOf("Error") !== -1 ? Theme.alert : Theme.disabled
                font.family: Theme.fontFamily
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
}
