import QtQuick
import Quickshell
import Quickshell.Io

// Thumbnail picker for images in local/wallpaper. It keeps the original
// picker interactions while leaving the desktop on the fixed Srcery palette.
Popout {
    id: root

    cardWidth: 176 * 3 + 2 * cardPadding
    cardHeight: 103 * 4 + 2 * cardPadding

    property var wallpapers: []
    property var _found: []
    property bool randomPending: false
    property string activePath: ""

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
        activePath = path
        Quickshell.execDetached(["feh", "--bg-fill", path])
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
                if (root.randomPending) {
                    root.randomPending = false
                    if (root.wallpapers.length > 0)
                        root.apply(root.wallpapers[
                            Math.floor(Math.random() * root.wallpapers.length)])
                }
            }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: root.wallpapers.length === 0
        text: "Add images to local/wallpaper"
        color: Theme.brightBlack
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
    }

    GridView {
        id: grid
        anchors.fill: parent
        visible: root.wallpapers.length > 0
        clip: true
        cellWidth: 176
        cellHeight: 103
        cacheBuffer: 4000
        model: root.wallpapers

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
                border.width: cell.modelData === root.activePath
                    ? 3 : mouse.containsMouse ? 2 : 1
                border.color: cell.modelData === root.activePath
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
                    onClicked: root.apply(cell.modelData)
                }
            }
        }
    }
}
