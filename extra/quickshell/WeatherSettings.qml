pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// Native editor for the two weather state files watched by Weather.qml.
Popout {
    id: root

    cardWidth: 340
    cardHeight: 248

    property string savedLocation: ""
    property string savedUnits: ""
    property string unitsDraft: ""
    property int focusAttempts: 0

    function focusLocation() {
        if (!visible)
            return
        if (_backingWindow)
            _backingWindow.requestActivate()
        locationInput.forceActiveFocus()
    }

    function openSettings() {
        visible = true
    }

    function saveSettings() {
        const location = locationInput.text.trim()
        savedLocation = location
        savedUnits = unitsDraft
        locationFile.setText(location === "" ? "" : location + "\n")
        unitsFile.setText(unitsDraft === "" ? "" : unitsDraft + "\n")
        visible = false
    }

    onVisibleChanged: {
        if (visible) {
            locationInput.text = savedLocation
            unitsDraft = savedUnits
            focusAttempts = 0
            Qt.callLater(() => root.focusLocation())
            focusRetry.start()
        }
    }

    Timer {
        id: focusRetry
        interval: 50
        repeat: true
        onTriggered: {
            root.focusAttempts++
            root.focusLocation()
            if (root.focusAttempts >= 4)
                stop()
        }
    }

    FileView {
        id: locationFile
        path: Theme.stateDir + "/weather-location"
        watchChanges: true
        atomicWrites: true
        onFileChanged: reload()
        onLoaded: root.savedLocation = text().trim()
        onLoadFailed: root.savedLocation = ""
    }

    FileView {
        id: unitsFile
        path: Theme.stateDir + "/weather-units"
        watchChanges: true
        atomicWrites: true
        onFileChanged: reload()
        onLoaded: {
            const value = text().trim().toLowerCase()
            root.savedUnits = value === "c" || value === "f" ? value : ""
        }
        onLoadFailed: root.savedUnits = ""
    }

    Text {
        id: heading
        anchors.left: parent.left
        anchors.top: parent.top
        text: "Weather settings"
        color: Theme.fg
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize + 2
        font.bold: true
    }

    Text {
        id: locationLabel
        anchors.left: parent.left
        anchors.top: heading.bottom
        anchors.topMargin: 16
        text: "Location"
        color: Theme.brightBlack
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }

    Rectangle {
        id: locationBox
        anchors.left: parent.left
        anchors.right: autoLocation.left
        anchors.rightMargin: 8
        anchors.top: locationLabel.bottom
        anchors.topMargin: 6
        height: 38
        color: Theme.gray2
        border.width: 1
        border.color: locationInput.activeFocus ? Theme.accent : Theme.gray5

        TextInput {
            id: locationInput
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

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: locationInput.text.length === 0
                text: "Automatic by IP"
                color: Theme.brightBlack
                font: locationInput.font
            }
        }
    }

    Rectangle {
        id: autoLocation
        anchors.right: parent.right
        anchors.top: locationBox.top
        width: 72
        height: locationBox.height
        color: autoMouse.containsMouse ? Theme.gray3 : Theme.gray2
        border.width: 1
        border.color: Theme.gray5

        Text {
            anchors.centerIn: parent
            text: "Auto"
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
        }
        MouseArea {
            id: autoMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
                locationInput.text = ""
                locationInput.forceActiveFocus()
            }
        }
    }

    Text {
        id: unitsLabel
        anchors.left: parent.left
        anchors.top: locationBox.bottom
        anchors.topMargin: 16
        text: "Units"
        color: Theme.brightBlack
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }

    Row {
        id: unitsRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: unitsLabel.bottom
        anchors.topMargin: 6
        spacing: 8

        Repeater {
            model: [
                { label: "Auto", value: "" },
                { label: "°C", value: "c" },
                { label: "°F", value: "f" }
            ]
            Rectangle {
                required property var modelData
                width: (unitsRow.width - unitsRow.spacing * 2) / 3
                height: 34
                color: root.unitsDraft === modelData.value ? Theme.accent
                    : (unitMouse.containsMouse ? Theme.gray3 : Theme.gray2)
                border.width: 1
                border.color: root.unitsDraft === modelData.value ? Theme.brightOrange : Theme.gray5

                Text {
                    anchors.centerIn: parent
                    text: parent.modelData.label
                    color: root.unitsDraft === parent.modelData.value ? Theme.selfg : Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: root.unitsDraft === parent.modelData.value
                }
                MouseArea {
                    id: unitMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.unitsDraft = parent.modelData.value
                }
            }
        }
    }

    Row {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: 8

        Repeater {
            model: [
                { label: "Cancel", primary: false },
                { label: "Save", primary: true }
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
