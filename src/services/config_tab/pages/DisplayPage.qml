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
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


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

    // ── Shell scaling across a mixed desk (P1-040) ───────────────────────────
    //
    // What this section says HAD to change when the shell learned to size
    // itself per output, and it is worth saying why rather than just editing
    // the string. It used to tell the user that "APEX Shell has one size to
    // give, so its bar and panels will be wrong on at least one of them". That
    // was true and it is now false: every surface resolves its own output's
    // factor, and a 4K beside a 1080p at compositor scale 1 gets a 60px bar and
    // a 40px bar. A page that keeps warning about a defect that has been fixed
    // is worse than one that never mentioned it.
    //
    // What is still true is the part that was never about the shell: every
    // OTHER application on the desk is drawn at the compositor's scale, so on
    // an output at scale 1 with twice the pixel density, their text and
    // controls really are half the size. That is what the recommended scales
    // fix, and it is a display setting rather than a shell setting, which is
    // why it is on this page. Staged like everything else here — the commit
    // bar's Apply is what reaches the hardware, with the countdown and the
    // rollback that go with it.
    CfgSection {
        title: "Shell scaling"
        visible: DisplayService.loaded && DisplayService.draft.length > 0
        first: root.nothingAbove && DisplayService.draft.length > 0

        CfgRow {
            label: "Mixed display densities"
            description: DisplayService.scalesDisagree
                ? "These displays land in different size classes. APEX Shell "
                  + "sizes its bar and panels for each display separately, so "
                  + "it is the right size on all of them — but your other "
                  + "applications are drawn at the display's own scale, so they "
                  + "will look smaller on the denser one. Putting each display "
                  + "on its recommended scale fixes that too."
                : "Every enabled display lands in the same size class, so the "
                  + "shell and your applications are the same size on all of "
                  + "them."
            // Not a warning any more. A mixed desk is a thing to know about,
            // not a fault in the shell: the shell is correct on both outputs.
            statusWarns: false
            status: DisplayService.scalesDisagree ? "Mixed" : ""
            hoverable: false
        }

        CfgRow {
            label:       "Recommended scales"
            description: DisplayService.offRecommendation === 0
                ? "Every display is already on the scale APEX Shell would pick."
                : DisplayService.offRecommendation
                  + (DisplayService.offRecommendation === 1
                        ? " display is not on it." : " displays are not on it.")
                  + " Staging it here does not change anything until you apply."
            CfgButton {
                label:   "Use recommended scales"
                icon:    "󰍹"
                enabled: DisplayService.offRecommendation > 0
                onClicked: DisplayService.stageRecommendedScales()
            }
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
            // Never the top of the page any more: the Shell scaling section
            // above is visible whenever there is an output card to be below it.
            first: false

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
                label: "Scale"
                // The recommendation is per output and it is arithmetic, not a
                // taste: the value that brings this panel's LOGICAL size into
                // the band APEX Shell's own token set was calibrated against.
                description: {
                    const rec = DisplayService.recommendedScale(card.out)
                    const now = Number(card.out.scale || 1)
                    const m   = card.out.mode || {}
                    if (!m.height) return "Fractional scaling is supported"
                    const logical = Math.round(m.height / (now > 0 ? now : 1))
                    const line = "This panel is " + m.width + "×" + m.height
                               + ", so the shell sees " + logical + " rows."
                    return now === rec
                        ? line + " That is the recommended " + rec + "×."
                        : line + " " + rec + "× is recommended."
                }
                visible: card.on
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

    // ── Colour (P1-041) ───────────────────────────────────────────────────────
    // NOT part of the draft, and deliberately outside the Apply/Save bar below.
    // Everything above is staged because a bad layout can leave the machine with
    // no usable output; a colour profile cannot. It also does not live in
    // display.json — colord owns it, in a database that outlives this shell — so
    // there is nothing for Save to write and nothing for Revert to put back.
    // Assigning takes effect when you press it, like every other settings page.
    //
    // WHAT THIS SECTION HONESTLY DELIVERS
    //
    // The assignment is stored in colord and reported back. It does NOT load the
    // calibration curve into the display hardware, and the section says so in
    // the engine's own words rather than leaving the user to discover it. Two
    // independent reasons, both measured: nothing on the image can load an ICC
    // curve (no xcalib, no argyll dispwin, no wl-gammactl — gammastep does
    // colour temperature and takes no ICC input), and on the wlroots
    // compositors the gamma LUT is a single slot that APEX's own Night Light
    // already occupies. Overstating this would be worse than omitting it: a
    // creator would trust a calibration that is not on screen.
    CfgSection {
        title: "Colour"
        visible: DisplayService.engineCanColour

        Component.onCompleted: DisplayService.refreshColour()

        // colord ships with the image and runs as a system service, and it has
        // profiles — six or seven come with the image. What it has none of is
        // DEVICES: measured on the L16, `colormgr get-devices` on a fresh
        // session prints nothing, because nothing on APEX had ever registered a
        // display with it. So the registered count is shown next to the profile
        // count on purpose. Profiles with no device to put them on is exactly
        // the state this section was written for, and a page that showed only
        // the profile list would look fully furnished while being unable to
        // apply any of them. Assigning is what creates the device.
        CfgRow {
            label: "Colour daemon"
            description: DisplayService.colordAvailable
                ? "colord is answering — " + DisplayService.colourProfiles.length
                  + " display profile(s) installed, "
                  + DisplayService.colordRegistered + " device(s) registered."
                  + (DisplayService.colordRegistered === 0
                        ? " Assigning a profile below is what registers the display."
                        : "")
                : "colord is not answering, so profiles cannot be stored or read."
            status: DisplayService.colourLoading ? "reading…" : ""
            hoverable: false
        }

        // ── The engine's sentence, verbatim ──────────────────────────────────
        //
        // A Text and not a CfgRow description, and that is the whole point of
        // this element rather than a style choice: CfgRow's description is
        // maximumLineCount 2 with ElideRight, and this sentence is ~300
        // characters. In a row it would be shown as its first two lines and an
        // ellipsis — so the page would claim to state the engine's reason and
        // would in fact hide the half that says the assignment is not on screen.
        // A truncated caveat is worse than none.
        //
        // It is also not paraphrased here. The engine is the only thing that
        // knows which of the two reasons applies on the running compositor
        // (missing loader, or a gamma LUT the night light already owns), and a
        // copy in the page is a claim that keeps being made after the engine
        // stops meaning it.
        Item {
            width: parent.width
            height: reason.visible ? reason.implicitHeight + theme.px(10) : 0
            visible: reason.visible

            Text {
                id: reason
                x:       theme.px(10)
                width:   parent.width - theme.px(20)
                anchors.verticalCenter: parent.verticalCenter
                visible: DisplayService.curveReason !== ""
                text:    "Calibration curve: " + DisplayService.curveReason
                font.pixelSize: theme.fs(10)
                color:   DisplayService.curveLoadable ? Theme.subtext : Theme.warning
                wrapMode: Text.WordWrap
            }
        }

        // What the last assign said, in the engine's words too. `colour-assign`
        // reports per-profile facts a generic success message would throw away
        // — "this profile carries no vcgt, so there is no curve to load even
        // where one could be" is the answer to the question actually being
        // asked, and it is specific to the profile just chosen.
        Text {
            x:       theme.px(10)
            width:   parent.width - theme.px(20)
            visible: text !== ""
            text:    DisplayService.colourError !== "" ? DisplayService.colourError
                                                       : DisplayService.colourNotice
            font.pixelSize: theme.fs(10)
            color:   DisplayService.colourError !== "" ? Theme.warning : Theme.info
            wrapMode: Text.WordWrap
            bottomPadding: theme.px(6)
        }

        Repeater {
            model: DisplayService.colourOutputs

            // A Column, so the pills sit BELOW the readout at the section's own
            // width instead of in the row's right-hand slot. CfgSegmented is a
            // Flow and can only wrap against a width it is given; in the slot it
            // gets childrenRect, lays six profile names in one line and pushes
            // the readout off the left of the row.
            Column {
                id: outCol
                required property var modelData
                readonly property var out: outCol.modelData

                width: parent ? parent.width : 0
                spacing: 2

                CfgRow {
                    label: outCol.out.name
                           + (outCol.out.model ? "  ·  " + outCol.out.model : "")
                    // The colord device id is worth showing: it is built from
                    // the EDID rather than the connector, so a profile follows
                    // the panel when it moves to another port, and a support
                    // question about "which device is this" has a visible
                    // answer.
                    description: {
                        const bits = ["colord device " + outCol.out.device]
                        const hdr = outCol.out.hdr
                        if (!hdr || !hdr.edid)
                            bits.push("no EDID — nothing plugged in, or a headless output")
                        else if (hdr.static_metadata)
                            bits.push("the panel advertises HDR static metadata")
                        else
                            bits.push("the panel advertises no HDR")
                        return bits.join("  ·  ")
                    }
                    status: outCol.out.profile
                        ? (outCol.out.profile.vcgt === true ? "has a gamma table"
                         : outCol.out.profile.vcgt === false ? "no gamma table"
                         : "profile file unreadable")
                        : "none"
                    statusWarns: !!outCol.out.profile
                                 && outCol.out.profile.vcgt === null
                    disabledReason: DisplayService.colordAvailable
                        ? "" : "colord is not answering"
                    hoverable: false
                }

                CfgSegmented {
                    x:       theme.px(10)
                    width:   parent.width - theme.px(20)
                    enabled: DisplayService.colordAvailable
                    opacity: DisplayService.colordAvailable ? 1.0 : 0.32
                    options: {
                        const opts = []
                        const ps = DisplayService.colourProfiles
                        for (let i = 0; i < ps.length; i++)
                            opts.push({ value: ps[i].id, label: ps[i].title })
                        return opts
                    }
                    // The id, not the title: the engine accepts either, but the
                    // id is what the readback compares against and two profiles
                    // may share a title.
                    value: outCol.out.profile ? outCol.out.profile.id : ""
                    onSelected: function(v) {
                        DisplayService.assignProfile(outCol.out.name, v)
                    }
                }

                Item { width: 1; height: theme.px(6) }
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
