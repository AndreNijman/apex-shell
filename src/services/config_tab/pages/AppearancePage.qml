import QtQuick
import "../../../"
import "../../"
import "../../../components/config"

// Config → Appearance
//   • Live palette preview (matugen output)
//   • Wallpaper strip (apply on click)
//   • Matugen colour scheme (re-themes from the wallpaper)
//   • Shape sliders — corner radius / border / notch — reflow the shell live
CfgScroll {
    id: root

    // ── Palette ───────────────────────────────────────────────────────────────
    CfgSection {
        title: "Palette"
        first: true

        Item {
            width:  parent.width
            height: 62

            Row {
                anchors.left:           parent.left
                anchors.leftMargin:     10
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

        CfgRow {
            label:       "Reset"
            description: "Use the desktop wallpaper on the lock screen"
            CfgButton {
                label: "Clear"
                icon:  "󰆴"
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

            Text {
                anchors.centerIn: parent
                visible: WallpaperService.wallpapers.length === 0
                text:    WallpaperService.applying ? "Applying…" : "No wallpapers in " + WallpaperService.wallpaperDir
                font.pixelSize: Theme.fs(11)
                color:   Qt.rgba(1,1,1,0.3)
            }

            ListView {
                id: wallStrip
                anchors.fill:        parent
                anchors.leftMargin:  10
                anchors.rightMargin: 4
                orientation:  ListView.Horizontal
                spacing:      8
                clip:         true
                boundsBehavior: Flickable.StopAtBounds
                model:        WallpaperService.wallpapers

                delegate: Item {
                    required property string modelData
                    width:  118
                    height: 70
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

                    readonly property bool active: WallpaperService.currentWall === modelData

                    Rectangle {
                        anchors.fill: parent
                        radius:       10
                        color:        Qt.rgba(1,1,1,0.04)
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
                                : Qt.rgba(1,1,1,0.4)

                            // The same selection ring as WallpaperPopup's thumbnail
                            // grid, which is the other place this control exists.
                            // That one eases; this one snapped its border on and off,
                            // so the two wallpaper pickers felt like different
                            // widgets. Same properties, same 120ms.
                            Behavior on border.color { ColorAnimation  { duration: 120 } }
                            Behavior on border.width { NumberAnimation { duration: 120 } }
                        }
                    }
                    HoverHandler { id: wh; cursorShape: Qt.PointingHandCursor }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape:  Qt.PointingHandCursor
                        onClicked:    if (!WallpaperService.applying) WallpaperService.apply(modelData)
                    }
                }
            }
        }
    }

    // ── Colour scheme ─────────────────────────────────────────────────────────
    CfgSection {
        title: "Colour scheme"

        Item { width: parent.width; height: 4 }

        Text {
            width:          parent.width
            leftPadding:    10
            text:           "How matugen derives the palette from your wallpaper."
            font.pixelSize: Theme.fs(10)
            color:          Qt.rgba(1,1,1,0.4)
            wrapMode:       Text.WordWrap
        }
        Item { width: parent.width; height: 8 }

        Item {
            width:  parent.width
            height: schemeSeg.implicitHeight

            CfgSegmented {
                id: schemeSeg
                x:     10
                width: parent.width - 20
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

        Item { width: parent.width; height: 6 }
        Item {
            width:  parent.width
            height: 30
            CfgButton {
                x: 10
                label:   "Reset shape to defaults"
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
