import QtQuick

// Independent scratchpad indicator. It stays hidden until at least one
// window is assigned to a scratchpad register.
BarModule {
    id: root

    visible: Wm.registeredScratchpads.length > 0
    icon: "󰆍"
    iconColor: Theme.accent
    label: Wm.registeredScratchpads.length > 1
        ? String(Wm.registeredScratchpads.length) : ""

    onClicked: mouse => {
        if (mouse.button === Qt.LeftButton)
            popup.visible = !popup.visible
    }

    ScratchpadsPopup {
        id: popup
        anchorItem: root
    }
}
