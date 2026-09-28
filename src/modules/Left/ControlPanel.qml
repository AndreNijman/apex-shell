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

    // ── Rime logo ─────────────────────────────────────
    // Rime OS override (rime-logs 15-rime-logo.md): upstream renders the
    // per-distro nerd-font glyph from the map above. On Rime OS the brand is
    // Rime regardless of the Fedora base, so show the Rime "spark"
    // (src/assets/rime-logo.png). The glyph map stays as the fallback for
    // non-Rime hosts and when the asset is missing.
    readonly property string rimeLogo: Quickshell.shellDir + "/src/assets/rime-logo.png"

    // Glyph fallback is used only when the Rime logo image is not available.
    text: logo.status === Image.Ready
              ? ""
              : (distroGlyphs[distroId] !== undefined ? distroGlyphs[distroId] : "")
    label: "Rime menu"
    // The Rime mark is accent-coloured by design (brief §D.3's one exception).
    textColor: Theme.accentText

    // Hover and press. The other bar icons answer by lighting their glyph; this
    // one is an image drawn in the accent, so it had no answer at all (Andre,
    // 2026-09-27: "the rime button … when you hover should show its
    // interactable"). A soft state layer behind the mark — the controls' own
    // 6 % / 10 % — and the spark itself lifts a little.
    Rectangle {
        anchors.centerIn: parent
        width: root.height + theme.px(8)
        height: width
        radius: width / 2
        color: root.stateLayer()
        Behavior on color { MotionColor { role: "hover" } }
    }

    // The asset is a fixed chartreuse spark. Drawn raw it stayed green while the
    // rest of the bar followed the wallpaper, so it is recoloured to the live
    // accent rather than shipped in several colourways. The Image is the texture
    // provider only — MultiEffect does the drawing, so it is itself invisible.
    Image {
        id: logo
        anchors.centerIn: parent
        source: root.rimeLogo
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
        colorizationColor: root.hovered || root.pressed ? Qt.lighter(Theme.active, 1.25) : Theme.active
        Behavior on colorizationColor { MotionColor { role: "hover" } }
        visible: logo.status === Image.Ready
    }

    property var osRelease: FileView {
        path: "/etc/os-release"
        onLoaded: {
            var m = text().match(/^ID=["']?([A-Za-z0-9._-]+)["']?/m)
            if (m) root.distroId = m[1].toLowerCase()
        }
    }

    // The open state of the control that opened the power menu (brief §D.5:
    // the same rule on the left notch as on the right).
    OpenPill { shown: Popups.archMenuOpen }

    onClicked: {
        var next = !Popups.archMenuOpen
        Popups.closeAll()
        Popups.archMenuOpen = next
    }
}
