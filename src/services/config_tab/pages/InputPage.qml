import QtQuick
import "../../../"
import "../../../theme"
import "../"
import "../../../components/config"

// Config → Input  (roadmap §18, settings parity)
//
// Every control writes one key of ~/.config/apex-shell/input.json, and
// InputService then runs /usr/libexec/apex-input-apply, which regenerates the
// Hyprland conf, the niri KDL and labwc's <libinput> block from that single
// model. Nothing on this page knows which compositor is running.
//
// The generator is the authority on validity: it clamps out-of-range values,
// replaces unknown enum values, and reports each correction. Those reports are
// shown at the top of the page rather than swallowed, because a slider that
// silently snaps back is indistinguishable from one that does not work.
CfgScroll {
    id: root

    // ── What the generator said ───────────────────────────────────────────────
    // Shown BEFORE the controls, not after: a correction the user has to scroll
    // to find is a correction they will not see.
    CfgSection {
        title: "Applied"
        first: true
        visible: InputService.applying || InputService.lastNotes !== ""

        CfgRow {
            label: InputService.applying ? "Applying…" : "The generator adjusted something"
            description: InputService.applying
                ? "Writing the model and regenerating every compositor config"
                : InputService.lastNotes
            hoverable: false
        }
    }

    // ── Touchpad ──────────────────────────────────────────────────────────────
    CfgSection {
        title: "Touchpad"
        first: !(InputService.applying || InputService.lastNotes !== "")

        CfgRow {
            label:       "Tap to click"
            description: "One finger taps left, and see the button map below"
            CfgSwitch {
                checked: InputService.tap
                onToggled: function(v) { InputService.set("tap", v) }
            }
        }

        CfgRow {
            label:       "Tap and drag"
            description: "Tap then slide to drag without holding the pad down"
            visible:     InputService.tap
            CfgSwitch {
                checked: InputService.tapAndDrag
                onToggled: function(v) { InputService.set("tapAndDrag", v) }
            }
        }

        CfgRow {
            label:       "Drag lock"
            description: "A drag survives lifting your finger briefly"
            visible:     InputService.tap && InputService.tapAndDrag
            CfgSwitch {
                checked: InputService.dragLock
                onToggled: function(v) { InputService.set("dragLock", v) }
            }
        }

        CfgRow {
            label:       "Tap button map"
            description: "Two- and three-finger taps"
            visible:     InputService.tap
            CfgSegmented {
                options: [
                    { value: "lrm", label: "L / R / M" },
                    { value: "lmr", label: "L / M / R" }
                ]
                value: InputService.tapButtonMap
                onSelected: function(v) { InputService.set("tapButtonMap", v) }
            }
        }

        CfgRow {
            label:       "Natural scrolling"
            description: "Content follows your fingers"
            CfgSwitch {
                checked: InputService.naturalScroll
                onToggled: function(v) { InputService.set("naturalScroll", v) }
            }
        }

        CfgRow {
            label:       "Scroll method"
            description: "How a scroll gesture is recognised"
            CfgSegmented {
                options: [
                    { value: "twofinger", label: "Two finger" },
                    { value: "edge",      label: "Edge"       },
                    { value: "none",      label: "Off"        }
                ]
                value: InputService.scrollMethod
                onSelected: function(v) { InputService.set("scrollMethod", v) }
            }
        }

        CfgRow {
            label:       "Scroll speed"
            description: "Multiplier applied to every scroll event"
            CfgSlider {
                value:  InputService.scrollFactor
                from:   0.1
                to:     10.0
                step:   0.1
                suffix: "×"
                onMoved: function(v) { InputService.set("scrollFactor", v) }
            }
        }

        CfgRow {
            label:       "Click method"
            description: InputService.clickMethod === "clickfinger"
                ? "Press anywhere; finger count picks the button"
                : "The bottom of the pad is split into button zones"
            CfgSegmented {
                options: [
                    { value: "clickfinger",  label: "Finger count" },
                    { value: "buttonAreas",  label: "Button areas" },
                    { value: "none",         label: "Off"          }
                ]
                value: InputService.clickMethod
                onSelected: function(v) { InputService.set("clickMethod", v) }
            }
        }

        CfgRow {
            label:       "Pointer speed"
            description: "Negative is slower than the driver default"
            CfgSlider {
                value:  InputService.padSpeed
                from:   -1.0
                to:     1.0
                step:   0.05
                onMoved: function(v) { InputService.set("padSpeed", v) }
            }
        }

        CfgRow {
            label:       "Acceleration"
            description: InputService.padAccelProfile === "flat"
                ? "One-to-one; no acceleration curve"
                : "Speed-dependent, the libinput default"
            CfgSegmented {
                options: [
                    { value: "adaptive", label: "Adaptive" },
                    { value: "flat",     label: "Flat"     }
                ]
                value: InputService.padAccelProfile
                onSelected: function(v) { InputService.set("padAccelProfile", v) }
            }
        }

        CfgRow {
            label:       "Disable while typing"
            description: "Ignore the pad for a moment after a keypress"
            CfgSwitch {
                checked: InputService.disableWhileTyping
                onToggled: function(v) { InputService.set("disableWhileTyping", v) }
            }
        }

        CfgRow {
            label:       "Three-finger drag"
            description: "Drag windows with three fingers"
            CfgSwitch {
                checked: InputService.threeFingerDrag
                onToggled: function(v) { InputService.set("threeFingerDrag", v) }
            }
        }

        CfgRow {
            label:       "Middle-click emulation"
            description: "Left and right together act as middle"
            CfgSwitch {
                checked: InputService.middleEmulation
                onToggled: function(v) { InputService.set("middleEmulation", v) }
            }
        }

        CfgRow {
            label:       "Left-handed"
            description: "Swap the primary and secondary buttons"
            CfgSwitch {
                checked: InputService.leftHandedPad
                onToggled: function(v) { InputService.set("leftHandedPad", v) }
            }
        }
    }

    // ── Mouse ─────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Mouse"

        // Said explicitly, because sharing it is the more obvious design and
        // the wrong one: inverting a wheel is not the same gesture as
        // inverting a two-finger swipe.
        CfgRow {
            label:       "Natural scrolling"
            description: "Separate from the touchpad's setting, on purpose"
            CfgSwitch {
                checked: InputService.pointerNaturalScroll
                onToggled: function(v) { InputService.set("pointerNaturalScroll", v) }
            }
        }

        CfgRow {
            label:       "Scroll speed"
            CfgSlider {
                value:  InputService.pointerScrollFactor
                from:   0.1
                to:     10.0
                step:   0.1
                suffix: "×"
                onMoved: function(v) { InputService.set("pointerScrollFactor", v) }
            }
        }

        CfgRow {
            label:       "Pointer speed"
            CfgSlider {
                value:  InputService.pointerSpeed
                from:   -1.0
                to:     1.0
                step:   0.05
                onMoved: function(v) { InputService.set("pointerSpeed", v) }
            }
        }

        CfgRow {
            label:       "Acceleration"
            description: InputService.pointerAccelProfile === "flat"
                ? "One-to-one; what most games expect"
                : "Speed-dependent, the libinput default"
            CfgSegmented {
                options: [
                    { value: "adaptive", label: "Adaptive" },
                    { value: "flat",     label: "Flat"     }
                ]
                value: InputService.pointerAccelProfile
                onSelected: function(v) { InputService.set("pointerAccelProfile", v) }
            }
        }

        CfgRow {
            label:       "Middle-click emulation"
            CfgSwitch {
                checked: InputService.pointerMiddleEmulation
                onToggled: function(v) { InputService.set("pointerMiddleEmulation", v) }
            }
        }

        CfgRow {
            label:       "Left-handed"
            description: "Swap the primary and secondary buttons"
            CfgSwitch {
                checked: InputService.leftHanded
                onToggled: function(v) { InputService.set("leftHanded", v) }
            }
        }
    }

    // ── Keyboard ──────────────────────────────────────────────────────────────
    CfgSection {
        title: "Keyboard"

        CfgRow {
            label:       "Repeat rate"
            description: "Characters per second once repeating starts"
            CfgSlider {
                value:  InputService.repeatRate
                from:   1
                to:     100
                step:   1
                suffix: "/s"
                onMoved: function(v) { InputService.set("repeatRate", Math.round(v)) }
            }
        }

        CfgRow {
            label:       "Repeat delay"
            description: "How long a key is held before it starts repeating"
            CfgSlider {
                value:  InputService.repeatDelay
                from:   100
                to:     2000
                step:   25
                suffix: "ms"
                onMoved: function(v) { InputService.set("repeatDelay", Math.round(v)) }
            }
        }

        // The layout is NOT here. It is chosen at the greeter and written into
        // every compositor config by apex-shell-firstrun, which greps the
        // seeded configs to verify it took. Offering a second, competing place
        // to set it would give two sources of truth for one value.
        CfgRow {
            label:       "Layout"
            description: "Set at login; changing it here is not supported yet"
            hoverable:   false
        }
    }

    // ── Reset ─────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Defaults"

        CfgRow {
            label:       "Restore defaults"
            description: InputService.anyChanged
                ? "Back to what the image ships, which is what these controls started as"
                : "Everything is already at its shipped value"
            CfgButton {
                label: "Reset"
                enabled: InputService.anyChanged
                onClicked: InputService.resetAll()
            }
        }
    }
}
