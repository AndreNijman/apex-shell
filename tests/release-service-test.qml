import QtQuick
import Quickshell
import "./src/services"

// Staged into the repo root by tests/run-release-service-test.sh. Instantiates
// the REAL ReleaseService (the shell's own singleton, its release.js, its
// Processes) and reports what it decided once it has settled: the runner's
// stubbed curl, rpm-ostree, notify-send and opener record what it did.
ShellRoot {
    property var _r: ReleaseService
    Timer {
        interval: 150; repeat: true; running: true
        property int n: 0
        onTriggered: {
            n++
            const settled = ReleaseService.lastAction !== "" && !ReleaseService._busy
                            && !ReleaseService._saveProc.running && !ReleaseService._notifyProc.running
            if (settled || n > 100) {
                console.warn("RESULT " + (ReleaseService.lastAction || "(none)") + " " + (ReleaseService.lastUrl || "-")
                             + " rollback=" + ReleaseService.hasRollback)
                Qt.quit()
            }
        }
    }
}
