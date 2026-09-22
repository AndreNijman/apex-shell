import QtQuick
import "../../../"
import "../../../theme"
import "../"
import "../../../components/config"

// Config → Input  (roadmap §18, settings parity; UI-003)
//
// Every control writes one key of ~/.config/apex-shell/input.json, and
// InputService then runs /usr/libexec/apex-input-apply, which regenerates the
// Hyprland Lua module, the niri KDL and labwc's <libinput> block from that
// single model. Nothing on this page knows which compositor is running.
//
// ── Why every control asks before it offers itself ───────────────────────────
//
// "Changing Input configuration in APEX Shell has no effect" was true of nine
// of these, and each was true for a different reason: an option the generator
// never emitted, a value the compositor has no spelling for, a setting that
// exists on Hyprland only as a named device. None of it was visible from here,
// because a switch that writes a file and runs a generator looks identical
// whether or not anything downstream reads what it wrote.
//
// So a control is one of three things and never anything else:
//
//   * live      — the compositor can do it, and the row shows what the
//                 compositor says is in effect beside it;
//   * disabled  — with the reason, from the generator's capability table.
//                 Not hidden: "niri has no three-finger drag" is an answer, and
//                 a control that vanishes is a bug report waiting to happen;
//   * absent    — for a value rather than a control. Neither Hyprland nor niri
//                 has a click method that produces no button at all, so the Off
//                 pill is not offered there rather than offered and ignored.
//
// The generator decides which. This file asks.
CfgScroll {
    id: root

    // The read-back is not free — on Hyprland it is seventeen `hyprctl
    // getoption` calls — and InputService is constructed at every shell start
    // whether or not anyone opens this page. So it is asked for here, when the
    // page that shows it appears, rather than on login.
    Component.onCompleted: InputService.refreshEffective()

    readonly property bool _hasNotes:
        InputService.applying || InputService.lastNotes !== ""

    // A row that is a setting: label, description, and the effective value from
    // the compositor on the right when there is one to show.
    component SettingRow: CfgRow {
        property string setting: ""
        disabledReason: InputService.reasonFor(setting)
        status:         InputService.effectiveText(setting)
        // The mark the Session section promises. A page that says "each is
        // marked below" and marks nothing is a worse answer than saying
        // nothing at all.
        statusWarns:    InputService.divergedFrom(setting)
    }

    // ── What the compositor said ──────────────────────────────────────────────
    // First, not last: a correction the user has to scroll to find is a
    // correction they will not see.
    CfgSection {
        title: "Applied"
        first: true
        visible: root._hasNotes

        CfgRow {
            label: InputService.applying ? "Applying…" : "The generator adjusted something"
            description: InputService.applying
                ? "Writing the model and regenerating every compositor config"
                : InputService.lastNotes
            hoverable: false
        }
    }

    // ── Where these settings are going ────────────────────────────────────────
    // Named, because which compositor is running decides which of the controls
    // below work, and a page that quietly disables half of itself owes the
    // reader the reason for the pattern as well as for each row.
    CfgSection {
        title: "Session"
        first: !root._hasNotes

        CfgRow {
            label: "Compositor"
            description: {
                if (InputService.capabilitiesFailed)
                    return "This system's input engine is older than this page and cannot say what "
                         + "each compositor supports, so nothing below is switched off — the "
                         + "controls behave as they did before"
                if (InputService.compositor === "")
                    return "APEX could not tell which compositor is running, so nothing below is known to work"
                return "What these settings are applied to, and what decides which of them can be"
            }
            hoverable: false
            status: InputService.capabilitiesFailed ? "not reported"
                  : (InputService.compositor === "" ? "unknown" : InputService.compositor)
        }

        CfgRow {
            label: "Reported values"
            description: {
                if (!InputService.readBackReady)
                    return "Reading what is in effect…"
                if (InputService.diverged.length === 0)
                    return "Every control below reads back the value it was set to"
                return InputService.diverged.length + " setting"
                     + (InputService.diverged.length === 1 ? " is" : "s are")
                     + " not what this page asked for; those readouts are highlighted below"
            }
            hoverable: false
            CfgButton {
                label: "Re-read"
                onClicked: InputService.refreshEffective()
            }
        }
    }

    // ── Touchpad ──────────────────────────────────────────────────────────────
    CfgSection {
        title: "Touchpad"

        SettingRow {
            setting:     "tap"
            label:       "Tap to click"
            description: "One finger taps left, and see the button map below"
            CfgSwitch {
                checked: InputService.tap
                onToggled: function(v) { InputService.set("tap", v) }
            }
        }

        SettingRow {
            setting:     "tapAndDrag"
            label:       "Tap and drag"
            description: "Tap then slide to drag without holding the pad down"
            visible:     InputService.tap
            CfgSwitch {
                checked: InputService.tapAndDrag
                onToggled: function(v) { InputService.set("tapAndDrag", v) }
            }
        }

        SettingRow {
            setting:     "dragLock"
            label:       "Drag lock"
            description: "A drag survives lifting your finger briefly"
            visible:     InputService.tap && InputService.tapAndDrag
            CfgSwitch {
                checked: InputService.dragLock
                onToggled: function(v) { InputService.set("dragLock", v) }
            }
        }

        SettingRow {
            setting:     "tapButtonMap"
            label:       "Tap button map"
            description: "Two- and three-finger taps"
            visible:     InputService.tap
            CfgSegmented {
                options: InputService.optionsFor("tapButtonMap", [
                    { value: "lrm", label: "L / R / M" },
                    { value: "lmr", label: "L / M / R" }
                ])
                value: InputService.tapButtonMap
                onSelected: function(v) { InputService.set("tapButtonMap", v) }
            }
        }

        SettingRow {
            setting:     "naturalScroll"
            label:       "Natural scrolling"
            description: "Content follows your fingers"
            CfgSwitch {
                checked: InputService.naturalScroll
                onToggled: function(v) { InputService.set("naturalScroll", v) }
            }
        }

        SettingRow {
            setting:     "scrollMethod"
            label:       "Scroll method"
            description: "How a scroll gesture is recognised"
            CfgSegmented {
                options: InputService.optionsFor("scrollMethod", [
                    { value: "twofinger", label: "Two finger" },
                    { value: "edge",      label: "Edge"       },
                    { value: "none",      label: "Off"        }
                ])
                value: InputService.scrollMethod
                onSelected: function(v) { InputService.set("scrollMethod", v) }
            }
        }

        SettingRow {
            setting:     "scrollFactor"
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

        SettingRow {
            setting:     "clickMethod"
            label:       "Click method"
            description: InputService.clickMethod === "clickfinger"
                ? "Press anywhere; finger count picks the button"
                : "The bottom of the pad is split into button zones"
            CfgSegmented {
                // "Off" is dropped where the compositor has no spelling for it,
                // which is both of them but labwc. Offering it there would be a
                // pill that selects and changes nothing.
                options: InputService.optionsFor("clickMethod", [
                    { value: "clickfinger",  label: "Finger count" },
                    { value: "buttonAreas",  label: "Button areas" },
                    { value: "none",         label: "Off"          }
                ])
                value: InputService.clickMethod
                onSelected: function(v) { InputService.set("clickMethod", v) }
            }
        }

        SettingRow {
            setting:     "padSpeed"
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

        SettingRow {
            setting:     "padAccelProfile"
            label:       "Acceleration"
            description: InputService.padAccelProfile === "flat"
                ? "One-to-one; no acceleration curve"
                : "Speed-dependent, the libinput default"
            CfgSegmented {
                options: InputService.optionsFor("padAccelProfile", [
                    { value: "adaptive", label: "Adaptive" },
                    { value: "flat",     label: "Flat"     }
                ])
                value: InputService.padAccelProfile
                onSelected: function(v) { InputService.set("padAccelProfile", v) }
            }
        }

        SettingRow {
            setting:     "disableWhileTyping"
            label:       "Disable while typing"
            description: "Ignore the pad for a moment after a keypress"
            CfgSwitch {
                checked: InputService.disableWhileTyping
                onToggled: function(v) { InputService.set("disableWhileTyping", v) }
            }
        }

        SettingRow {
            setting:     "threeFingerDrag"
            label:       "Three-finger drag"
            description: "Drag windows with three fingers"
            CfgSwitch {
                checked: InputService.threeFingerDrag
                onToggled: function(v) { InputService.set("threeFingerDrag", v) }
            }
        }

        SettingRow {
            setting:     "middleEmulation"
            label:       "Middle-click emulation"
            description: "Left and right together act as middle"
            CfgSwitch {
                checked: InputService.middleEmulation
                onToggled: function(v) { InputService.set("middleEmulation", v) }
            }
        }

        SettingRow {
            setting:     "leftHandedPad"
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
        SettingRow {
            setting:     "pointerNaturalScroll"
            label:       "Natural scrolling"
            description: "Separate from the touchpad's setting, on purpose"
            CfgSwitch {
                checked: InputService.pointerNaturalScroll
                onToggled: function(v) { InputService.set("pointerNaturalScroll", v) }
            }
        }

        SettingRow {
            setting: "pointerScrollFactor"
            label:   "Scroll speed"
            CfgSlider {
                value:  InputService.pointerScrollFactor
                from:   0.1
                to:     10.0
                step:   0.1
                suffix: "×"
                onMoved: function(v) { InputService.set("pointerScrollFactor", v) }
            }
        }

        SettingRow {
            setting: "pointerSpeed"
            label:   "Pointer speed"
            CfgSlider {
                value:  InputService.pointerSpeed
                from:   -1.0
                to:     1.0
                step:   0.05
                onMoved: function(v) { InputService.set("pointerSpeed", v) }
            }
        }

        SettingRow {
            setting:     "pointerAccelProfile"
            label:       "Acceleration"
            description: InputService.pointerAccelProfile === "flat"
                ? "One-to-one; what most games expect"
                : "Speed-dependent, the libinput default"
            CfgSegmented {
                options: InputService.optionsFor("pointerAccelProfile", [
                    { value: "adaptive", label: "Adaptive" },
                    { value: "flat",     label: "Flat"     }
                ])
                value: InputService.pointerAccelProfile
                onSelected: function(v) { InputService.set("pointerAccelProfile", v) }
            }
        }

        SettingRow {
            setting: "pointerMiddleEmulation"
            label:   "Middle-click emulation"
            CfgSwitch {
                checked: InputService.pointerMiddleEmulation
                onToggled: function(v) { InputService.set("pointerMiddleEmulation", v) }
            }
        }

        SettingRow {
            setting:     "leftHanded"
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

        SettingRow {
            setting:     "repeatRate"
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

        SettingRow {
            setting:     "repeatDelay"
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

    // ── This machine's devices ────────────────────────────────────────────────
    // The sections above are the defaults for a KIND of device. This one is for
    // a particular one, by name — which is the only way to say "the external
    // trackball, not the built-in touchpad", and the only way Hyprland can
    // express touchpad pointer speed at all.
    CfgSection {
        title: "Devices"

        CfgRow {
            label: "Detected"
            description: InputService.devices.length === 0
                ? "APEX has not been able to enumerate this machine's input devices"
                : "Read from the kernel and udev, which need no extra permission — unlike libinput's own device list"
            hoverable: false
            status: InputService.configurableDevices.length + " configurable"
        }

        CfgRow {
            visible:        InputService.perDeviceReason !== ""
            label:          "Per-device settings"
            disabledReason: InputService.perDeviceReason
            hoverable:      false
        }

        Repeater {
            model: InputService.perDeviceReason === ""
                 ? InputService.configurableDevices : []

            delegate: Column {
                id: dev
                required property var modelData
                readonly property var keys: InputService.deviceKeys[modelData.type] || []
                readonly property bool overridden:
                    InputService.deviceOverrides[modelData.name] !== undefined

                width:   parent ? parent.width : 0
                spacing: 2

                CfgRow {
                    label:       dev.modelData.name
                    description: {
                        const kind = dev.modelData.type
                        const shown = kind.charAt(0).toUpperCase() + kind.slice(1)
                        return dev.overridden
                            ? shown + " · set apart from the " + kind + " defaults above"
                            : shown + " · following the defaults above"
                    }
                    hoverable: false
                    CfgButton {
                        label:   dev.overridden ? "Clear" : "Follows defaults"
                        enabled: dev.overridden
                        onClicked: InputService.clearDevice(dev.modelData.name)
                    }
                }

                // Only the settings this KIND of device has. A touchscreen gets
                // one row and a touchpad gets nine, from the generator's own
                // table rather than from a guess made here.
                CfgRow {
                    label:       "Pointer speed"
                    description: "For this device only"
                    visible:     dev.keys.indexOf("speed") >= 0
                    CfgSlider {
                        value: InputService.deviceValue(dev.modelData.name, "speed") !== undefined
                             ? InputService.deviceValue(dev.modelData.name, "speed")
                             : (dev.modelData.type === "touchpad" ? InputService.padSpeed
                                                                  : InputService.pointerSpeed)
                        from: -1.0
                        to:    1.0
                        step:  0.05
                        onMoved: function(v) {
                            InputService.setDevice(dev.modelData.name, dev.modelData.type, "speed", v)
                        }
                    }
                }

                CfgRow {
                    label:       "Natural scrolling"
                    description: "For this device only"
                    visible:     dev.keys.indexOf("natural_scroll") >= 0
                    CfgSwitch {
                        checked: InputService.deviceValue(dev.modelData.name, "natural_scroll") !== undefined
                               ? InputService.deviceValue(dev.modelData.name, "natural_scroll")
                               : (dev.modelData.type === "touchpad" ? InputService.naturalScroll
                                                                    : InputService.pointerNaturalScroll)
                        onToggled: function(v) {
                            InputService.setDevice(dev.modelData.name, dev.modelData.type,
                                                   "natural_scroll", v)
                        }
                    }
                }

                CfgRow {
                    label:       "Left-handed"
                    description: "For this device only"
                    visible:     dev.keys.indexOf("left_handed") >= 0
                    CfgSwitch {
                        checked: InputService.deviceValue(dev.modelData.name, "left_handed") !== undefined
                               ? InputService.deviceValue(dev.modelData.name, "left_handed")
                               : (dev.modelData.type === "touchpad" ? InputService.leftHandedPad
                                                                    : InputService.leftHanded)
                        onToggled: function(v) {
                            InputService.setDevice(dev.modelData.name, dev.modelData.type,
                                                   "left_handed", v)
                        }
                    }
                }

                CfgRow {
                    label:       "Enabled"
                    description: "Turn this device off without unplugging it"
                    visible:     dev.keys.indexOf("enabled") >= 0
                    CfgSwitch {
                        checked: InputService.deviceValue(dev.modelData.name, "enabled") !== undefined
                               ? InputService.deviceValue(dev.modelData.name, "enabled") : true
                        onToggled: function(v) {
                            InputService.setDevice(dev.modelData.name, dev.modelData.type, "enabled", v)
                        }
                    }
                }
            }
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
