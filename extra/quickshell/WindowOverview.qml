pragma ComponentBehavior: Bound

import QtQuick

// One instance lives on every bar. Only the instance on skarwm's focused
// output opens, while its snapshot includes windows from every output/tag.
Popout {
    id: root

    property var workspaceData: []
    property var flatWindows: []
    property int selectedWorkspaceIndex: -1
    property int selectedWindowIndex: -1

    readonly property var selectedWorkspace:
        selectedWorkspaceIndex >= 0 && selectedWorkspaceIndex < workspaceData.length
            ? workspaceData[selectedWorkspaceIndex] : null
    readonly property var selectedWindow:
        selectedWorkspace && selectedWindowIndex >= 0
            && selectedWindowIndex < selectedWorkspace.windows.length
            ? selectedWorkspace.windows[selectedWindowIndex] : null

    cardWidth: 760
    cardHeight: 470

    function anchorBelongsTo(rect) {
        if (!anchorItem || !rect)
            return false
        const point = anchorItem.mapToGlobal(0, 0)
        return point.x >= rect.x && point.x < rect.x + rect.width
            && point.y >= rect.y && point.y < rect.y + rect.height
    }

    function visibleWindows() {
        return Wm.windows.filter(win => !win.dock && !win.scratchpad
            && win.workspace !== null && win.workspace !== undefined)
    }

    function buildSnapshot() {
        const windows = visibleWindows()
        let highest = Math.max(1, TagConfig.count)
        for (const win of windows)
            highest = Math.max(highest, Number(win.workspace))
        for (const output of Wm.outputs) {
            const current = Number(output.current_workspace)
            if (isFinite(current)) highest = Math.max(highest, current)
        }

        const groups = []
        const flattened = []
        for (let tag = 1; tag <= highest; ++tag) {
            const grouped = windows.filter(win => Number(win.workspace) === tag)
            grouped.sort((a, b) => {
                const outputOrder = String(a.output).localeCompare(String(b.output))
                if (outputOrder !== 0) return outputOrder
                const ay = a.rect ? a.rect.y : 0
                const by = b.rect ? b.rect.y : 0
                const ax = a.rect ? a.rect.x : 0
                const bx = b.rect ? b.rect.x : 0
                return ay === by ? ax - bx : ay - by
            })
            const outputNames = []
            for (const win of grouped) {
                flattened.push(win)
                if (win.output && outputNames.indexOf(win.output) < 0)
                    outputNames.push(win.output)
            }
            groups.push({ id: tag, windows: grouped, outputs: outputNames })
        }
        workspaceData = groups
        flatWindows = flattened
    }

    function selectWindow(win) {
        if (!win) return
        const workspaceIndex = workspaceData.findIndex(
            workspace => workspace.id === Number(win.workspace))
        if (workspaceIndex < 0) return
        selectedWorkspaceIndex = workspaceIndex
        selectedWindowIndex = workspaceData[workspaceIndex].windows.findIndex(
            candidate => candidate.id === win.id)
    }

    function openOverview(direction) {
        const output = Wm.focusedOutput
        if (!output || !anchorBelongsTo(output.rect))
            return

        buildSnapshot()
        const focused = Wm.focusedWindow
        const currentTag = Number(output.current_workspace)
        selectedWorkspaceIndex = Math.max(0, workspaceData.findIndex(
            workspace => workspace.id === currentTag))
        const currentWindows = selectedWorkspace
            ? selectedWorkspace.windows : []
        if (currentWindows.length > 0) {
            let index = focused
                ? currentWindows.findIndex(win => win.id === focused.id) : -1
            if (index < 0) index = direction > 0 ? -1 : 0
            selectedWindowIndex = (index + direction + currentWindows.length)
                % currentWindows.length
        } else {
            selectedWindowIndex = -1
        }
        showCenteredInRect(output.rect.x, output.rect.y,
                           output.rect.width, output.rect.height)
    }

    function cycleAll(direction) {
        if (flatWindows.length === 0) return
        const current = selectedWindow
            ? flatWindows.findIndex(win => win.id === selectedWindow.id) : -1
        const next = (current + direction + flatWindows.length) % flatWindows.length
        selectWindow(flatWindows[next])
    }

    function cycleWorkspace(direction) {
        if (workspaceData.length === 0) return
        selectedWorkspaceIndex = (selectedWorkspaceIndex + direction
            + workspaceData.length) % workspaceData.length
        selectedWindowIndex = workspaceData[selectedWorkspaceIndex].windows.length > 0
            ? 0 : -1
    }

    function cycleWindow(direction) {
        if (!selectedWorkspace || selectedWorkspace.windows.length === 0) {
            selectedWindowIndex = -1
            return
        }
        selectedWindowIndex = (selectedWindowIndex + direction
            + selectedWorkspace.windows.length) % selectedWorkspace.windows.length
    }

    function commit() {
        if (!visible) return
        if (selectedWindow)
            Wm.focusWindow(selectedWindow.id)
        else if (selectedWorkspace)
            Wm.viewTag(selectedWorkspace.id - 1)
        visible = false
    }

    function handleCommand(action) {
        if (!visible) {
            if (action === "next") openOverview(1)
            else if (action === "previous") openOverview(-1)
            return
        }
        if (action === "next") cycleAll(1)
        else if (action === "previous") cycleAll(-1)
        else if (action === "workspace-next") cycleWorkspace(1)
        else if (action === "workspace-previous") cycleWorkspace(-1)
        else if (action === "window-next") cycleWindow(1)
        else if (action === "window-previous") cycleWindow(-1)
        else if (action === "commit") commit()
        else if (action === "cancel") visible = false
    }

    Connections {
        target: Wm
        function onOverviewCommand(action) { root.handleCommand(action) }
    }

    Column {
        anchors.fill: parent
        spacing: 9

        Row {
            width: parent.width
            height: 28

            Text {
                width: parent.width - help.width
                anchors.verticalCenter: parent.verticalCenter
                text: "Window overview"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 2
                font.bold: true
            }
            Text {
                id: help
                anchors.verticalCenter: parent.verticalCenter
                text: "← → tags   ↑ ↓ windows"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }

        ListView {
            id: workspaceList
            width: parent.width
            height: 76
            orientation: ListView.Horizontal
            spacing: 7
            clip: true
            model: root.workspaceData
            currentIndex: root.selectedWorkspaceIndex

            delegate: Rectangle {
                id: workspaceCard
                required property var modelData
                required property int index
                readonly property bool selected: index === root.selectedWorkspaceIndex

                width: 112
                height: workspaceList.height
                color: selected ? Qt.alpha(Theme.accent, 0.2) : Theme.gray2
                border.width: selected ? 2 : 1
                border.color: selected ? Theme.accent : Theme.gray5

                Column {
                    anchors.fill: parent
                    anchors.margins: 9
                    spacing: 4
                    Text {
                        text: "Tag " + workspaceCard.modelData.id
                        color: workspaceCard.selected ? Theme.accent : Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        font.bold: workspaceCard.selected
                    }
                    Text {
                        width: parent.width
                        text: workspaceCard.modelData.windows.length === 1
                            ? "1 window"
                            : workspaceCard.modelData.windows.length + " windows"
                        color: Theme.brightBlack
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Text {
                        width: parent.width
                        text: workspaceCard.modelData.outputs.length > 0
                            ? workspaceCard.modelData.outputs.join(", ") : "Empty"
                        elide: Text.ElideRight
                        color: workspaceCard.selected ? Theme.accent : Theme.gray6
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.selectedWorkspaceIndex = workspaceCard.index
                        root.selectedWindowIndex = workspaceCard.modelData.windows.length > 0
                            ? 0 : -1
                    }
                }
            }

            onCurrentIndexChanged: {
                if (currentIndex >= 0)
                    positionViewAtIndex(currentIndex, ListView.Contain)
            }
        }

        Row {
            width: parent.width
            height: 24
            Text {
                width: parent.width - outputLabel.width
                text: root.selectedWorkspace
                    ? "Windows on tag " + root.selectedWorkspace.id : "Windows"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
            }
            Text {
                id: outputLabel
                text: root.selectedWorkspace && root.selectedWorkspace.outputs.length > 0
                    ? root.selectedWorkspace.outputs.join(" · ") : "No windows"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
            }
        }

        Item {
            width: parent.width
            height: 265

            Text {
                anchors.centerIn: parent
                visible: !root.selectedWorkspace
                    || root.selectedWorkspace.windows.length === 0
                text: "This tag is empty"
                color: Theme.brightBlack
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            GridView {
                id: windowGrid
                anchors.fill: parent
                clip: true
                cellWidth: width / 3
                cellHeight: 128
                model: root.selectedWorkspace ? root.selectedWorkspace.windows : []
                currentIndex: root.selectedWindowIndex
                interactive: contentHeight > height

                delegate: Rectangle {
                    id: windowCard
                    required property var modelData
                    required property int index
                    readonly property bool selected: index === root.selectedWindowIndex

                    width: windowGrid.cellWidth - 7
                    height: windowGrid.cellHeight - 7
                    color: selected ? Qt.alpha(Theme.accent, 0.22) : Theme.gray2
                    border.width: selected ? 2 : 1
                    border.color: selected ? Theme.accent : Theme.gray5

                    Column {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 5
                        Row {
                            width: parent.width
                            spacing: 8
                            Text {
                                text: "󰖯"
                                color: windowCard.selected ? Theme.accent : Theme.cyan
                                font.family: Theme.fontFamily
                                font.pixelSize: 20
                            }
                            Text {
                                width: parent.width - 30
                                text: windowCard.modelData.class
                                    || windowCard.modelData.instance || "Window"
                                elide: Text.ElideRight
                                color: Theme.brightBlack
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }
                        }
                        Text {
                            width: parent.width
                            height: 38
                            text: windowCard.modelData.title || "Untitled window"
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            color: Theme.fg
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                            font.bold: windowCard.selected
                        }
                        Text {
                            width: parent.width
                            text: (windowCard.modelData.output || "Unknown output") + "  ·  "
                                + (windowCard.modelData.floating ? "Floating"
                                   : windowCard.modelData.column_layout === "tabbed"
                                     ? "Tabbed" : "Tiled")
                            elide: Text.ElideRight
                            color: windowCard.selected ? Theme.accent : Theme.brightBlack
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.selectedWindowIndex = windowCard.index
                        onClicked: root.commit()
                    }
                }

                onCurrentIndexChanged: {
                    if (currentIndex >= 0)
                        positionViewAtIndex(currentIndex, GridView.Contain)
                }
            }
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Alt+Tab: all windows  ·  Release Alt: open  ·  Esc: cancel"
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
    }
}
