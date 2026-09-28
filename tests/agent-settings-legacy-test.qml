import Quickshell
import QtQuick
import "./src/services"

// The agent runtime's settings under their pre-rename path, read and written by
// the real AgentPolicyService (tests/run-agent-settings-test.sh stages this at
// the repo root and points XDG_CONFIG_HOME at a directory holding ONLY
// apex/agent.json).
//
// On a machine the OS has not finished moving, ~/.config/apex/agent.json is the
// user's file and ~/.config/rime does not exist. The service has to read the
// old file, and a change has to be written THERE: creating ~/.config/rime would
// make the OS's move of the old directory refuse, and the user's other settings
// would be stranded beside it. The runner checks the files; this reports what
// the service saw and makes one change that needs no password.

ShellRoot {
    id: rootScope

    property int phase: 0

    Timer {
        interval: 100
        repeat: true
        running: true
        property int ticks: 0
        onTriggered: {
            ticks++
            if (ticks > 150) {
                console.log("LEGACY-TIMEOUT phase=" + rootScope.phase)
                Qt.quit()
                return
            }
            if (rootScope.phase === 0 && AgentPolicyService.loaded) {
                console.log("LEGACY-READ sandbox=" + AgentPolicyService.defaultSandbox
                            + " path=" + AgentPolicyService.configPath)
                rootScope.phase = 1
                // Switching the sandbox back on asks for nothing (criterion 5).
                AgentPolicyService.setAlwaysUnrestricted(false)
                return
            }
            if (rootScope.phase === 1 && !AgentPolicyService.busy) {
                console.log("LEGACY-WROTE sandbox=" + AgentPolicyService.defaultSandbox
                            + " error=" + AgentPolicyService.lastError)
                rootScope.phase = 2
                Qt.quit()
            }
        }
    }
}
