import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

// Thumbnail picker for images in local/wallpaper. It keeps the original
// picker interactions while leaving the desktop on the fixed Srcery palette.
Popout {
    id: root

    cardWidth: 176 * 3 + 2 * cardPadding
    readonly property real titleHeight: 20
    readonly property real galleryHeight: 103 * 4
    readonly property real footerHeight: 36
    cardHeight: titleHeight + 9 + galleryHeight + footerHeight + 10
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

    function apply(path, scope, targetX, targetY) {
        if (path === "")
            return
        const anchorCenter = root.anchorItem
            ? root.anchorItem.mapToGlobal(root.anchorItem.width / 2,
                root.anchorItem.height / 2) : null
        const suppliedX = Number(targetX)
        const suppliedY = Number(targetY)
        const screenX = isFinite(suppliedX) ? suppliedX
            : anchorCenter ? anchorCenter.x : ""
        const screenY = isFinite(suppliedY) ? suppliedY
            : anchorCenter ? anchorCenter.y : ""
        Quickshell.execDetached([
            Theme.configDir + "/scripts/wallpaper-theme",
            path,
            scope === "current" ? "current" : "all",
            "",
            String(Math.round(screenX)),
            String(Math.round(screenY))
        ])
        visible = false
    }

    IpcHandler {
        target: "wallpapers"
        function toggle(): void { root.toggle() }
        function random(): void { root.applyRandom() }
        function set(path: string): void { root.apply(path, "all") }
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
                            Math.floor(Math.random() * root.wallpapers.length)],
                            "all")
                }
            }
        }
    }

    component ApplyButton: Rectangle {
        id: button
        required property string buttonText
        required property string scope
        readonly property bool available: root.selectedPath !== ""

        height: root.footerHeight
        color: !available ? Theme.gray2
            : pointer.containsMouse ? Theme.brightOrange : Theme.accent
        border.width: 1
        border.color: available ? Theme.brightOrange : Theme.gray5

        Text {
            anchors.centerIn: parent
            text: button.buttonText
            color: button.available ? Theme.selfg : Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
            font.bold: button.available
        }

        MouseArea {
            id: pointer
            anchors.fill: parent
            enabled: button.available
            hoverEnabled: true
            onClicked: mouse => {
                const point = pointer.mapToGlobal(mouse.x, mouse.y)
                root.apply(root.selectedPath, button.scope, point.x, point.y)
            }
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
                    onClicked: root.selectedPath = cell.modelData
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
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.footerHeight
        spacing: 8

        ApplyButton {
            width: (parent.width - parent.spacing) / 2
            buttonText: "Apply to current screen"
            scope: "current"
        }

        ApplyButton {
            width: (parent.width - parent.spacing) / 2
            buttonText: "Apply to all screens"
            scope: "all"
        }
    }
}
