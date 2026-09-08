pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Native device picker and mixer. Quickshell classifies PipeWire
// Stream/Output/Audio nodes as stream sinks, despite their output naming.
Popout {
    id: root

    readonly property var allNodes: Pipewire.nodes.values
    readonly property var outputDevices: allNodes.filter(node =>
        node.audio !== null && !node.isStream && node.isSink)
    readonly property var inputDevices: allNodes.filter(node =>
        node.audio !== null && !node.isStream && !node.isSink)
    readonly property var playbackStreams: allNodes.filter(node =>
        node.audio !== null && node.isStream && node.isSink)
    // The session manager may keep defaultAudioSink/Source on its automatic
    // choice even after the user configures another device. Prefer the
    // configured node so the dropdown and global slider follow the selection.
    readonly property var selectedOutput: Pipewire.preferredDefaultAudioSink
        ?? Pipewire.defaultAudioSink
    readonly property var selectedInput: Pipewire.preferredDefaultAudioSource
        ?? Pipewire.defaultAudioSource

    cardWidth: 360
    cardHeight: Math.min(560, Math.max(150,
        content.implicitHeight + 2 * cardPadding))

    // Binding nodes makes audio volume, mute, and descriptive properties live.
    PwObjectTracker {
        objects: root.outputDevices.concat(root.inputDevices, root.playbackStreams)
    }

    function nodeName(node) {
        return node.description || node.nickname || node.name || "Unknown device"
    }

    function applicationName(node) {
        const props = node.properties ?? ({})
        return props["application.name"] || node.description
            || node.nickname || node.name || "Application"
    }

    function mediaName(node) {
        const props = node.properties ?? ({})
        const media = props["media.name"] || props["media.title"] || ""
        return media !== applicationName(node) ? media : ""
    }

    function selectOutput(node) {
        Pipewire.preferredDefaultAudioSink = node
        // The metadata preference alone does not move streams on every session
        // manager. Set the Pulse default explicitly and move current streams.
        Quickshell.execDetached(["pactl", "set-default-sink", node.name])
        sinkInputLister.running = false
        sinkInputLister.targetName = node.name
        sinkInputLister.running = true
    }

    function selectInput(node) {
        Pipewire.preferredDefaultAudioSource = node
        Quickshell.execDetached(["pactl", "set-default-source", node.name])
        sourceOutputLister.running = false
        sourceOutputLister.targetName = node.name
        sourceOutputLister.running = true
    }

    Process {
        id: sinkInputLister
        property string targetName: ""
        command: ["pactl", "list", "short", "sink-inputs"]
        stdout: StdioCollector {
            onStreamFinished: {
                for (const line of text.trim().split("\n")) {
                    const id = line.trim().split(/\s+/)[0]
                    if (id !== "")
                        Quickshell.execDetached(["pactl", "move-sink-input",
                                                id, sinkInputLister.targetName])
                }
            }
        }
    }

    Process {
        id: sourceOutputLister
        property string targetName: ""
        command: ["pactl", "list", "short", "source-outputs"]
        stdout: StdioCollector {
            onStreamFinished: {
                for (const line of text.trim().split("\n")) {
                    const id = line.trim().split(/\s+/)[0]
                    if (id !== "")
                        Quickshell.execDetached(["pactl", "move-source-output",
                                                id, sourceOutputLister.targetName])
                }
            }
        }
    }

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: content
            width: parent.width
            spacing: 8

            Text {
                text: "Audio output"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 1
                font.bold: true
            }

            AudioDeviceSelector {
                width: content.width
                visible: root.outputDevices.length > 0
                devices: root.outputDevices
                currentDevice: root.selectedOutput
                onSelected: device => root.selectOutput(device)
            }

            Text {
                visible: root.outputDevices.length === 0
                width: parent.width
                text: Pipewire.ready ? "No output devices available."
                                     : "Connecting to PipeWire…"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            Row {
                width: parent.width
                height: 28
                spacing: 8
                visible: (root.selectedOutput?.audio ?? null) !== null

                Text {
                    width: 21
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.selectedOutput?.audio?.muted ? "󰝟" : "󰕾"
                    color: root.selectedOutput?.audio?.muted
                        ? Theme.brightBlack : Theme.green
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.iconSize
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        onClicked: {
                            const audio = root.selectedOutput?.audio
                            if (audio)
                                audio.muted = !audio.muted
                        }
                    }
                }

                AudioSlider {
                    width: parent.width - 29
                    anchors.verticalCenter: parent.verticalCenter
                    audio: root.selectedOutput?.audio ?? null
                    accent: root.selectedOutput?.audio?.muted
                        ? Theme.brightBlack : Theme.green
                }
            }

            Rectangle { width: parent.width; height: 1; color: Theme.gray5 }

            Text {
                text: "Audio input"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 1
                font.bold: true
            }

            AudioDeviceSelector {
                width: content.width
                visible: root.inputDevices.length > 0
                devices: root.inputDevices
                currentDevice: root.selectedInput
                onSelected: device => root.selectInput(device)
            }

            Text {
                visible: root.inputDevices.length === 0
                width: parent.width
                text: Pipewire.ready ? "No input devices available."
                                     : "Connecting to PipeWire…"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            Row {
                width: parent.width
                height: 28
                spacing: 8
                visible: (root.selectedInput?.audio ?? null) !== null

                Text {
                    width: 21
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.selectedInput?.audio?.muted ? "󰍭" : "󰍬"
                    color: root.selectedInput?.audio?.muted
                        ? Theme.brightRed : Theme.cyan
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.iconSize
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        onClicked: {
                            const audio = root.selectedInput?.audio
                            if (audio)
                                audio.muted = !audio.muted
                        }
                    }
                }

                AudioSlider {
                    width: parent.width - 29
                    anchors.verticalCenter: parent.verticalCenter
                    audio: root.selectedInput?.audio ?? null
                    accent: root.selectedInput?.audio?.muted
                        ? Theme.brightRed : Theme.cyan
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.gray5
            }

            Text {
                text: "Applications"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 1
                font.bold: true
            }

            Text {
                visible: root.playbackStreams.length === 0
                width: parent.width
                text: "No applications are playing audio."
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            Flickable {
                id: applicationListView
                visible: root.playbackStreams.length > 0
                width: parent.width
                height: Math.min(applicationList.implicitHeight, 240)
                contentWidth: width
                contentHeight: applicationList.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: applicationList
                    width: parent.width
                    spacing: 8

                    Repeater {
                        model: root.playbackStreams

                        Rectangle {
                            id: streamRow
                            required property var modelData
                            readonly property var streamAudio: modelData.audio

                            width: applicationList.width
                            height: 54
                            color: Theme.gray2
                            border.width: 1
                            border.color: Theme.gray5

                            Text {
                                id: muteButton
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.top: parent.top
                                anchors.topMargin: 7
                                width: 19
                                text: streamRow.streamAudio?.muted ? "󰝟" : "󰕾"
                                color: streamRow.streamAudio?.muted
                                    ? Theme.brightBlack : Theme.green
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.iconSize

                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    onClicked: {
                                        if (streamRow.streamAudio)
                                            streamRow.streamAudio.muted = !streamRow.streamAudio.muted
                                    }
                                }
                            }

                            Text {
                                anchors.left: muteButton.right
                                anchors.leftMargin: 7
                                anchors.right: parent.right
                                anchors.rightMargin: 9
                                anchors.top: parent.top
                                anchors.topMargin: 6
                                text: root.applicationName(streamRow.modelData)
                                elide: Text.ElideRight
                                color: Theme.fg
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize
                            }

                            Text {
                                anchors.left: muteButton.right
                                anchors.leftMargin: 7
                                anchors.right: parent.right
                                anchors.rightMargin: 9
                                anchors.top: parent.top
                                anchors.topMargin: 21
                                visible: text !== ""
                                text: root.mediaName(streamRow.modelData)
                                elide: Text.ElideRight
                                color: Theme.brightBlack
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }

                            AudioSlider {
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.right: parent.right
                                anchors.rightMargin: 9
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 1
                                audio: streamRow.streamAudio
                                accent: streamRow.streamAudio?.muted
                                    ? Theme.brightBlack : Theme.green
                            }
                        }
                    }
                }

                Controls.ScrollBar.vertical: Controls.ScrollBar {
                    id: applicationScroll
                    width: 8
                    policy: applicationListView.contentHeight
                            > applicationListView.height + 0.5
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
                        color: applicationScroll.pressed ? Theme.brightOrange
                             : applicationScroll.hovered ? Theme.orange : Theme.gray6
                    }
                }
            }
        }
    }
}
