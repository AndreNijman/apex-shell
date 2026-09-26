import QtQuick
import Quickshell
import Quickshell.Io
import "../"
import "../components/controls"

// Power menu — vertical list of power action buttons.
//
// Rows (UI/UX roadmap v3 Phase 17, brief §F.6): 40 px, no gaps, the glyph in
// a fixed column so the labels line up — they used to be centred and padded
// with trailing spaces to fake it — and the state layer on hover instead of
// flooding the row with the accent. A destructive row tints toward danger. Each
// row is an ApexPressable, so the menu is reachable with Tab and operable with
// Space/Return; it was pointer-only.

Column {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    spacing: 0
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
            label:   "Reboot",
            icon:    "↺",
            danger:  true,
            confirm: true,
            title:   "Reboot?",
            message: "Your computer will restart. Save your work before continuing.",
            label2:  "Reboot",
            action:  "reboot"
        },
        {
            label:   "Windows",
            icon:    "󰖳",
            danger:  false,
            confirm: true,
            title:   "Boot into Windows?",
            message: "Your computer will restart into Windows. Save your work before continuing. It will boot back into Linux the next time.",
            label2:  "Restart to Windows",
            action:  "windows"
        },
        {
            label:   "Gaming",
            icon:    "󰊴",
            danger:  false,
            confirm: true,
            title:   "Enter Gaming Mode?",
            message: "You will be logged out and returned to the login screen with Gaming Mode selected. Steam Big Picture then runs inside gamescope, with no desktop compositing over the game. Save your work before continuing.",
            label2:  "Enter Gaming Mode",
            action:  "gamingmode"
        },
        {
            label:   "Log Out",
            icon:    "󰍃",
            danger:  true,
            confirm: true,
            title:   "Log Out?",
            message: "You will be logged out of your session. Save your work before continuing.",
            label2:  "Log Out",
            action:  "logout"
        },
        {
            label:   "Lock",
            icon:    "󰌾",
            danger:  false,
            confirm: false,
            action:  "lock"
        },
        {
            label:   "Suspend",
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

    // Gaming Mode is offered ONLY on an image that actually ships it.
    //
    // Same posture as the Windows row, and for the same reason: this shell also
    // runs on the Daily edition and on non-APEX machines, where the gamescope
    // session does not exist. Advertising a button that logs you out and then
    // cannot start anything would be worse than not showing it.
    //
    // Both halves are required — the session file (so the greeter has something
    // to select) AND the switch helper (so the choice can be recorded). Failure
    // closed: anything unexpected leaves this false and the row absent.
    property bool gamingModeAvailable: false

    // windowsAvailable is read into a local FIRST, in the binding's own scope,
    // rather than only inside the filter callback. QML captures binding
    // dependencies by recording property reads during evaluation, and while the
    // callback does run synchronously here, keeping the read at this level makes
    // the dependency unambiguous — so the row appears the moment the probe
    // resolves, instead of the binding never re-evaluating.
    readonly property var visibleActions: {
        const showWindows = root.windowsAvailable
        const showGaming  = root.gamingModeAvailable
        return root.actions.filter(a =>
            (a.action !== "windows"     || showWindows) &&
            (a.action !== "gamingmode"  || showGaming))
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

    // Probed once at startup, like the Windows check. Cheap: two file tests and
    // a `command -v`.
    //
    // THE THIRD TEST IS THE ONE THAT WAS MISSING. This used to check the helper
    // and the session file only, never gamescope — but gamescope and Steam are
    // on-demand packages, not image content, so apex-gaming.desktop ships on
    // every machine while the binary it runs does not. The entry itself says so
    // and carries `TryExec=/usr/bin/gamescope` for exactly that reason, and
    // apex-greet's enumeration honours it.
    //
    // So the menu and the greeter disagreed. The menu offered "Gaming Mode" on
    // any APEX install; taking it logged the user out into a greeter that HID
    // the session, landing them back on the desktop with
    // `last-session=apex-gaming` recorded — which then selected by sort order
    // at the next login. The build gate in Containerfile.apex asserts the
    // greeter hides it; nothing asserted that this menu agrees.
    //
    // It reads TryExec out of the same file rather than naming gamescope here,
    // so the two surfaces cannot drift: change the entry and both follow.
    // Failure closed — an unreadable file, a missing helper or a TryExec that
    // resolves to nothing all leave the row absent.
    //
    // The paths come from APEX_SESSION_HELPER and APEX_SESSION_DIR when set,
    // which is the same pair PowerControl.sh already honours, so the gate can
    // be exercised against a fixture instead of against the machine running
    // the test.
    Process {
        id: gamingProbe
        running: true
        command: ["sh", "-c",
            "h=\"${APEX_SESSION_HELPER:-/usr/libexec/apex-session-select}\"; " +
            "d=\"${APEX_SESSION_DIR:-/usr/share/wayland-sessions}\"; " +
            "test -x \"$h\" || exit 1; " +
            "f=\"$d/apex-gaming.desktop\"; " +
            "test -f \"$f\" || exit 1; " +
            "t=$(sed -n 's/^TryExec=//p' \"$f\" | head -n1); " +
            "[ -z \"$t\" ] || command -v \"$t\" >/dev/null 2>&1"]
        onExited: function(code) {
            root.gamingModeAvailable = (code === 0)
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
            LockState.lock()
            Popups.archMenuOpen = false
            return
        }
        switch (action) {
            case "suspend": runner.pendingCmd = ["bash", Quickshell.shellDir + "/src/scripts/PowerControl.sh", "suspend"]; break
        }
        runner.running = true
        Popups.archMenuOpen = false
    }

    function activate(entry) {
        if (entry.confirm) {
            // Close menu first, then show confirm dialog
            Popups.closeAll()
            Popups.showConfirm(entry.title, entry.message, entry.label2, entry.action)
        } else {
            root.runDirect(entry.action)
        }
    }

    // A menu on the keyboard (UI/UX roadmap v3 Phase 21): Tab reaches the first
    // row, Up and Down walk the rows and stop at the ends.
    Keys.onPressed: function (event) {
        if (event.key !== Qt.Key_Up && event.key !== Qt.Key_Down) return
        for (let i = 0; i < rows.count; i++) {
            if (!rows.itemAt(i) || !rows.itemAt(i).activeFocus) continue
            const j = Math.max(0, Math.min(rows.count - 1, i + (event.key === Qt.Key_Down ? 1 : -1)))
            rows.itemAt(j).forceActiveFocus()
            event.accepted = true
            return
        }
    }

    Repeater {
        id: rows
        model: root.visibleActions

        delegate: ApexPressable {
            id: row
            required property var modelData
            width:  root.width
            height: theme.rowHeight
            radius: theme.radiusM
            Accessible.name: row.modelData.label
            onActivated: root.activate(row.modelData)

            readonly property color _fg: row.modelData.danger && (row.hovered || row.pressed)
                                         ? Theme.danger : Theme.textPrimary

            Rectangle {
                anchors.fill: parent
                radius: row.radius
                color: row.modelData.danger && (row.hovered || row.pressed)
                       ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, row.pressed ? 0.20 : 0.14)
                       : row.stateLayer()
                Behavior on color { MotionColor {} }
            }

            // The glyph in a 20 px column, the label after it.
            Text {
                id: glyph
                x: theme.px(12)
                width: theme.px(20)
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignHCenter
                text:           row.modelData.icon
                font.family:    Theme.fontIcon
                font.pixelSize: theme.typeIcon
                color:          row.modelData.danger && (row.hovered || row.pressed) ? Theme.danger : Theme.iconDefault
                Behavior on color { MotionColor {} }
            }
            Text {
                anchors.left: glyph.right
                anchors.leftMargin: theme.px(10)
                anchors.verticalCenter: parent.verticalCenter
                text:           row.modelData.label
                font.pixelSize: theme.typeBody
                color:          row._fg
                Behavior on color { MotionColor {} }
            }
            ApexFocusRing { target: row }
        }
    }
}
