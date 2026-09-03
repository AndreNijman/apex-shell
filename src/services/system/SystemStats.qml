import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// Gathers system info natively (no fastfetch dependency) into key/value rows
// and renders them styled. The collector script emits one "Key: Value" line per
// field — we split on ": " (first occurrence).
//
// ── The WM row is not collected by the script ────────────────────────────────
// It used to be: a `hyprctl version | grep -oE` pipeline with a parallel
// `niri --version` branch and a three-way `if` over
// HYPRLAND_INSTANCE_SIGNATURE / NIRI_SOCKET, all inside the same shell
// one-liner that reads the kernel and counts packages. That made this file the
// last one outside src/services/compositor/ that named a compositor's CLI, and
// it got labwc wrong — it fell through to printing "WM: labwc:wlroots".
//
// Two consequences of asking the adapter instead, both deliberate:
//   • The name now follows Compositor's detection AND its config_Provider.json
//     override, rather than re-probing the environment on its own. If a user
//     has pinned the compositor, this row agrees with the rest of the shell.
//   • The version arrives asynchronously, so the row appears with the name
//     first and gains the version a moment later.
//
// ── Refcounted: it costs a subprocess ────────────────────────────────────────
// The collector is a bash invocation that shells out to uname, uptime and a
// package manager. That is cheap but not free, and `uptime` is stale the moment
// it is read, so the honest model is: run it when somebody starts looking, and
// not at all otherwise. Consumers therefore hold a ServiceRef:
//
//     SystemStats { id: stats }
//     ServiceRef  { service: stats; active: root.onScreen }
//
// `onVisibleChanged` used to trigger the reload and has been removed. An Item
// inside a hidden window still reports visible: true, so that hook fires for a
// dashboard nobody has opened and never fires again when the page is genuinely
// revealed a second time. It is the exact trap ServiceRef.qml's header warns
// about, and it has already shipped twice in this repo.

