import QtQuick
import Quickshell.Services.Pipewire

// Compact warning beside Volume. It appears only while the selected default
// input is muted; clicking it is the fast path back to a live microphone.
BarModule {
    id: root

    readonly property var source: Pipewire.preferredDefaultAudioSource
        ?? Pipewire.defaultAudioSource
    readonly property var audio: source?.audio ?? null

    PwObjectTracker {
        objects: [root.source]
    }

    visible: BarVisibility.enabled("micIndicator")
        && (audio?.muted ?? false)
    icon: "󰍭"
    iconColor: Theme.red

    onClicked: {
        if (audio)
            audio.muted = false
    }
}
