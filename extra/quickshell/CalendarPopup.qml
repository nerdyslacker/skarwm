pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// Month calendar popup anchored under the clock. Today gets an accent pill;
// chevrons page months, clicking the header jumps back to today, and renCal's
// local Caldir events mark their days and appear below the grid.
Popout {
    id: root

    property date shown: new Date()
    property var upcomingEvents: []
    property var eventDates: ({})

    cardWidth: 280
    cardHeight: upcomingEvents.length > 0 ? 470 : 300

    onVisibleChanged: {
        if (visible) {
            shown = new Date()
            eventQuery.running = false
            eventQuery.running = true
        }
    }

    function dateValue(value) {
        if (value === null || value === undefined)
            return null
        let raw = value
        if (typeof value === "object")
            raw = value.instant ?? value.wallclock ?? value.date
                ?? value.date_time ?? value.datetime ?? value.value
                ?? value.Date ?? value.DatetimeUtc ?? value.DatetimeFloating
                ?? value.DatetimeZoned
        if (typeof raw === "object")
            return dateValue(raw)
        if (typeof raw !== "string" || raw === "")
            return null
        if (/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
            const p = raw.split("-")
            return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
        }
        const parsed = new Date(raw)
        return isNaN(parsed.getTime()) ? null : parsed
    }

    function isDateOnly(value) {
        if (typeof value === "string")
            return /^\d{4}-\d{2}-\d{2}$/.test(value)
        return value && typeof value === "object"
            && (value.kind === "date" || value.date !== undefined
                || value.Date !== undefined)
    }

    function parseEvents(text) {
        try {
            const payload = JSON.parse(text)
            const rows = Array.isArray(payload) ? payload
                : Array.isArray(payload.events) ? payload.events : []
            const now = Date.now()
            const result = []
            const dates = {}
            for (const row of rows) {
                const event = row.event ?? row
                const startRaw = event.start ?? event.start_time ?? event.dtstart
                const endRaw = event.end ?? event.end_time ?? event.dtend
                const start = dateValue(startRaw)
                const end = dateValue(endRaw)
                if (!start)
                    continue
                const normalized = {
                    title: event.summary ?? event.title ?? "Untitled event",
                    uid: event.uid ?? "",
                    recurrenceId: event.recurrence_id ?? event.recurrenceId ?? "",
                    start: start,
                    startMs: start.getTime(),
                    allDay: event.all_day === true || isDateOnly(startRaw),
                    calendar: row.calendar_name ?? row.calendar
                        ?? event.calendar_name ?? event.calendar_slug ?? ""
                }
                for (const day of event.dates ?? []) {
                    if (dates[day] === undefined)
                        dates[day] = normalized
                }
                if (!end || end.getTime() > now)
                    result.push(normalized)
            }
            result.sort((a, b) => a.startMs - b.startMs)
            eventDates = dates
            upcomingEvents = result.slice(0, 3)
        } catch (e) {
            eventDates = ({})
            upcomingEvents = []
        }
    }

    function eventWhen(event) {
        const now = new Date()
        const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
        const sameDay = event.start.getFullYear() === now.getFullYear()
            && event.start.getMonth() === now.getMonth()
            && event.start.getDate() === now.getDate()
        const nextDay = event.start.getFullYear() === tomorrow.getFullYear()
            && event.start.getMonth() === tomorrow.getMonth()
            && event.start.getDate() === tomorrow.getDate()
        const day = sameDay ? "Today" : nextDay ? "Tomorrow"
            : Qt.formatDate(event.start, "ddd MMM d")
        return day + (event.allDay ? " · all day"
            : " · " + Qt.formatTime(event.start, "h:mm AP"))
    }

    function openEvent(event) {
        visible = false
        if (!event || event.uid === "") {
            Quickshell.execDetached(["rencal"])
            return
        }
        let url = "rencal://event?uid=" + encodeURIComponent(event.uid)
        if (event.recurrenceId !== "")
            url += "&recurrence-id=" + encodeURIComponent(event.recurrenceId)
        Quickshell.execDetached(["rencal", url])
    }

    Process {
        id: eventQuery
        command: [Theme.configDir + "/scripts/calendar-events"]
        stdout: StdioCollector {
            onStreamFinished: root.parseEvents(text)
        }
    }

    Column {
        anchors.fill: parent
        spacing: 8

        // header: ‹ month year ›
        Item {
            width: parent.width
            height: 28

            Text {
                id: prevBtn
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "󰅁"
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: 18
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    onClicked: root.shown = new Date(root.shown.getFullYear(), root.shown.getMonth() - 1, 1)
                }
            }

            Text {
                anchors.centerIn: parent
                text: Qt.formatDate(root.shown, "MMMM yyyy")
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: 14
                font.bold: true
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    onClicked: root.shown = new Date()
                }
            }

            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "󰅂"
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: 18
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    onClicked: root.shown = new Date(root.shown.getFullYear(), root.shown.getMonth() + 1, 1)
                }
            }
        }

        // weekday header
        Row {
            width: parent.width
            Repeater {
                model: 7
                Text {
                    required property int index
                    width: parent.width / 7
                    text: Qt.locale().dayName((Qt.locale().firstDayOfWeek + index) % 7, Locale.ShortFormat)
                    color: Qt.alpha(Theme.fg, 0.5)
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        // day grid
        Grid {
            id: dayGrid
            width: parent.width
            columns: 7

            Repeater {
                model: 42

                Item {
                    id: cell
                    required property int index
                    width: dayGrid.width / 7
                    height: 30

                    readonly property date cellDate: {
                        const first = new Date(root.shown.getFullYear(), root.shown.getMonth(), 1)
                        const offset = (first.getDay() - Qt.locale().firstDayOfWeek + 7) % 7
                        return new Date(first.getFullYear(), first.getMonth(), 1 - offset + index)
                    }
                    readonly property bool inMonth: cellDate.getMonth() === root.shown.getMonth()
                    readonly property var dayEvent: root.eventDates[
                        Qt.formatDate(cellDate, "yyyy-MM-dd")] ?? null
                    readonly property bool hasEvent: dayEvent !== null
                    readonly property bool isToday: {
                        const now = new Date()
                        return cellDate.getFullYear() === now.getFullYear()
                            && cellDate.getMonth() === now.getMonth()
                            && cellDate.getDate() === now.getDate()
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: 26
                        height: 26
                        radius: 0
                        color: cell.isToday ? Theme.selbg : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: cell.cellDate.getDate()
                            color: cell.isToday ? Theme.selfg
                                 : cell.inMonth ? Theme.fg
                                 : Qt.alpha(Theme.fg, 0.25)
                            font.family: Theme.fontFamily
                            font.pixelSize: 12
                            font.bold: cell.isToday
                        }

                        Rectangle {
                            visible: cell.hasEvent && !cell.isToday
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            width: 12
                            height: 3
                            color: Theme.orange
                        }

                        MouseArea {
                            anchors.fill: parent
                            visible: cell.hasEvent
                            onClicked: root.openEvent(cell.dayEvent)
                        }
                    }
                }
            }
        }

        Rectangle {
            visible: root.upcomingEvents.length > 0
            width: parent.width
            height: 1
            color: Qt.alpha(Theme.fg, 0.15)
        }

        Text {
            visible: root.upcomingEvents.length > 0
            text: "Upcoming"
            color: Theme.orange
            font.family: Theme.fontFamily
            font.pixelSize: 12
            font.bold: true
        }

        Repeater {
            model: root.upcomingEvents

            Rectangle {
                id: eventRow
                required property var modelData
                width: parent.width
                height: 42
                color: eventMouse.containsMouse
                    ? Qt.alpha(Theme.orange, 0.14) : Theme.gray2
                border.width: 1
                border.color: eventMouse.containsMouse ? Theme.orange : Theme.gray5

                Behavior on color { ColorAnimation { duration: 100 } }
                Behavior on border.color { ColorAnimation { duration: 100 } }

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 3
                    color: Theme.orange
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.right: parent.right
                    anchors.rightMargin: 9
                    spacing: 1

                    Text {
                        width: parent.width
                        text: eventRow.modelData.title
                        color: Theme.brightWhite
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    Text {
                        width: parent.width
                        text: root.eventWhen(eventRow.modelData)
                            + (eventRow.modelData.calendar !== ""
                               ? " · " + eventRow.modelData.calendar : "")
                        color: Theme.white
                        font.family: Theme.fontFamily
                        font.pixelSize: 10
                        elide: Text.ElideRight
                    }
                }
                MouseArea {
                    id: eventMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.openEvent(eventRow.modelData)
                }
            }
        }
    }
}
