import QtQuick

// Left click opens the native application launcher. Wallpaper actions live on
// the layout button alongside the other desktop appearance controls.
BarModule {
    id: root

    icon: "󰀻"
    iconColor: Theme.accent
    onClicked: mouse => {
        if (mouse.button === Qt.LeftButton)
            applications.toggle()
    }

    ApplicationLauncher {
        id: applications
        anchorItem: root
    }
}
