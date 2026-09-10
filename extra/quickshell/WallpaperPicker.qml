import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

// Thumbnail picker for images in local/wallpaper. Wallpaper-driven palette
// generation is optional; disabled mode leaves the current theme unchanged.
Popout {
    id: root

    cardWidth: 176 * 3 + 2 * cardPadding
    readonly property real titleHeight: 20
    readonly property real galleryHeight: 103 * 4
    readonly property real themeOptionHeight: 30
    cardHeight: titleHeight + 9 + galleryHeight + 8 + themeOptionHeight
        + 2 * cardPadding

    property var wallpapers: []
    property var _found: []
    property bool randomPending: false
    property string selectedPath: ""

    function scan() {
        lister.running = false
        lister.running = true
    }

    function toggle() {
        visible = !visible
        if (visible)
            scan()
    }

    function applyRandom() {
        randomPending = true
        scan()
    }

    function apply(path) {
        if (path === "")
            return
        Quickshell.execDetached([
            Theme.configDir + "/scripts/wallpaper-theme",
            path,
            Theme.wallpaperThemeEnabled ? "true" : "false"
        ])
        visible = false
    }

    IpcHandler {
        target: "wallpapers"
        function toggle(): void { root.toggle() }
        function random(): void { root.applyRandom() }
        function set(path: string): void { root.apply(path) }
    }

    Process {
        id: lister
        command: ["sh", "-c",
            "find \"" + Theme.configDir + "/wallpaper\" -maxdepth 1 -type f " +
            "\\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o " +
            "-iname '*.webp' \\) 2>/dev/null | sort"]
        stdout: SplitParser {
            onRead: line => {
                if (line.trim() !== "")
                    root._found.push(line.trim())
            }
        }
        onRunningChanged: {
            if (running) {
                root._found = []
            } else {
                root.wallpapers = root._found
                if (root.wallpapers.indexOf(root.selectedPath) < 0)
                    root.selectedPath = ""
                if (root.randomPending) {
                    root.randomPending = false
                    if (root.wallpapers.length > 0)
                        root.apply(root.wallpapers[
                            Math.floor(Math.random() * root.wallpapers.length)])
                }
            }
        }
    }

    component SettingSwitch: Rectangle {
        id: control
        property bool checked: false
        signal toggled()

        width: 34
        height: 18
        color: checked ? Theme.accent : Qt.alpha(Theme.fg, 0.15)
        Behavior on color { ColorAnimation { duration: 150 } }

        Rectangle {
            x: control.checked ? parent.width - width - 2 : 2
            anchors.verticalCenter: parent.verticalCenter
            width: 14
            height: 14
            color: control.checked ? Theme.bg : Qt.alpha(Theme.fg, 0.7)
            Behavior on x {
                NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: control.toggled()
        }
    }

    Text {
        id: heading
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: root.titleHeight
        text: "Wallpapers"
        color: Theme.fg
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize + 1
        font.bold: true
        verticalAlignment: Text.AlignVCenter
    }

    Rectangle {
        id: titleSeparator
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: heading.bottom
        height: 1
        color: Theme.gray5
    }

    GridView {
        id: grid
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: titleSeparator.bottom
        anchors.topMargin: 8
        height: root.galleryHeight
        visible: root.wallpapers.length > 0
        clip: true
        cellWidth: 176
        cellHeight: 103
        cacheBuffer: 4000
        model: root.wallpapers
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {
            policy: grid.contentHeight > grid.height
                ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
        }

        delegate: Item {
            id: cell
            required property string modelData
            width: grid.cellWidth
            height: grid.cellHeight

            Rectangle {
                anchors.fill: parent
                anchors.margins: 4
                radius: 0
                color: Theme.gray1
                border.width: cell.modelData === root.selectedPath
                    ? 3 : mouse.containsMouse ? 2 : 1
                border.color: cell.modelData === root.selectedPath
                    ? Theme.orange : mouse.containsMouse
                    ? Theme.brightOrange : Theme.gray4

                Image {
                    anchors.fill: parent
                    anchors.margins: 2
                    source: "file://" + cell.modelData
                    sourceSize.width: 340
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    clip: true
                }

                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        root.selectedPath = cell.modelData
                        root.apply(cell.modelData)
                    }
                }
            }
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: grid.verticalCenter
        visible: root.wallpapers.length === 0
        text: "Add images to local/wallpaper"
        color: Theme.brightBlack
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
    }

    Row {
        id: themeOption
        anchors.left: parent.left
        anchors.top: grid.bottom
        anchors.topMargin: 8
        height: root.themeOptionHeight
        spacing: 9

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Use default theme"
            color: Theme.wallpaperThemeEnabled
                ? Theme.brightBlack : Theme.accent
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
            font.bold: !Theme.wallpaperThemeEnabled
        }

        SettingSwitch {
            anchors.verticalCenter: parent.verticalCenter
            checked: Theme.wallpaperThemeEnabled
            onToggled: Theme.persistWallpaperThemeEnabled(
                !Theme.wallpaperThemeEnabled, root.selectedPath)
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Generate theme based on wallpaper"
            color: Theme.wallpaperThemeEnabled
                ? Theme.accent : Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
            font.bold: Theme.wallpaperThemeEnabled
        }
    }
}
