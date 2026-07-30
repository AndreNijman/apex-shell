import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// Power menu — vertical list of power action buttons.

Column {
    id: root
    spacing: 4
    width: parent.width

    readonly property var actions: [
        {
            label:   "Shutdown",
            icon:    "⏻",
            danger:  true,
            confirm: true,
            title:   "Shut Down?",
            message: "Your computer will power off. Save your work before continuing.",
            label2:  "Shut Down",
            action:  "shutdown"
        },
        {
            label:   "Reboot     ",
            icon:    "↺",
            danger:  true,
            confirm: true,
            title:   "Reboot?",
            message: "Your computer will restart. Save your work before continuing.",
            label2:  "Reboot",
            action:  "reboot"
        },
        {
            label:   "Windows ",
            icon:    "󰖳",
            danger:  false,
            confirm: true,
            title:   "Boot into Windows?",
            message: "Your computer will restart into Windows. Save your work before continuing. It will boot back into Linux the next time.",
            label2:  "Restart to Windows",
            action:  "windows"
        },
        {
            label:   "Log Out  ",
            icon:    "󰍃",
            danger:  true,
            confirm: true,
            title:   "Log Out?",
            message: "You will be logged out of your session. Save your work before continuing.",
            label2:  "Log Out",
            action:  "logout"
        },
        {
            label:   "Lock        ",
            icon:    "󰌾",
            danger:  false,
            confirm: false,
            action:  "lock"
        },
        {
            label:   "Suspend ",
            icon:    "⏾",
            danger:  false,
            confirm: false,
            action:  "suspend"
        },
    ]

    // Windows is offered ONLY when a bootable Windows actually exists.
    //
    // The button used to be shown unconditionally, which was misleading in two
    // different ways: on a Linux-only machine it advertised an OS that is not
    // there, and on a machine where Windows was removed but its EFI boot entry was
    // left behind (which is what Windows does when its partition is deleted) it
    // offered to reboot into a loader that no longer exists.
    //
    // The privileged helper answers that question properly — it resolves the boot
    // entry's ESP and confirms the Windows loader is present, rather than trusting
    // the entry's existence — so the decision is delegated to it via --check rather
    // than guessed at here. --check never touches NVRAM and never reboots.
    //
    // Failure closed: no helper, no sudoers rule, or a non-zero exit all leave this
    // false and the row simply absent. A shell running on a distro that ships no
    // helper therefore hides the button instead of showing a broken one.
    property bool windowsAvailable: false

    // windowsAvailable is read into a local FIRST, in the binding's own scope,
    // rather than only inside the filter callback. QML captures binding
    // dependencies by recording property reads during evaluation, and while the
    // callback does run synchronously here, keeping the read at this level makes
    // the dependency unambiguous — so the row appears the moment the probe
    // resolves, instead of the binding never re-evaluating.
    readonly property var visibleActions: {
        const showWindows = root.windowsAvailable
        return root.actions.filter(a => a.action !== "windows" || showWindows)
    }

    // Probed once at startup rather than on every menu open: --check mounts an ESP
    // read-only to verify the loader, which is not something to redo each time the
    // menu is toggled.
    Process {
        id: windowsProbe
        running: true
        command: ["bash", Quickshell.shellDir + "/src/scripts/PowerControl.sh", "windows-check"]
        onExited: function(code) {
            root.windowsAvailable = (code === 0)
        }
    }

    // Direct runner for non-confirm actions
    Process {
        id: runner
        property var pendingCmd: []
        command: pendingCmd
        onRunningChanged: if (!running) pendingCmd = []
    }

    function runDirect(action) {
        // Lock routes through shared state (engages windows/Lockscreen.qml
        // instantly) rather than spawning hyprlock. No external round-trip.
        if (action === "lock") {
            LockState.locked = true
            Popups.archMenuOpen = false
            return
        }
        switch (action) {
            case "suspend": runner.pendingCmd = ["bash", Quickshell.shellDir + "/src/scripts/PowerControl.sh", "suspend"]; break
        }
        runner.running = true
        Popups.archMenuOpen = false
    }

    Repeater {
        model: root.visibleActions

        delegate: Rectangle {
            width:  root.width
            height: 44
            radius: Theme.cornerRadius
            color:  hov.hovered
                        ? (modelData.danger ? "#4d2020" : Theme.active)
                        : "transparent"

            Behavior on color { ColorAnimation { duration: 120 } }

            Row {
                anchors.centerIn: parent
                spacing: 10

                Text {
                    text:           modelData.icon
                    font.pixelSize: 16
                    color:          modelData.danger && hov.hovered ? "#ff6b6b" : hov.hovered?"#000000":Theme.text
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    text:           modelData.label
                    font.pixelSize: 13
                    color:          modelData.danger && hov.hovered ? "#ff6b6b" : hov.hovered?"#000000":Theme.text
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (modelData.confirm) {
                        // Close menu first, then show confirm dialog
                        Popups.closeAll()
                        Popups.showConfirm(
                            modelData.title,
                            modelData.message,
                            modelData.label2,
                            modelData.action
                        )
                    } else {
                        root.runDirect(modelData.action)
                    }
                }
            }
        }
    }
}
