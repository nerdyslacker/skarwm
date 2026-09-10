import QtQuick
import Quickshell

// Active connection indicator. Left click toggles the network popup;
// right click opens NetworkManager's full connection editor.
BarModule {
    id: root

    icon: Sys.netIcon
    iconColor: Sys.vpnOn ? Theme.green : Sys.online ? Theme.cyan : Theme.red
    label: Sys.bluetoothOn ? "󰂯" : ""
    labelColor: Sys.bluetoothConnected ? Theme.green : Theme.cyan
    labelPixelSize: Theme.iconSize
    compactLabel: label
    compactLabelPixelSize: Theme.iconSize

    onClicked: mouse => {
        if (mouse.button === Qt.RightButton)
            Quickshell.execDetached(["nm-connection-editor"])
        else
            popup.visible = !popup.visible
    }

    NetworkPopup {
        id: popup
        anchorItem: root
    }
}
