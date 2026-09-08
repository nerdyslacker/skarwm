import QtQuick

// System numbers: CPU / RAM / root fs ("/" is the mountpoint). Battery has
// its own interactive module because it also anchors the power-state popup.
BarModule {
    id: root

    onClicked: mouse => {
        if (mouse.button === Qt.LeftButton)
            popup.visible = !popup.visible
    }

    MetricsPopup {
        id: popup
        anchorItem: root
    }

    // Dim separators keep the compact icon/value groups easy to scan.
    component Sep: Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "·"
        color: Qt.alpha(Theme.fg, 0.3)
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
    }

    component Seg: Row {
        property string tag: ""
        property string icon: ""
        property color tagColor
        property string value
        property color valueColor: Theme.fg
        spacing: Math.round(5 * Theme.barScale)
        anchors.verticalCenter: parent.verticalCenter

        Text {
            visible: parent.icon !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: parent.icon
            color: parent.tagColor
            font.family: Theme.fontFamily
            font.pixelSize: Theme.iconSize
            Behavior on color { ColorAnimation { duration: 250 } }
        }
        Text {
            visible: parent.tag !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: parent.tag
            color: parent.tagColor
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            Behavior on color { ColorAnimation { duration: 250 } }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: parent.value
            color: parent.valueColor
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            Behavior on color { ColorAnimation { duration: 250 } }
        }
    }

    // one Row child so segment spacing is ours, not BarModule's tighter default
    Row {
        spacing: Math.round(10 * Theme.barScale)
        anchors.verticalCenter: parent.verticalCenter
        leftPadding: 4
        rightPadding: 4

        Seg {
            icon: "󰻠"
            tagColor: Sys.cpu > 90 ? Theme.red : Theme.orange
            value: Math.round(Sys.cpu) + "%"
            valueColor: Sys.cpu > 90 ? Theme.red : Theme.fg
        }
        Sep {}
        Seg {
            icon: "󰍛"
            tagColor: Theme.blue
            value: Math.round(Sys.mem) + "%"
            valueColor: Sys.mem > 90 ? Theme.red : Theme.fg
        }
        Sep {}
        Seg {
            icon: "󰋊"
            tagColor: Theme.yellow
            value: Math.round(Sys.disk) + "%"
            valueColor: Sys.disk > 90 ? Theme.red : Theme.fg
        }
    }
}
