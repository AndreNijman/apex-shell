import QtQuick
import "../../../"
import "../../"
import "../../../components"
import "../../../components/config"
import "../../../components/controls"

// Config → Appearance
//   • Live palette preview (matugen output)
//   • Wallpaper strip (apply on click)
//   • Matugen colour scheme (re-themes from the wallpaper)
//   • Shape sliders — corner radius / border / notch — reflow the shell live
CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    // ── Keyboard (UI/UX roadmap v3 Phase 21) ─────────────────────────────────
    // The wallpaper strip is ONE Tab stop: Left/Right move a highlight kept by
    // the wallpaper's own path (a stable key — a rescan can reorder the list),
    // Return/Space applies it. It is a single horizontal row, so Up/Down do
    // nothing here (there is no second row to jump to).
    property string _curWall: ""

    function _stepWall(d) {
        var list = WallpaperService.wallpapers
        if (list.length === 0) return
        var i = list.indexOf(root._curWall)
        root._curWall = i < 0 ? list[d > 0 ? 0 : list.length - 1]
                              : list[Math.max(0, Math.min(list.length - 1, i + d))]
    }


    // Criterion 1. Everything on this page writes as you touch it and is
    // persisted; the one line at the top says so, in the same words the other
    // five live pages use.
    lifecycle: "live"
    lifecycleError: SettingsService.lastError

    // ── Palette ───────────────────────────────────────────────────────────────
    CfgSection {
        title: "Palette"
        first: true

        Item {
            width:  parent.width
            height: 62

            Row {
                anchors.left:           parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 14

                CfgSwatch { swatchColor: Theme.background; label: "bg" }
                CfgSwatch { swatchColor: Theme.active;     label: "accent" }
                CfgSwatch { swatchColor: Theme.text;       label: "text" }
                CfgSwatch { swatchColor: Theme.subtext;    label: "subtext" }
                CfgSwatch { swatchColor: Theme.icon;       label: "icon" }
                CfgSwatch { swatchColor: Theme.border;     label: "border" }
                CfgSwatch { swatchColor: Theme.iconFont;   label: "iconfont" }
            }
        }
    }

    // ── Wallpaper ─────────────────────────────────────────────────────────────
    CfgSection {
        title: "Lock screen"

        CfgRow {
            label:       "Background"
            description: SettingsService.lockBackground === ""
                             ? "Follows the desktop wallpaper"
                             : SettingsService.lockBackground.split("/").pop()

            CfgTextField {
                text:        SettingsService.lockBackground
                placeholder: "/path/to/image.jpg"
                onAccepted:  function(t) { SettingsService.set("lockBackground", t.trim()) }
                onEdited:    function(t) { SettingsService.set("lockBackground", t.trim()) }
            }
        }

        // Reset, and it is really Reset: the shipped default for this key is
        // the empty string, which means "follow the desktop wallpaper". The row
        // said Reset and the button said Clear, which are two words for one act
        // and neither of them was the one every other page uses.
        CfgRow {
            label:       "Lock background"
            description: "Return to the shipped default: the desktop wallpaper"
            CfgButton {
                label: "Reset"
                icon:  "↺"
                onClicked: SettingsService.set("lockBackground", "")
            }
        }
    }

    CfgSection {
        title: "Wallpaper"

        // Current name + refresh
        CfgRow {
            label:       "Current"
            description: {
                var p = WallpaperService.currentWall
                if (!p) return "No wallpaper set"
                return p.split("/").pop()
            }
            CfgButton {
                icon:  "󰑐"
                label: "Rescan"
                onClicked: WallpaperService.refresh()
            }
        }

        // Thumbnail strip
        Item {
            width:  parent.width
            height: 78

            // The shared empty state, inline (UI/UX Phase 17): on the content
            // edge like the rows, not a centred tertiary line in the strip's slot.
            EmptyState {
                anchors.left: parent.left; anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                inline:  true
                visible: WallpaperService.wallpapers.length === 0
                title:   WallpaperService.applying ? "Applying…" : "No wallpapers in " + WallpaperService.wallpaperDir
                hint:    WallpaperService.applying ? "" : "Add images there, then Rescan."
            }

            ListView {
                id: wallStrip
                anchors.fill:        parent
                anchors.rightMargin: 4
                orientation:  ListView.Horizontal
                spacing:      8
                clip:         true
                boundsBehavior: Flickable.StopAtBounds
                model:        WallpaperService.wallpapers

                // Its own currentIndex/arrow handling would fight the stable-
                // path highlight below (WallpaperService.wallpapers can
                // reorder on a rescan, so an index is not a safe key).
                keyNavigationEnabled: false
                activeFocusOnTab: WallpaperService.wallpapers.length > 0
                Accessible.role: Accessible.List
                Accessible.name: "Wallpapers"
                onActiveFocusChanged: if (activeFocus
                        && WallpaperService.wallpapers.indexOf(root._curWall) < 0)
                    root._stepWall(1)
                Keys.onPressed: function (event) {
                    // A single row: Up/Down have nowhere to go, so they are
                    // left unaccepted rather than eaten.
                    var flip = wallStrip.LayoutMirroring.enabled ? -1 : 1
                    var list = WallpaperService.wallpapers
                    if      (event.key === Qt.Key_Right) root._stepWall(flip)
                    else if (event.key === Qt.Key_Left)  root._stepWall(-flip)
                    else if (event.key === Qt.Key_Home && list.length > 0) root._curWall = list[0]
                    else if (event.key === Qt.Key_End   && list.length > 0) root._curWall = list[list.length - 1]
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                             || event.key === Qt.Key_Space) {
                        if (!WallpaperService.applying && root._curWall !== "")
                            WallpaperService.apply(root._curWall)
                    } else return
                    event.accepted = true
                    var idx = list.indexOf(root._curWall)
                    if (idx >= 0) wallStrip.positionViewAtIndex(idx, ListView.Contain)
                }

                delegate: Item {
                    id: thumb
                    required property string modelData
                    width:  118
                    height: 70
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

                    readonly property bool active: WallpaperService.currentWall === modelData
                    // ApexFocusRing's contract: radius + focusVisible. The
                    // container (wallStrip) is the actual Tab stop; this is
                    // never itself focused, so focusVisible just tracks
                    // whether it is the keyboard's current thumbnail.
                    readonly property real radius: 10
                    readonly property bool focusVisible: root._curWall === modelData && wallStrip.activeFocus

                    Accessible.role: Accessible.ListItem
                    Accessible.name: modelData.split("/").pop()
                    Accessible.selected: active

                    Rectangle {
                        anchors.fill: parent
                        radius:       10
                        color:        Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)
                        clip:         true

                        Image {
                            anchors.fill: parent
                            source:       "file://" + modelData
                            fillMode:     Image.PreserveAspectCrop
                            asynchronous: true
                            cache:        true
                            sourceSize.width:  236
                            sourceSize.height: 140
                        }
                        Rectangle {
                            anchors.fill: parent
                            radius:       10
                            color:        "transparent"
                            border.width: parent.parent.active ? 2 : (wh.hovered ? 1 : 0)
                            border.color: parent.parent.active
                                ? Theme.active
                                : Qt.rgba(Theme.fixedLight.r, Theme.fixedLight.g, Theme.fixedLight.b, 0.4) // on a fixed surface

                            // The same selection ring as WallpaperPopup's thumbnail
                            // grid, which is the other place this control exists.
                            // That one eases; this one snapped its border on and off,
                            // so the two wallpaper pickers felt like different
                            // widgets. Same properties, same 120ms.
                            Behavior on border.color { MotionColor { role: "state" } }
                            Behavior on border.width { MotionFade {} }
                        }
                    }
                    ApexFocusRing { target: thumb }
                    HoverHandler { id: wh; cursorShape: Qt.PointingHandCursor }
                    MouseArea {
                        anchors.fill: parent
                        onPressed: root._curWall = modelData
                        cursorShape:  Qt.PointingHandCursor
                        onClicked:    if (!WallpaperService.applying) WallpaperService.apply(modelData)
                    }
                }
            }
        }
    }

    // ── Light or dark ─────────────────────────────────────────────────────────
    // Withheld until every foreground in the shell followed the palette (the
    // translucent whites, UI/UX Phase 18); tests/agent-state-test.js keeps this
    // control tied to tests/check-color-tokens.sh's ban on them.
    CfgSection {
        title: "Light or dark"

        Item { width: parent.width; height: 4 }

        Text {
            width:          parent.width
            text:           "Which half of the wallpaper's palette the shell paints with. "
                          + "Changing this re-derives the colours from the wallpaper you are on."
            font.pixelSize: theme.typeCaption
            color:          Theme.textSecondary
            wrapMode:       Text.WordWrap
        }
        Item { width: parent.width; height: 8 }

        Item {
            width:  parent.width
            height: modeSeg.implicitHeight

            CfgSegmented {
                id: modeSeg
                width: parent.width
                options: WallpaperService.modes
                value:   WallpaperService.mode
                onSelected: function(v) { WallpaperService.setMode(v) }
            }
        }
    }

    // ── Colour scheme ─────────────────────────────────────────────────────────
    CfgSection {
        title: "Colour scheme"

        Item { width: parent.width; height: 4 }

        Text {
            width:          parent.width
            text:           "How matugen derives the palette from your wallpaper."
            font.pixelSize: theme.typeCaption
            color:          Theme.textSecondary
            wrapMode:       Text.WordWrap
        }
        Item { width: parent.width; height: 8 }

        Item {
            width:  parent.width
            height: schemeSeg.implicitHeight

            CfgSegmented {
                id: schemeSeg
                width: parent.width
                options: WallpaperService.schemes
                value:   WallpaperService.scheme
                onSelected: function(v) {
                    WallpaperService.scheme = v
                    if (WallpaperService.currentWall !== "")
                        WallpaperService.apply(WallpaperService.currentWall)
                }
            }
        }
    }

    // ── Night light ───────────────────────────────────────────────────────────
    //
    // The dashboard tile is a switch and nothing else; this is where the
    // temperature lives, because it is a preference and not a thing you reach
    // for twice an evening. Both surfaces read and write the same two values, so
    // there is one night light and not two.
    CfgSection {
        title: "Night light"

        CfgRow {
            label: "Night light"
            description: CompositorService.nightLightSupported
                ? "Warms the screen using " + CompositorService.nightLightMechanism
                  + " on " + Compositor.name
                : "This session is not a compositor APEX Shell has a "
                  + "colour-temperature mechanism for, so there is nothing to warm "
                  + "the screen with."
            disabledReason: CompositorService.nightLightSupported
                ? "" : "No mechanism on this compositor"
            status:      CompositorService.nightLightError
            statusWarns: CompositorService.nightLightError !== ""

            CfgSwitch {
                checked: CompositorService.nightLightActive
                onToggled: function(v) { CompositorService.setNightLight(v) }
            }
        }

        CfgRow {
            label:       "Temperature"
            description: "Lower is warmer. 6500K is neutral — the screen is left alone."
            disabledReason: CompositorService.nightLightSupported
                ? "" : "No mechanism on this compositor"

            CfgSlider {
                from: 1000; to: 6500; step: 100; suffix: "K"
                readoutWidth: 56
                value: SettingsService.nightLightTemp
                onMoved: function(v) { CompositorService.setNightLightTemperature(v) }
            }
        }
    }

    // ── Shape (live reflow) ───────────────────────────────────────────────────
    CfgSection {
        title: "Shape"

        CfgRow {
            label:       "Corner radius"
            description: "Rounding of the shell's border & cards"
            CfgSlider {
                from: 0; to: 40; step: 1; suffix: "px"
                value: SettingsService.cornerRadius
                onMoved: function(v) { SettingsService.set("cornerRadius", v) }
            }
        }
        CfgRow {
            label:       "Border thickness"
            description: "Width of the screen-edge frame"
            CfgSlider {
                from: 0; to: 24; step: 1; suffix: "px"
                value: SettingsService.borderWidth
                onMoved: function(v) { SettingsService.set("borderWidth", v) }
            }
        }
        CfgRow {
            label: "Notch radius"
            CfgSlider {
                from: 0; to: 30; step: 1; suffix: "px"
                value: SettingsService.notchRadius
                onMoved: function(v) { SettingsService.set("notchRadius", v) }
            }
        }
        CfgRow {
            label: "Notch height"
            CfgSlider {
                from: 24; to: 72; step: 1; suffix: "px"
                value: SettingsService.notchHeight
                onMoved: function(v) { SettingsService.set("notchHeight", v) }
            }
        }

        // A CfgRow rather than a bare button in a spacer, so it says what it
        // resets and reads like the Layout page's, which resets the same way.
        CfgRow {
            label:       "Shape"
            description: "Return the corner radius, border, notch radius and " +
                         "notch height to the shipped defaults"
            CfgButton {
                label:   "Reset"
                icon:    "↺"
                onClicked: {
                    SettingsService.set("cornerRadius", 17)
                    SettingsService.set("borderWidth",  6)
                    SettingsService.set("notchRadius",  15)
                    SettingsService.set("notchHeight",  40)
                }
            }
        }
    }

    Item { width: parent.width; height: 10 }
}
