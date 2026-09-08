import QtQuick

BarModule {
    id: root

    icon: "󰅌"
    iconColor: ClipboardState.entries.length > 0 ? Theme.magenta : Theme.brightBlack
    label: ClipboardState.entries.length > 0 ? String(ClipboardState.entries.length) : ""

    onClicked: history.toggleAtAnchor()

    Connections {
        target: ClipboardState
        function onPopupRequested() { history.toggleAtCursor() }
    }

    ClipboardPopup {
        id: history
        anchorItem: root
    }
}
