import QtQuick
import Quickshell.Services.Pipewire

// Default sink volume. Scroll to adjust, left click to mute, and right click
// to choose an output device or adjust application volumes.
BarModule {
    id: root

    readonly property var sink: Pipewire.preferredDefaultAudioSink
        ?? Pipewire.defaultAudioSink

    PwObjectTracker {
        objects: [root.sink]
    }

    readonly property var audio: sink?.audio ?? null
    readonly property bool muted: audio?.muted ?? false
    readonly property int volume: audio ? Math.round(audio.volume * 100) : 0

    // flash the % briefly on any change (volume keys included)
    property bool flash: false
    onVolumeChanged: { flash = true; flashTimer.restart() }
    onMutedChanged: { flash = true; flashTimer.restart() }
    Timer {
        id: flashTimer
        interval: 1500
        onTriggered: root.flash = false
    }

    icon: muted ? "󰝟" : volume < 25 ? "󰕿" : volume < 65 ? "󰖀" : "󰕾"
    iconColor: muted ? Qt.alpha(Theme.fg, 0.45) : Theme.green
    // label only flashes on change — deliberate feedback, never hover
    label: flash ? (muted ? "--" : volume + "%") : ""

    onClicked: mouse => {
        if (mouse.button === Qt.RightButton)
            popup.visible = !popup.visible
        else if (audio)
            audio.muted = !audio.muted
    }
    onScrolled: dir => {
        if (audio) {
            audio.muted = false
            audio.volume = Math.max(0, Math.min(1, audio.volume + dir * 0.02))
        }
    }

    AudioPopup {
        id: popup
        anchorItem: root
    }
}