Item {
    id: root

    // ── ServiceRef contract ───────────────────────────────────────────────────
    // Held by whatever is displaying these rows. > 0 means a human can actually
    // see them, which is when a fresh read is worth a subprocess.
    property int refCount: 0

    onRefCountChanged: {
        if (root.refCount > 0) root.reload()
        else                   statsProc.running = false
    }

    // Rows as parsed from the collector, before the WM row is spliced in.
    property var _statsRows: []

    // "Hyprland 0.56.2", or just the name until version() answers, or
    // XDG_CURRENT_DESKTOP where there is no adapter at all. Never empty, so
    // the row is never missing — which is what the old script guaranteed with
    // its `${XDG_CURRENT_DESKTOP:-Wayland}` fallback.
    readonly property string _wmFallback:
        Quickshell.env("XDG_CURRENT_DESKTOP") || "Wayland"
    property string _wmValue: root._wmFallback

    // Rendered rows: the collector's, with WM inserted directly after Kernel
    // where the script used to print it.
    readonly property var rows: {
        const out = []
        for (let i = 0; i < root._statsRows.length; i++) {
            out.push(root._statsRows[i])
            if (root._statsRows[i].key === "Kernel")
                out.push({ key: "WM", value: root._wmValue })
        }
        return out
    }

    function reload() {
        root._statsRows = []
        // false-then-true, not a bare `true`: assigning true to a Process that
        // is already running is a no-op, so a second reveal would keep showing
        // the first read's uptime. Same restart idiom as CompositorService's
        // version and helper processes.
        statsProc.running = false
        statsProc.running = true

        const name = CompositorService.displayName
        root._wmValue = name !== "" ? name : root._wmFallback
        if (name === "") return

        // (false, "") is the answer when the compositor's CLI is missing or
        // cannot be executed — the name alone is still correct, so the row
        // stays rather than reverting to the environment string.
        CompositorService.version(function (ok, v) {
            if (ok && v !== "") root._wmValue = name + " " + v
        })
    }

    // Strip ANSI escape codes just in case
    function stripAnsi(str) {
        return str.replace(/\x1B\[[0-9;]*[mGKHF]/g, "")
    }

    function parse(raw) {
        var lines = stripAnsi(raw).split("\n")
        var result = []
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            if (line === "") continue
            var sep = line.indexOf(": ")
            if (sep === -1) continue
            result.push({
                key:   line.substring(0, sep).trim(),
                value: line.substring(sep + 2).trim()
            })
        }
        return result
    }

    // Native collector — one lightweight shell invocation emits "Key: Value"
    // lines. All values come from fixed system commands (no data interpolation).
    // The WM row is NOT here; see the header.
    Process {
        id: statsProc
        command: ["bash", "-c",
            ". /etc/os-release 2>/dev/null; " +
            "printf 'Distro: %s\\n' \"${PRETTY_NAME:-Linux}\"; " +
            "printf 'Kernel: %s\\n' \"$(uname -r)\"; " +
            "printf 'Uptime: %s\\n' \"$(uptime -p | sed 's/up //; s/ hours\\?/h/; s/ minutes\\?/m/; s/ days\\?/d/; s/, / /g')\"; " +
            "if command -v xbps-query >/dev/null 2>&1; then printf 'Packages: %s\\n' \"$(xbps-query -l 2>/dev/null | wc -l)\"; " +
            "elif command -v pacman >/dev/null 2>&1; then printf 'Packages: %s\\n' \"$(pacman -Qq 2>/dev/null | wc -l)\"; " +
            "elif command -v dpkg-query >/dev/null 2>&1; then printf 'Packages: %s\\n' \"$(dpkg-query -f '.\\n' -W 2>/dev/null | wc -l)\"; " +
            // Fedora / RHEL / openSUSE — APEX-OS's own base is Fedora bootc, so
            // without this branch the Packages row is simply missing there.
            "elif command -v rpm >/dev/null 2>&1; then printf 'Packages: %s\\n' \"$(rpm -qa 2>/dev/null | wc -l)\"; " +
            "elif command -v flatpak >/dev/null 2>&1; then printf 'Packages: %s\\n' \"$(flatpak list --app 2>/dev/null | wc -l)\"; fi; " +
            "printf 'Hostname: %s\\n' \"$(cat /etc/hostname 2>/dev/null || uname -n)\""]

        // A CONSTANT false, deliberately not `running: root.refCount > 0`.
        // reload() drives this imperatively, and an imperative assignment to a
        // bound property destroys the binding — after which the refcount would
        // still increment and decrement while the gate it was supposed to
        // control had silently stopped existing. Nothing errors; the poller
        // just never stops again. So the gate lives in onRefCountChanged, which
        // is the only writer, rather than being half binding and half
        // assignment.
        running: false

        stdout: StdioCollector {
            id: statsOut
            onStreamFinished: root._statsRows = root.parse(statsOut.text)
        }
    }

    // Row height, named once so the intrinsic height below cannot drift from
    // the delegate that actually draws them.
    readonly property int rowHeight: 36

    // An intrinsic height, so this can be dropped into a Column that sizes to
    // its children — a CfgSection, say — instead of only working where the
    // caller already knows how many rows there will be. Zero rows is zero
    // height, which is what should happen before the collector answers.
    implicitHeight: root.rows.length * root.rowHeight
    implicitWidth:  200

    // --- Rows ---
    Column {
        anchors {
            left:   parent.left
            right:  parent.right
            top:    parent.top
        }
        spacing: 0

        Repeater {
            model: root.rows

            delegate: Item {
                width:  parent.width
                height: root.rowHeight

                // Subtle alternating background
                Rectangle {
                    anchors.fill: parent
                    radius:       Theme.cornerRadius
                    color:        index % 2 === 0
                                      ? Qt.rgba(1, 1, 1, 0.04)
                                      : "transparent"
                }

                // Key
                Text {
                    id: keyText
                    anchors {
                        left:           parent.left
                        leftMargin:     10
                        verticalCenter: parent.verticalCenter
                    }
                    text:            modelData.key
                    color:           Theme.active
                    font.pixelSize:  Theme.fs(12)
                    font.bold:       true
                    width:           90
                    elide:           Text.ElideRight
                }

                // Separator dot
                Text {
                    id: dot
                    anchors {
                        left:           keyText.right
                        verticalCenter: parent.verticalCenter
                    }
                    text:  "·"
                    color: Qt.rgba(1, 1, 1, 0.25)
                    font.pixelSize: Theme.fs(12)
                }

                // Value
                Text {
                    anchors {
                        left:           dot.right
                        leftMargin:     6
                        right:          parent.right
                        rightMargin:    10
                        verticalCenter: parent.verticalCenter
                    }
                    text:            modelData.value
                    color:           Theme.text
                    font.pixelSize:  Theme.fs(12)
                    elide:           Text.ElideRight
                }
            }
        }
    }
}
