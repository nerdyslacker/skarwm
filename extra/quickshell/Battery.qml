import QtQuick

// Battery status is kept separate from CPU/RAM/disk and opens the power-state
// controls on a left click.
BarModule {
    id: root

    visible: Sys.hasBattery
    icon: Sys.batteryCharging ? "󰂄"
        : Sys.battery < 15 ? "󰁺"
        : Sys.battery < 40 ? "󰁼"
        : Sys.battery < 80 ? "󰁾"
        : "󰁹"
    iconColor: Sys.batteryCharging ? Theme.green
        : Sys.battery < 15 ? Theme.red
        : Sys.battery < 40 ? Theme.yellow
        : Theme.green
    label: Math.round(Sys.battery) + "%"
    labelColor: !Sys.batteryCharging && Sys.battery < 15
        ? Theme.red : Theme.fg

    onClicked: mouse => {
        if (mouse.button === Qt.LeftButton)
            popup.visible = !popup.visible
    }

    BatteryPopup {
        id: popup
        anchorItem: root
    }
}
