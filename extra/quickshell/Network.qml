import QtQuick
import Quickshell

// Active connection indicator (icon-only; connection details live in
// the network app). Clicking opens NetworkManager's connection editor.
BarModule {
    id: root

    icon: Sys.netIcon
    iconColor: Sys.vpnOn ? Theme.green : Sys.online ? Theme.cyan : Theme.red

    onClicked: Quickshell.execDetached(["nm-connection-editor"])
}
