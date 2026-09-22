import QtQuick
import QtQuick.Effects
import Quickshell
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

    // ── APEX logo ─────────────────────────────────────
    // APEX-OS override (apex-logs 15-apex-logo.md): upstream renders the
    // per-distro nerd-font glyph from the map above. On APEX-OS the brand is
    // APEX regardless of the Fedora base, so show the APEX "spark"
    // (src/assets/apex-logo.png). The glyph map stays as the fallback for
    // non-APEX hosts and when the asset is missing.
    readonly property string apexLogo: Quickshell.shellDir + "/src/assets/apex-logo.png"

    // Glyph fallback is used only when the APEX logo image is not available.
    text: logo.status === Image.Ready
              ? ""
              : (distroGlyphs[distroId] !== undefined ? distroGlyphs[distroId] : "")
    textColor: Theme.active

    // The asset is a fixed chartreuse spark. Drawn raw it stayed green while the
    // rest of the bar followed the wallpaper, so it is recoloured to the live
    // accent rather than shipped in several colourways. The Image is the texture
    // provider only — MultiEffect does the drawing, so it is itself invisible.
    Image {
        id: logo
        anchors.centerIn: parent
        source: root.apexLogo
        // Keep the spark comfortably inside the IconBtn.
        width: 18
        height: 18
        fillMode: Image.PreserveAspectFit
        sourceSize.width: 36
        sourceSize.height: 36
        smooth: true
        mipmap: true
        visible: false
    }

    MultiEffect {
        source: logo
        anchors.fill: logo
        // colorization 1.0 replaces the hue outright and keeps the spark's own
        // luminance, so the shape survives on both light and dark accents.
        colorization: 1.0
        colorizationColor: Theme.active
        visible: logo.status === Image.Ready
    }

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
