import QtQuick

// Muted-mic warning, CapsLock-pattern: hidden until the default source
// is muted, then a red pill. Click unmutes (the toggle also lives in the
// Commands panel — this is the fast way out, and the "why is my
// voice-over silent" saver).
BarModule {
    visible: Sys.micMuted
    icon: "󰍭"
    iconColor: Theme.bg
    label: "Mic"
    labelColor: Theme.bg
    color: Theme.red
    onClicked: Sys.toggleMicMute()
}
