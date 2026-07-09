import QtQuick
import Quickshell.Io
import "../../components"
import "../../"

IconBtn {
    id: root

    // ── Distro logo (upstream hardcoded Arch) ─────────────────────────────────
    // Detected from /etc/os-release ID= and mapped to the nerd-font linux set;
    // unknown distros fall back to Tux. Tinted with the matugen accent so it
    // follows the wallpaper theme instead of a hardcoded brand color.
    property string distroId: ""
    readonly property var distroGlyphs: ({
        "void":        "",
        "arch":        "",
        "artix":       "",
        "nixos":       "",
        "debian":      "",
        "ubuntu":      "",
        "fedora":      "",
        "gentoo":      "",
        "opensuse":    "",
        "manjaro":     "",
        "endeavouros": "",
        "alpine":      ""
    })

    // Fallback: Tux, for distros not in the map.
    text: distroGlyphs[distroId] !== undefined ? distroGlyphs[distroId] : ""
    textColor: Theme.active

    property var osRelease: FileView {
        path: "/etc/os-release"
        onLoaded: {
            var m = text().match(/^ID=["']?([A-Za-z0-9._-]+)["']?/m)
            if (m) root.distroId = m[1].toLowerCase()
        }
    }

    onClicked: {
        var next = !Popups.archMenuOpen
        Popups.closeAll()
        Popups.archMenuOpen = next
    }
}
