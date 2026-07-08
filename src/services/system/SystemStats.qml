import QtQuick
import Quickshell.Io
import "../../"

// Gathers system info natively (no fastfetch dependency) into key/value rows
// and renders them styled. The collector script emits one "Key: Value" line per
// field — we split on ": " (first occurrence).

Item {
    id: root

    onVisibleChanged: if (visible) reload()

    // Parsed rows: [{key, value}]
    property var rows: []

    function reload() {
        root.rows = []
        statsProc.running = true
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
    Process {
        id: statsProc
        command: ["bash", "-c",
            ". /etc/os-release 2>/dev/null; " +
            "printf 'Distro: %s\\n' \"${PRETTY_NAME:-Linux}\"; " +
            "printf 'Kernel: %s\\n' \"$(uname -r)\"; " +
            "hv=$(hyprctl version 2>/dev/null | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+' | head -n1); " +
            "if [ -n \"$hv\" ]; then printf 'WM: Hyprland %s\\n' \"$hv\"; " +
            "elif [ -n \"$HYPRLAND_INSTANCE_SIGNATURE\" ]; then printf 'WM: Hyprland\\n'; " +
            "else printf 'WM: %s\\n' \"${XDG_CURRENT_DESKTOP:-Wayland}\"; fi; " +
            "printf 'Uptime: %s\\n' \"$(uptime -p | sed 's/up //; s/ hours\\?/h/; s/ minutes\\?/m/; s/ days\\?/d/; s/, / /g')\"; " +
            "if command -v xbps-query >/dev/null 2>&1; then printf 'Packages: %s\\n' \"$(xbps-query -l 2>/dev/null | wc -l)\"; " +
            "elif command -v pacman >/dev/null 2>&1; then printf 'Packages: %s\\n' \"$(pacman -Qq 2>/dev/null | wc -l)\"; " +
            "elif command -v dpkg-query >/dev/null 2>&1; then printf 'Packages: %s\\n' \"$(dpkg-query -f '.\\n' -W 2>/dev/null | wc -l)\"; fi; " +
            "printf 'Hostname: %s\\n' \"$(cat /etc/hostname 2>/dev/null || uname -n)\""]
        running: true

        stdout: StdioCollector {
            id: statsOut
            onStreamFinished: root.rows = root.parse(statsOut.text)
        }
    }

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
                height: 36

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
                    font.pixelSize:  12
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
                    font.pixelSize: 12
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
                    font.pixelSize:  12
                    elide:           Text.ElideRight
                }
            }
        }
    }
}
