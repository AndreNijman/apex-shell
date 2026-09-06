import QtQuick
import "../../../"
import "../../../theme"
import "../"
import "../../../components/config"

// Config → Display  (roadmap §18, settings parity)
//
// One model, ~/.config/apex-shell/display.json, applied live through hyprctl eval or
// wlr-randr and persisted as ~/.config/hypr/apex/monitors.lua plus a kanshi profile.
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

    // Criterion 1, in one line: this page holds changes until you ask for them.
    // The words come from settings-semantics.js so they are the same ones the
    // Blueprint and Keybinds pages use.
    lifecycle: "staged"
    // One place at a time: while there is a draft the failure belongs on the
    // bar, beside the intent it did not destroy, because that is where the user
    // pressed the button. With no draft there is no bar, and a read that could
    // not enumerate the outputs is about the page.
    lifecycleError: DisplayService.dirty ? "" : DisplayService.lastError

    // Whether the first output card is genuinely the top of the page. Two
    // sections can precede it and each one is conditional, so the flag has to
    // be one expression rather than two copies that drift.
    readonly property bool nothingAbove: DisplayService.confirmSeconds === 0
                                         && DisplayService.lastNotice === ""

    // Enumeration is on demand: DisplayService is constructed at startup now
    // (it has to settle an abandoned transaction), so the `list` has to be
    // asked for rather than run in every login.
    Component.onCompleted: DisplayService.refresh()

    // ── Confirmation ──────────────────────────────────────────────────────────
    // The buttons that answer the countdown are NOT here any more; they are a
    // layer-shell overlay on every output (src/windows/DisplayConfirm.qml).
    // This section is what is left over: an in-page echo, for the case where
    // the dialog is up on a monitor other than the one the settings window is
    // on. It answers "what is that countdown" without being the only way to
    // answer it — which is what it used to be, and why nobody ever saw it.
    CfgSection {
        title: "Waiting for you"
        first: true
        visible: DisplayService.confirmSeconds > 0

        CfgRow {
            label: "Keep this layout?"
            description: "Answer on screen. If you do nothing, the previous " +
                         "layout comes back in " + DisplayService.confirmSeconds +
                         (DisplayService.confirmSeconds === 1 ? " second." : " seconds.")
            hoverable: false
            CfgButton {
                label: "Keep it"
                onClicked: DisplayService.confirm()
            }
        }
    }

    // ── What happened without you ─────────────────────────────────────────────
    CfgSection {
        title: "Display"
        visible: DisplayService.lastNotice !== ""

        CfgRow {
            label: "Since the last time"
            description: DisplayService.lastNotice
            hoverable: false
        }
    }

    // The read/apply error used to be a section of its own here. It is the
    // page's `lifecycleError` now — the same line every settings page reports a
    // refused write on — so a reader who has seen one page has seen them all.

    // ── No outputs ────────────────────────────────────────────────────────────
    CfgSection {
        title: "Outputs"
        first: root.nothingAbove
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
            first: card.index === 0 && root.nothingAbove

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

    // ── The draft ─────────────────────────────────────────────────────────────
    // Three CfgRows with three buttons became one bar. The words, the order and
    // the sentence above them are CfgCommit's, shared with Blueprint and
    // Keybinds; what stays here is the part only this page knows — that Save
    // writes files a login or a hotplug reads, and how long the countdown runs.
    CfgCommit {
        count: DisplayService.stagedCount
        noun:  "change"

        canApply: true
        canSave:  true

        // Also inert while a countdown is running: the previous apply has not
        // been answered yet, and the answer is on the confirmation window.
        busy:  DisplayService.applying || DisplayService.confirmSeconds > 0
        error: DisplayService.lastError

        // "module", not "conf": P0-018 made the Hyprland artifact a Lua module
        // at ~/.config/hypr/apex/monitors.lua. The sentence is the only part of
        // the bar this page owns, so this is where that fact belongs.
        note: "Do nothing after an apply and the previous layout comes back in "
              + DisplayService.confirmTotal + " seconds. Save writes the "
              + "Hyprland monitor module and the kanshi profile, which the next "
              + "login or hotplug reads."

        onApplyRequested:  DisplayService.apply()
        onSaveRequested:   DisplayService.save()
        onRevertRequested: DisplayService.revert()
    }
}
