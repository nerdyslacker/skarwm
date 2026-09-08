pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls

Popout {
    id: root

    cardWidth: 480
    cardHeight: 590

    property string groupDraft: ""
    property string errorText: ""
    property int focusAttempts: 0
    property var selectedLayouts: []
    readonly property var filteredLayouts: {
        const query = searchInput.text.trim().toLowerCase()
        if (query === "")
            return KeyboardState.availableLayouts
        return KeyboardState.availableLayouts.filter(layout =>
            layout.code.toLowerCase().indexOf(query) !== -1
                || layout.name.toLowerCase().indexOf(query) !== -1)
    }

    readonly property var shortcutPresets: [
        { label: "Alt+Shift", value: "grp:alt_shift_toggle" },
        { label: "Super+Space", value: "grp:win_space_toggle" },
        { label: "Ctrl+Shift", value: "grp:ctrl_shift_toggle" },
        { label: "Caps Lock", value: "grp:caps_toggle" },
        { label: "None", value: "" }
    ]

    function focusSearch() {
        if (!visible)
            return
        if (_backingWindow)
            _backingWindow.requestActivate()
        searchInput.forceActiveFocus()
    }

    function openSettings() {
        syncInputs()
        errorText = ""
        visible = true
    }

    function syncInputs() {
        selectedLayouts = KeyboardState.layouts.slice()
        const values = KeyboardState.variants.slice(0, selectedLayouts.length)
        while (values.length < selectedLayouts.length)
            values.push("")
        variantsInput.text = values.join(",")
        searchInput.text = ""
        groupDraft = KeyboardState.groupOption
        customInput.text = groupDraft
    }

    function toggleLayout(code) {
        const layouts = selectedLayouts.slice()
        const variants = String(variantsInput.text).split(",")
        const index = layouts.indexOf(code)
        if (index === -1) {
            layouts.push(code)
            variants.push("")
        } else {
            layouts.splice(index, 1)
            variants.splice(index, 1)
        }
        selectedLayouts = layouts
        variantsInput.text = variants.slice(0, layouts.length).join(",")
        errorText = ""
    }

    function saveSettings() {
        if (!KeyboardState.saveConfiguration(selectedLayouts.join(","),
                                             variantsInput.text,
                                             customInput.text)) {
            errorText = "Add at least one layout."
            return
        }
        visible = false
    }

    onVisibleChanged: {
        if (visible) {
            focusAttempts = 0
            Qt.callLater(() => root.focusSearch())
            focusRetry.start()
        }
    }

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

    Text {
        id: heading
        anchors.left: parent.left
        anchors.top: parent.top
        text: "Keyboard settings"
        color: Theme.fg
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize + 2
        font.bold: true
    }

    Text {
        id: selectedLabel
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: heading.bottom
        anchors.topMargin: 14
        elide: Text.ElideRight
        text: "Selected (in order): " + (root.selectedLayouts.length > 0
            ? root.selectedLayouts.map(code => code.toUpperCase()).join(" → ")
            : "none")
        color: Theme.brightBlack
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }

    Rectangle {
        id: searchBox
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: selectedLabel.bottom
        anchors.topMargin: 5
        height: 36
        color: Theme.gray2
        border.width: 1
        border.color: searchInput.activeFocus ? Theme.accent : Theme.gray5

        Row {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 8

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "󰍉"
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: Theme.iconSize
            }

            TextInput {
                id: searchInput
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 30
                clip: true
                color: Theme.fg
                selectionColor: Theme.selbg
                selectedTextColor: Theme.selfg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: searchInput.text.length === 0
                    text: "Search available languages or layout codes"
                    color: Theme.brightBlack
                    font: searchInput.font
                }
            }
        }
    }

    ListView {
        id: layoutList
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: searchBox.bottom
        anchors.topMargin: 6
        height: 210
        clip: true
        spacing: 2
        model: root.filteredLayouts

        Text {
            anchors.centerIn: parent
            visible: layoutList.count === 0
            text: KeyboardState.availableLayouts.length === 0
                ? "XKB layout catalogue was not found"
                : "No matching layouts"
            color: Theme.brightBlack
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }

        delegate: Rectangle {
            id: layoutRow
            required property var modelData

            width: layoutList.width
            height: 32
            readonly property int selectedIndex: root.selectedLayouts.indexOf(modelData.code)
            readonly property bool selected: selectedIndex !== -1
            color: selected ? Qt.alpha(Theme.accent, 0.22)
                : (layoutMouse.containsMouse ? Theme.gray3 : Theme.gray2)
            border.width: 1
            border.color: selected ? Theme.accent : Theme.gray5

            Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: 9
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                color: layoutRow.selected ? Theme.accent : "transparent"
                border.width: 1
                border.color: layoutRow.selected ? Theme.brightOrange : Theme.gray6

                Text {
                    anchors.centerIn: parent
                    visible: layoutRow.selected
                    text: "✓"
                    color: Theme.selfg
                    font.pixelSize: 12
                    font.bold: true
                }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 34
                anchors.right: orderText.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: layoutRow.modelData.name + "  (" + layoutRow.modelData.code + ")"
                elide: Text.ElideRight
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            Text {
                id: orderText
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: layoutRow.selected ? String(layoutRow.selectedIndex + 1) : ""
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
            }

            MouseArea {
                id: layoutMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.toggleLayout(layoutRow.modelData.code)
            }
        }

        Controls.ScrollBar.vertical: Controls.ScrollBar {
            id: layoutScroll
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
                color: layoutScroll.pressed ? Theme.brightOrange
                    : layoutScroll.hovered ? Theme.orange : Theme.gray6
            }
        }
    }

    Text {
        id: variantsLabel
        anchors.left: parent.left
        anchors.top: layoutList.bottom
        anchors.topMargin: 12
        text: "Variants (same order; keep empty entries)"
        color: Theme.brightBlack
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }

    Rectangle {
        id: variantsBox
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: variantsLabel.bottom
        anchors.topMargin: 5
        height: 36
        color: Theme.gray2
        border.width: 1
        border.color: variantsInput.activeFocus ? Theme.accent : Theme.gray5

        TextInput {
            id: variantsInput
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            color: Theme.fg
            selectionColor: Theme.selbg
            selectedTextColor: Theme.selfg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            Keys.onReturnPressed: customInput.forceActiveFocus()
        }
    }

    Text {
        id: shortcutLabel
        anchors.left: parent.left
        anchors.top: variantsBox.bottom
        anchors.topMargin: 12
        text: "Switch shortcut"
        color: Theme.brightBlack
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }

    Flow {
        id: presetFlow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: shortcutLabel.bottom
        anchors.topMargin: 5
        spacing: 6

        Repeater {
            model: root.shortcutPresets

            Rectangle {
                required property var modelData
                width: presetText.implicitWidth + 18
                height: 30
                readonly property bool selected: customInput.text.trim() === modelData.value
                color: selected ? Theme.accent
                    : (presetMouse.containsMouse ? Theme.gray3 : Theme.gray2)
                border.width: 1
                border.color: selected ? Theme.brightOrange : Theme.gray5

                Text {
                    id: presetText
                    anchors.centerIn: parent
                    text: parent.modelData.label
                    color: parent.selected ? Theme.selfg : Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                }

                MouseArea {
                    id: presetMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        root.groupDraft = parent.modelData.value
                        customInput.text = root.groupDraft
                    }
                }
            }
        }
    }

    Text {
        id: optionLabel
        anchors.left: parent.left
        anchors.top: presetFlow.bottom
        anchors.topMargin: 12
        text: "XKB group option"
        color: Theme.brightBlack
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }

    Rectangle {
        id: optionBox
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: optionLabel.bottom
        anchors.topMargin: 5
        height: 36
        color: Theme.gray2
        border.width: 1
        border.color: customInput.activeFocus ? Theme.accent : Theme.gray5

        TextInput {
            id: customInput
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            color: Theme.fg
            selectionColor: Theme.selbg
            selectedTextColor: Theme.selfg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            Keys.onReturnPressed: root.saveSettings()
        }
    }

    Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 7
        text: root.errorText
        visible: text !== ""
        color: Theme.red
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }

    Row {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: 8

        Repeater {
            model: [
                { label: "Cancel", primary: false },
                { label: "Apply", primary: true }
            ]

            Rectangle {
                required property var modelData
                width: 82
                height: 34
                color: modelData.primary ? Theme.accent
                    : (actionMouse.containsMouse ? Theme.gray3 : Theme.gray2)
                border.width: 1
                border.color: modelData.primary ? Theme.brightOrange : Theme.gray5

                Text {
                    anchors.centerIn: parent
                    text: parent.modelData.label
                    color: parent.modelData.primary ? Theme.selfg : Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: parent.modelData.primary
                }

                MouseArea {
                    id: actionMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        if (parent.modelData.primary)
                            root.saveSettings()
                        else
                            root.visible = false
                    }
                }
            }
        }
    }
}
