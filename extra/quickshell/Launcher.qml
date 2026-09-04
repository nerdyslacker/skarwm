import QtQuick

// Left click opens the application launcher, right click opens the wallpaper
// picker, and middle click applies a random wallpaper.
BarModule {
    id: root

    icon: "󰀻"
    iconColor: Theme.accent
    onClicked: mouse => {
        if (mouse.button === Qt.RightButton)
            picker.toggle()
        else if (mouse.button === Qt.MiddleButton)
            picker.applyRandom()
        else
            Wm.openLauncher()
    }

    WallpaperPicker {
        id: picker
        anchorItem: root
    }
}
