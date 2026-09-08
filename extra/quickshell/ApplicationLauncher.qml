import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import Quickshell.Widgets

// Searchable application launcher backed by the system's .desktop entries.
Popout {
    id: root

    cardWidth: 520
    cardHeight: 480

    readonly property string query: search.text.trim().toLowerCase()
    readonly property var applications: {
        const entries = DesktopEntries.applications.values.filter(app => {
            if (app.noDisplay)
                return false
            if (root.query === "")
                return true
            const searchable = [app.name, app.genericName, app.comment]
                .concat(app.keywords).join(" ").toLowerCase()
            return searchable.indexOf(root.query) !== -1
        })
        entries.sort((a, b) => a.name.localeCompare(b.name))
        return entries
    }

    function toggle() {
        if (visible)
            visible = false
        else
            showAtAnchor()
    }

    function toggleCentered() {
        if (visible) {
            visible = false
            return
        }
        if (!focusedOutputQuery.running)
            focusedOutputQuery.running = true
    }

    function anchorBelongsTo(rect) {
        if (!anchorItem || !rect)
            return false
        const anchorPosition = anchorItem.mapToGlobal(0, 0)
        return anchorPosition.x >= rect.x
            && anchorPosition.x < rect.x + rect.width
            && anchorPosition.y >= rect.y
            && anchorPosition.y < rect.y + rect.height
    }

    function focusSearch() {
        if (!visible)
            return
        if (_backingWindow)
            _backingWindow.requestActivate()
        search.forceActiveFocus()
    }

    function launch(app) {
        if (!app)
            return
        visible = false
        app.execute()
    }

    onVisibleChanged: {
        if (visible) {
            search.text = ""
            appList.currentIndex = applications.length > 0 ? 0 : -1
            appList.positionViewAtBeginning()
            focusAttempts = 0
            Qt.callLater(() => {
                appList.positionViewAtBeginning()
                root.focusSearch()
            })
            focusRetry.start()
        }
    }

    property int focusAttempts: 0
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

    Connections {
        target: LauncherState
        function onCenteredRequested() { root.toggleCentered() }
    }

    Process {
        id: focusedOutputQuery
        command: [Wm.msgPath, "get-outputs"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const outputs = JSON.parse(text)
                    const focused = outputs.find(output => output.focused === true)
                    if (focused && root.anchorBelongsTo(focused.rect)) {
                        const rect = focused.rect
                        root.showCenteredInRect(
                            rect.x, rect.y, rect.width, rect.height)
                    }
                } catch (error) {
                    console.warn("application launcher output query:", error)
                }
            }
        }
    }

    Column {
        anchors.fill: parent
        spacing: 10

        Rectangle {
            width: parent.width
            height: 42
            color: Theme.gray2
            border.width: 1
            border.color: search.activeFocus ? Theme.accent : Theme.gray5

            Row {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 10

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰍉"
                    color: Theme.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: 17
                }

                TextInput {
                    id: search
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 40
                    color: Theme.fg
                    selectionColor: Theme.selbg
                    selectedTextColor: Theme.selfg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 1
                    clip: true

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: search.text.length === 0
                        text: "Search applications"
                        color: Theme.brightBlack
                        font: search.font
                    }

                    onTextChanged: {
                        appList.currentIndex = root.applications.length > 0 ? 0 : -1
                        appList.positionViewAtBeginning()
                    }
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Down) {
                            appList.currentIndex = Math.min(appList.count - 1,
                                appList.currentIndex + 1)
                            appList.positionViewAtIndex(appList.currentIndex, ListView.Contain)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Up) {
                            appList.currentIndex = Math.max(0, appList.currentIndex - 1)
                            appList.positionViewAtIndex(appList.currentIndex, ListView.Contain)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.launch(root.applications[appList.currentIndex])
                            event.accepted = true
                        }
                    }
                }
            }
        }

        Text {
            visible: root.applications.length === 0
            width: parent.width
            topPadding: 30
            text: "No matching applications"
            horizontalAlignment: Text.AlignHCenter
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }

        ListView {
            id: appList
            width: parent.width
            height: parent.height - y
            visible: count > 0
            clip: true
            spacing: 3
            model: root.applications
            currentIndex: count > 0 ? 0 : -1

            delegate: Rectangle {
                id: appRow
                required property var modelData
                required property int index

                width: appList.width
                height: 52
                color: index === appList.currentIndex
                    ? Theme.selbg
                    : rowMouse.containsMouse ? Qt.alpha(Theme.fg, 0.12) : "transparent"
                border.width: index === appList.currentIndex ? 1 : 0
                border.color: Theme.brightOrange

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 12

                    IconImage {
                        anchors.verticalCenter: parent.verticalCenter
                        implicitSize: 32
                        source: Quickshell.iconPath(appRow.modelData.icon,
                            "application-x-executable")
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 44
                        spacing: 2

                        Text {
                            width: parent.width
                            text: appRow.modelData.name
                            elide: Text.ElideRight
                            color: appRow.index === appList.currentIndex
                                ? Theme.selfg : Theme.fg
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize + 1
                            font.bold: true
                        }

                        Text {
                            width: parent.width
                            visible: text.length > 0
                            text: appRow.modelData.genericName || appRow.modelData.comment
                            elide: Text.ElideRight
                            color: appRow.index === appList.currentIndex
                                ? Qt.alpha(Theme.selfg, 0.75) : Theme.brightBlack
                            font.family: Theme.fontFamily
                            font.pixelSize: Math.max(10, Theme.fontSize - 1)
                        }
                    }
                }

                MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: appList.currentIndex = appRow.index
                    onClicked: root.launch(appRow.modelData)
                }
            }

            Controls.ScrollBar.vertical: Controls.ScrollBar {
                width: 8
                policy: Controls.ScrollBar.AsNeeded
                interactive: true

                background: Rectangle {
                    color: Theme.gray2
                    border.width: 1
                    border.color: Theme.gray5
                    radius: 0
                }

                contentItem: Rectangle {
                    implicitWidth: 6
                    implicitHeight: 28
                    color: parent.pressed ? Theme.brightOrange
                         : parent.hovered ? Theme.orange : Theme.gray6
                    radius: 0

                    Behavior on color { ColorAnimation { duration: 100 } }
                }
            }
        }
    }
}
