pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property int count: 9
    property bool showNumbers: true
    property bool dynamicWorkspaces: false

    function save(newCount, numbersVisible, dynamic) {
        count = Math.max(1, Math.min(20, Math.round(newCount)))
        showNumbers = numbersVisible
        dynamicWorkspaces = dynamic === true
        stateFile.setText(JSON.stringify({
            count: count,
            showNumbers: showNumbers,
            dynamicWorkspaces: dynamicWorkspaces
        }) + "\n")
    }

    FileView {
        id: stateFile
        path: Theme.stateDir + "/tags.json"
        watchChanges: true
        atomicWrites: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const saved = JSON.parse(text())
                const savedCount = Number(saved.count)
                if (isFinite(savedCount))
                    root.count = Math.max(1, Math.min(20, Math.round(savedCount)))
                root.showNumbers = saved.showNumbers !== false
                root.dynamicWorkspaces = saved.dynamicWorkspaces === true
            } catch (error) {
                console.warn("tag settings:", error)
            }
        }
    }
}
