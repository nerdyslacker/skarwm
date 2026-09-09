import QtQuick

// Focused window/column layout. Click opens desktop appearance controls;
// scrolling cycles tiling, tabbed and floating modes.
BarModule {
    id: root

    icon: Wm.layouts[Wm.layoutIndex].glyph
    iconColor: Theme.accent

    onClicked: mouse => {
        if (mouse.button === Qt.LeftButton)
            picker.visible = !picker.visible
    }
    onScrolled: direction => Wm.cycleLayout(direction)

    LayoutPicker {
        id: picker
        anchorItem: root
    }
}
