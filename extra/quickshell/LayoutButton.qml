import QtQuick

// Focused window/column layout. Left click opens desktop appearance controls,
// right click opens wallpapers, middle click applies a random wallpaper, and
// scrolling cycles tiling, tabbed and floating modes.
BarModule {
    id: root

    icon: Wm.layouts[Wm.layoutIndex].glyph
    iconColor: Theme.accent

    onClicked: mouse => {
        if (mouse.button === Qt.RightButton) {
            picker.visible = false
            wallpapers.toggle()
        } else if (mouse.button === Qt.MiddleButton) {
            picker.visible = false
            wallpapers.applyRandom()
        } else if (mouse.button === Qt.LeftButton) {
            wallpapers.visible = false
            picker.visible = !picker.visible
        }
    }
    onScrolled: direction => Wm.cycleLayout(direction)

    LayoutPicker {
        id: picker
        anchorItem: root
    }

    WallpaperPicker {
        id: wallpapers
        anchorItem: root
    }
}
