import QtQuick
import "../../../"
import "../../"
import "../../../components"
import "../../../components/config"

// Config → Paired devices  (roadmap P1-051, criteria 3 and 5)
//
//   3. "Lost devices can be revoked from APEX Settings."
//   5. "Paired-device list shows name, last seen, permissions, and revocation
//       state."
//
// ── A revoked device stays on the list ──────────────────────────────────────
//
// The daemon keeps the record after revocation so the listing can still show
// that it WAS revoked and when, and this page shows it. A row that vanished
// would leave the person unable to tell "I revoked that phone" from "that
// phone was never here" — and the second reading is the one that sends
// somebody hunting for a device they already dealt with.
//
// ── The biometric flag is a claim, and is not a column ──────────────────────
//
// Criterion 5 says "permissions", and the field behind it is
// `requires_user_verification`. It records that the DEVICE said its key is
// held behind a biometric or device lock. This desktop cannot see a
// fingerprint and cannot check it, which apex-remote-core says at length:
// "recorded as a requirement the owner set and not as a fact about the
// device".
//
// So it is one sentence under the list, exactly as `apex remote devices`
// prints it, and deliberately NOT a tick in each row — "a tick in a table
// would read as a fact this machine had verified". remotepairing.js exposes it
// only as that sentence, and tests/remote-pairing-test.js asserts the absence
// of anything a row could render per device.
//
// ── State colours are not decided here ──────────────────────────────────────
//
// The token and the weight come from remotepairing.js, looked up on Theme by
// name. That is the rule tests/check-color-tokens.sh states after "APEX agents
// display only in white": a row does not decide what a state looks like, and a
// three-branch ternary made of theme tokens is still the bug.
CfgScroll {
    id: root

    lifecycle: "live"

    property bool onScreen: false

    ServiceRef {
        service: RemotePairingService
        active: root.onScreen
    }

    // ── The devices ──────────────────────────────────────────────────────────
    CfgSection {
        title: "Paired devices"
        first: true

        CfgRow {
            label: "Nothing paired yet"
            description: "Open 'Pair a device' and scan the code with APEX Remote."
            // Only once a read has actually come back. "No devices" and "not
            // asked yet" look identical and mean opposite things.
            visible: RemotePairingService.devicesChecked
                     && RemotePairingService.summary === "No devices paired."
        }

        CfgRow {
            label: "Could not read the device list"
            description: RemotePairingService.devicesError
            visible: RemotePairingService.devicesError !== ""
        }

        Repeater {
            model: RemotePairingService.devices

            Rectangle {
                id: deviceRow

                // What the headless suite finds rows by. A marker property
                // rather than a position in the tree, so the assertion still
                // points at the right object after somebody reflows the page.
                property string deviceId: modelData.id
                readonly property string deviceState: RemotePairingService.deviceState(modelData)
                // The token is a NAME on Theme, looked up rather than switched
                // on, so remotepairing.js stays the only file deciding it.
                readonly property color tone: Theme[RemotePairingService.stateToken(deviceRow.deviceState)]
                readonly property string weight: RemotePairingService.stateWeight(deviceRow.deviceState)

                x: Theme.px(10)
                width: parent.width - Theme.px(20)
                height: Theme.px(62)
                radius: Theme.px(8)
                color: deviceRow.weight === "tint"
                    ? Qt.rgba(deviceRow.tone.r, deviceRow.tone.g, deviceRow.tone.b, 0.08)
                    : "transparent"
                border.color: deviceRow.weight === "outline" || deviceRow.weight === "solid"
                    ? deviceRow.tone : Theme.border
                border.width: Math.max(1, Theme.px(1))

                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.px(12)
                    anchors.right: revokeBtn.left
                    anchors.rightMargin: Theme.px(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.px(3)

                    Text {
                        text: modelData.name
                        font.pixelSize: Theme.fs(13)
                        font.weight: Font.Medium
                        color: Theme.text
                        elide: Text.ElideRight
                        width: parent.width
                    }

                    Row {
                        spacing: Theme.px(8)

                        // The state word, in the state's own tone. The word is
                        // the redundant channel that survives when the hue
                        // does not carry -- see remotepairing.js on why every
                        // state also has a weight.
                        Text {
                            text: RemotePairingService.stateLabel(deviceRow.deviceState)
                            font.pixelSize: Theme.fs(10)
                            color: deviceRow.tone
                        }
                        Text {
                            text: "·  last seen " + RemotePairingService.lastSeen(modelData)
                                + (modelData.lastPath ? "  over " + modelData.lastPath : "")
                            font.pixelSize: Theme.fs(10)
                            color: Theme.subtext
                            elide: Text.ElideRight
                        }
                    }
                }

                CfgButton {
                    id: revokeBtn
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.px(8)
                    anchors.verticalCenter: parent.verticalCenter
                    label: RemotePairingService.revoking === modelData.id ? "Revoking…" : "Revoke"
                    icon: "󰅙"
                    // A revoked device has nothing left to take away. The
                    // button goes rather than greying, so the row reads as
                    // finished business instead of a disabled action somebody
                    // tries to work out how to enable.
                    visible: RemotePairingService.deviceState(modelData) !== "revoked"
                    enabled: RemotePairingService.revoking === ""
                    onClicked: RemotePairingService.revoke(modelData.id)
                }
            }
        }

        CfgRow {
            label: "Could not revoke"
            description: RemotePairingService.revokeError
            visible: RemotePairingService.revokeError !== ""
        }
    }

    // ── The device's own claim ───────────────────────────────────────────────
    CfgSection {
        title: "Device locks"
        visible: RemotePairingService.verificationNote !== ""

        CfgRow {
            label: "What the device says"
            // One sentence, naming the devices, phrased as a claim. Not a
            // column and not a tick: this machine cannot verify it, and a
            // tick would read as though it had.
            description: RemotePairingService.verificationNote
        }
    }

    // ── What revoking does ───────────────────────────────────────────────────
    CfgSection {
        title: "About revoking"

        CfgRow {
            label: "It takes effect immediately"
            description: "A connection the device is already holding is dropped, not merely refused next time. The record is kept, so the device stays on this list marked revoked rather than disappearing."
        }

        CfgRow {
            label: "Pairing again is a new decision"
            description: "A revoked device cannot come back on its own. It has to scan a fresh pairing code, which means somebody has to be at this machine to show one."
        }
    }
}
