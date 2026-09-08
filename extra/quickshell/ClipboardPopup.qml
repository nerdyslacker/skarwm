pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io

Popout {
    id: root

    cardWidth: 430
    cardHeight: 500

    property bool pendingAtCursor: false
    property string targetWindow: ""
    property int focusAttempts: 0
    readonly property string query: searchInput.text.trim().toLowerCase()
    readonly property var filteredEntries: ClipboardState.entries.filter(entry => {
        if (root.query === "")
            return true
        return entry.text.toLowerCase().indexOf(root.query) !== -1
    })

    function preview(content) {
        const compact = String(content).replace(/\s+/g, " ").trim()
        return compact.length > 125 ? compact.slice(0, 125) + "…" : compact
    }

    function details(entry) {
        return entry.lineCount > 1 ? entry.lineCount + " lines" : "Text"
    }

    function selectedEntry() {
        if (historyList.currentIndex < 0 || historyList.currentIndex >= filteredEntries.length)
            return null
        return filteredEntries[historyList.currentIndex]
    }

    function moveSelection(delta) {
        if (historyList.count === 0)
            return
        historyList.currentIndex = Math.max(0,
            Math.min(historyList.count - 1, historyList.currentIndex + delta))
        historyList.positionViewAtIndex(historyList.currentIndex, ListView.Contain)
    }

    function toggleAtAnchor() {
        if (visible) {
            visible = false
            return
        }
        pendingAtCursor = false
        captureContext()
    }

    function toggleAtCursor() {
        if (visible) {
            visible = false
            return
        }
        pendingAtCursor = true
        captureContext()
    }

    function captureContext() {
        if (!contextProcess.running)
            contextProcess.running = true
    }

    function screenContainsPointer(x, y) {
        if (!anchorItem)
            return false
        const anchorPosition = anchorItem.mapToGlobal(0, 0)
        for (const screen of Quickshell.screens) {
            const ownsAnchor = anchorPosition.x >= screen.x
                && anchorPosition.x < screen.x + screen.width
                && anchorPosition.y >= screen.y
                && anchorPosition.y < screen.y + screen.height
            const ownsPointer = x >= screen.x && x < screen.x + screen.width
                && y >= screen.y && y < screen.y + screen.height
            if (ownsAnchor)
                return ownsPointer
        }
        return false
    }

    function focusSearch() {
        if (!visible)
            return
        if (_backingWindow)
            _backingWindow.requestActivate()
        searchInput.forceActiveFocus()
    }

    function paste(entry) {
        if (!entry)
            return
        visible = false
        pasteProcess.environment = {
            "SKARWM_CLIPBOARD_ROW": String(entry.row),
            "SKARWM_CLIPBOARD_TARGET": targetWindow
        }
        pasteProcess.running = true
    }

    onVisibleChanged: {
        if (visible) {
            searchInput.text = ""
            historyList.currentIndex = historyList.count > 0 ? 0 : -1
            focusAttempts = 0
            ClipboardState.refresh()
            Qt.callLater(() => root.focusSearch())
            focusRetry.start()
        }
    }

    onFilteredEntriesChanged: historyList.currentIndex = historyList.count > 0 ? 0 : -1

    Timer {
        id: focusRetry
        interval: 50
        repeat: true
        onTriggered: {
            root.focusAttempts++
            root.focusSearch()
            if (root.focusAttempts >= 4)
                stop()
        }
    }

    Process {
        id: contextProcess
        command: ["sh", "-c",
            "printf 'WINDOW=%s\\n' \"$(xdotool getactivewindow 2>/dev/null)\"; "
            + "xdotool getmouselocation --shell 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const windowMatch = text.match(/(?:^|\n)WINDOW=(\d+)/)
                const xMatch = text.match(/(?:^|\n)X=(-?\d+)/)
                const yMatch = text.match(/(?:^|\n)Y=(-?\d+)/)
                root.targetWindow = windowMatch ? windowMatch[1] : ""

                if (root.pendingAtCursor) {
                    if (!xMatch || !yMatch)
                        return
                    const x = Number(xMatch[1])
                    const y = Number(yMatch[1])
                    if (!root.screenContainsPointer(x, y))
                        return
                    root.showAtGlobalPoint(x, y)
                } else {
                    root.showAtAnchor()
                }
            }
        }
    }

    Process {
        id: pasteProcess
        command: ["sh", "-c",
            "helper=${SKARWM_EXTRA_DIR:-$HOME/.config/skarwm}/scripts/clipboard-history; "
            + "\"$helper\" select \"$SKARWM_CLIPBOARD_ROW\" || exit; "
            + "if [ -n \"$SKARWM_CLIPBOARD_TARGET\" ]; then "
            + "xdotool windowactivate \"$SKARWM_CLIPBOARD_TARGET\" 2>/dev/null; fi; "
            + "xdotool key --clearmodifiers ctrl+v"]
        stderr: StdioCollector {}
    }

    Column {
        anchors.fill: parent
        spacing: 8

        Item {
            width: parent.width
            height: 25

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Clipboard history"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 2
                font.bold: true
            }

            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Clear"
                color: clearMouse.containsMouse ? Theme.brightOrange : Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: Math.max(9, Theme.fontSize - 1)

                MouseArea {
                    id: clearMouse
                    anchors.fill: parent
                    anchors.margins: -6
                    hoverEnabled: true
                    enabled: !ClipboardState.busy
                    onClicked: ClipboardState.clear()
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 36
            color: Theme.gray2
            border.width: 1
            border.color: searchInput.activeFocus ? Theme.accent : Theme.gray5

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "⌕"
                color: Theme.brightBlack
                font.pixelSize: Theme.fontSize + 3
            }

            TextInput {
                id: searchInput
                anchors.fill: parent
                anchors.leftMargin: 32
                anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.fg
                selectionColor: Theme.accent
                selectedTextColor: Theme.bg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                clip: true

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Down) {
                        root.moveSelection(1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Up) {
                        root.moveSelection(-1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.paste(root.selectedEntry())
                        event.accepted = true
                    }
                }

                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: searchInput.text.length === 0
                    text: "Search clipboard history…"
                    color: Theme.brightBlack
                    font: searchInput.font
                }
            }
        }

        Text {
            visible: !ClipboardState.available || ClipboardState.errorMessage !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: ClipboardState.errorMessage
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }

        Text {
            visible: ClipboardState.available && ClipboardState.errorMessage === ""
                && root.filteredEntries.length === 0
            width: parent.width
            topPadding: 35
            horizontalAlignment: Text.AlignHCenter
            text: root.query === "" ? "Copy something to start the history" : "No matching items"
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }

        ListView {
            id: historyList
            width: parent.width
            height: parent.height - y
            visible: count > 0
            clip: true
            spacing: 4
            model: root.filteredEntries
            currentIndex: count > 0 ? 0 : -1

            delegate: Rectangle {
                id: historyRow
                required property var modelData
                required property int index

                // Scroll bars overlay ListView content, so reserve a fixed
                // gutter instead of allowing rows beneath the thumb.
                width: historyList.width - 14
                height: 62
                color: index === historyList.currentIndex
                    ? Qt.alpha(Theme.accent, 0.2)
                    : rowMouse.containsMouse ? Theme.gray3 : Theme.gray2
                border.width: 1
                border.color: index === historyList.currentIndex
                    ? Theme.accent : Theme.gray5

                MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: historyList.currentIndex = historyRow.index
                    onClicked: root.paste(historyRow.modelData)
                }

                Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter

                    Column {
                        width: parent.width
                        spacing: 4

                        Text {
                            width: parent.width
                            text: root.preview(historyRow.modelData.text)
                            maximumLineCount: 1
                            elide: Text.ElideRight
                            color: Theme.fg
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                        }

                        Text {
                            width: parent.width
                            text: root.details(historyRow.modelData)
                            elide: Text.ElideRight
                            color: Theme.brightBlack
                            font.family: Theme.fontFamily
                            font.pixelSize: Math.max(9, Theme.fontSize - 2)
                        }
                    }
                }
            }

            Controls.ScrollBar.vertical: Controls.ScrollBar {
                id: historyScroll
                width: 8
                policy: Controls.ScrollBar.AsNeeded
                interactive: true

                background: Rectangle {
                    color: Theme.gray2
                    border.width: 1
                    border.color: Theme.gray5
                }

                contentItem: Rectangle {
                    implicitWidth: 6
                    implicitHeight: 28
                    color: historyScroll.pressed ? Theme.brightOrange
                        : historyScroll.hovered ? Theme.orange : Theme.gray6
                }
            }
        }
    }
}
