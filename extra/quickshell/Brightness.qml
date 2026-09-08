import QtQuick

// Display brightness is independent from the general command menu. Each
// connected XRandR output gets its own control in the popup.
BarModule {
    id: root

    icon: "󰃠"
    iconColor: Theme.yellow
    onClicked: mouse => {
        if (mouse.button === Qt.LeftButton)
            popup.visible = !popup.visible
    }

    BrightnessPopup {
        id: popup
        anchorItem: root
    }
}
