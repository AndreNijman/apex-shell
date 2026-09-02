import QtQuick
import "../../../"
import "../../../theme"
import "../"
import "../../../components/config"

// Config → Display  (roadmap §18, settings parity)
//
// One model, ~/.config/apex-shell/display.json, applied live through hyprctl or
// wlr-randr and persisted as a Hyprland monitor conf plus a kanshi profile.
// Nothing here knows which compositor is running.
//
// THIS PAGE DOES NOT WRITE AS YOU DRAG
//
// Every other settings page does, and that is right for them. It is wrong here:
// a bad display setting can leave the machine with no usable output, and the
// control to undo it is on the output that just disappeared. So changes are
// STAGED, applied on request, and reverted automatically unless confirmed.
//
// There is also a Save that writes persistence without touching hardware, which
// is the safe way to set up a layout for a monitor that is not plugged in yet.
CfgScroll {
    id: root

    // ── Confirmation ──────────────────────────────────────────────────────────
    // First, and unmissable: while this is up the user may be looking at a
    // broken or blank screen, and everything else on the page is irrelevant.
    CfgSection {
        title: "Keep this layout?"
        first: true
        visible: DisplayService.confirmSeconds > 0

        CfgRow {
            label: "Reverting in " + DisplayService.confirmSeconds + "s"
            description: "If you cannot read this, do nothing and the previous " +
                         "layout comes back on its own."
            hoverable: false
            CfgButton {
                label: "Keep it"
                onClicked: DisplayService.confirm()
            }
        }
        CfgRow {
            label: "Put it back now"
            description: "Restores the layout that was on screen before Apply"
            CfgButton {
                label: "Revert"
                variant: "danger"
                onClicked: DisplayService.revertApplied()
            }
        }
    }

    // ── Errors ────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Display"
        visible: DisplayService.lastError !== ""

        CfgRow {
            label: "Could not read or set the layout"
            description: DisplayService.lastError
            hoverable: false
        }
    }

    // ── No outputs ────────────────────────────────────────────────────────────
    CfgSection {
        title: "Outputs"
        first: DisplayService.confirmSeconds === 0 && DisplayService.lastError === ""
        visible: DisplayService.loaded && DisplayService.draft.length === 0

        CfgRow {
            label: "No outputs reported"
            description: "This session has no wlr-output-management support, " +
                         "or neither wlr-randr nor hyprctl is available."
            hoverable: false
        }
    }

    // ── One section per output ────────────────────────────────────────────────
    Repeater {
        model: DisplayService.draft

        delegate: CfgSection {
            id: card

            required property var modelData
            required property int index

            readonly property var out: modelData
            readonly property bool on: card.out.enabled !== false

            title: (card.out.name || "?") +
                   (card.out.model && card.out.model !== "" ? "  ·  " + card.out.model : "")
            first: card.index === 0
                   && DisplayService.confirmSeconds === 0
                   && DisplayService.lastError === ""

            CfgRow {
                label:       "Enabled"
                description: card.out.description || card.out.name || ""
                CfgSwitch {
                    checked: card.on
                    onToggled: function(v) {
                        DisplayService.stage(card.out.name, "enabled", v)
                    }
                }
            }

            CfgRow {
                label:       "Mode"
                description: DisplayService.modeLabel(card.out.mode)
                             + (card.out.modes ? "  ·  " + card.out.modes.length + " available" : "")
                visible:     card.on
                CfgSegmented {
                    // Only the distinct resolutions, highest refresh first: a
                    // real panel reports thirty modes and a segmented control
                    // of thirty is not a control.
                    options: {
                        const seen = {}
                        const out2 = []
                        const modes = card.out.modes || []
                        for (let i = 0; i < modes.length; i++) {
                            const m = modes[i]
                            const key = m.width + "x" + m.height
                            if (seen[key] !== undefined) continue
                            seen[key] = true
                            out2.push({
                                value: i,
                                label: m.width + "×" + m.height
                            })
                            if (out2.length >= 6) break
                        }
                        return out2
                    }
                    value: DisplayService.currentModeIndex(card.out)
                    onSelected: function(v) {
                        DisplayService.stageMode(card.out.name, v)
                    }
                }
            }

            CfgRow {
                label:       "Refresh"
                description: "Rates offered at this resolution"
                visible:     card.on
                CfgSegmented {
                    options: {
                        const cur = card.out.mode
                        if (!cur) return []
                        const out2 = []
                        const modes = card.out.modes || []
                        for (let i = 0; i < modes.length; i++) {
                            const m = modes[i]
                            if (m.width !== cur.width || m.height !== cur.height) continue
                            out2.push({
                                value: i,
                                label: Number(m.refresh).toFixed(0) + " Hz"
                            })
                        }
                        return out2
                    }
                    value: DisplayService.currentModeIndex(card.out)
                    onSelected: function(v) {
                        DisplayService.stageMode(card.out.name, v)
                    }
                }
            }

            CfgRow {
                label:       "Scale"
                description: "Fractional scaling is supported; 1.5 and 1.75 are " +
                             "the usual choices on a high-DPI panel"
                visible:     card.on
                CfgSlider {
                    value:  Number(card.out.scale || 1)
                    from:   0.5
                    to:     3.0
                    step:   0.05
                    suffix: "×"
                    onMoved: function(v) {
                        DisplayService.stage(card.out.name, "scale", v)
                    }
                }
            }

            CfgRow {
                label:       "Rotation"
                visible:     card.on
                CfgSegmented {
                    options: DisplayService.transforms
                    value:   String(card.out.transform || "normal")
                    onSelected: function(v) {
                        DisplayService.stage(card.out.name, "transform", v)
                    }
                }
            }

            CfgRow {
                label:       "Variable refresh rate"
                description: "Adaptive sync / FreeSync, where the panel supports it"
                visible:     card.on
                CfgSwitch {
                    checked: !!card.out.adaptive_sync
                    onToggled: function(v) {
                        DisplayService.stage(card.out.name, "adaptive_sync", v)
                    }
                }
            }

            // Position is numeric rather than a drag-to-arrange canvas. A
            // canvas is the nicer interaction and a much larger piece of work;
            // saying "not yet" beats shipping a half one that cannot express
            // vertical stacking.
            CfgRow {
                label:       "Position"
                description: "Top-left corner in the combined desktop, in pixels"
                visible:     card.on
                CfgTextField {
                    text: Math.round(card.out.x || 0) + "," + Math.round(card.out.y || 0)
                    onAccepted: function(t) {
                        const parts = String(t).split(",")
                        if (parts.length !== 2) return
                        const x = parseInt(parts[0].trim(), 10)
                        const y = parseInt(parts[1].trim(), 10)
                        if (isNaN(x) || isNaN(y)) return
                        DisplayService.stage(card.out.name, "x", x)
                        DisplayService.stage(card.out.name, "y", y)
                    }
                }
            }
        }
    }

    // ── Apply ─────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Changes"
        visible: DisplayService.draft.length > 0

        CfgRow {
            label: DisplayService.dirty ? "Not applied yet" : "Nothing staged"
            description: DisplayService.dirty
                ? "Apply reaches the running compositor and asks you to confirm. " +
                  "Save writes the layout without touching the screen."
                : "Change something above and Apply becomes available."
            hoverable: false
        }

        CfgRow {
            label:       "Apply now"
            description: "You will have 15 seconds to confirm"
            CfgButton {
                label:   DisplayService.applying ? "Applying…" : "Apply"
                enabled: DisplayService.dirty && !DisplayService.applying
                         && DisplayService.confirmSeconds === 0
                onClicked: DisplayService.apply()
            }
        }

        CfgRow {
            label:       "Save without applying"
            description: "Writes the Hyprland monitor conf and the kanshi profile. " +
                         "Takes effect at the next login or hotplug."
            CfgButton {
                label:   "Save"
                enabled: DisplayService.dirty && !DisplayService.applying
                onClicked: DisplayService.save()
            }
        }

        CfgRow {
            label:       "Discard"
            description: "Forget the staged changes and re-read the hardware"
            CfgButton {
                label:   "Revert"
                enabled: DisplayService.dirty
                onClicked: DisplayService.revert()
            }
        }
    }
}
