pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "remotepairing.js" as RP

// ─────────────────────────────────────────────────────────────────────────────
//  APEX Remote pairing and paired devices, for the two settings pages
//  (roadmap P1-051, criteria 1, 3 and 5).
//
//  ── Everything through the apex CLI ─────────────────────────────────────────
//
//  Same rule as RemoteAgentService and AgentService: the `apex` CLI is the
//  stability surface. It already handles an absent daemon and a version
//  mismatch, and it owns the control-socket path and its framing.
//
//  There is a second reason here that does not apply to the others, and it is
//  the load-bearing one. `apex remote pair` MINTS A ONE-TIME TOKEN and arms
//  the daemon to accept the next device that presents it. Under test, the
//  `apex` on PATH is the stub tests/lib/headless.sh installs, so a suite can
//  drive this page without arming anything. A service that opened
//  apex-remoted/control.sock directly would walk straight past that stub and
//  mint a real pairing token on whoever's machine the suite ran on.
//
//  ── Pairing is not a read, so it is not on the sweep ────────────────────────
//
//  The sweep refreshes the device list and the status, both of which are
//  questions. It never runs `pair`. A code is minted exactly three times: when
//  the pairing page first comes on screen with no live offer, when the one on
//  screen expires, and when the person asks for a new one. Putting `pair` on a
//  30-second timer would burn a fresh one-time token every 30 seconds for as
//  long as the page was open, and each new one invalidates the code the person
//  is currently holding their phone up to.
//
//  tests/run-remote-pairing-page-test.sh asserts this against the stub's own
//  call log: zero `pair` calls before the page is shown, exactly one after.
//
//  ── Process lifetime ────────────────────────────────────────────────────────
//
//  Nothing runs while nobody is looking; `refCount` is the name
//  components/ServiceRef.qml expects. Four commands, four Process objects,
//  rather than one process and a queue: the queue needs a tagged settle timer
//  so a fire armed by step N does not resolve step N+1, and four independent
//  readers do not need one at all.
//
//  The Quickshell 0.3.0 facts this depends on are the ones RecoveryService.qml
//  documents: `streamFinished` precedes `exited`, and a binary that cannot
//  exec emits NEITHER and only drops `running` to false. The last is not
//  hypothetical — an image whose `apex` predates `remote` reaches these pages
//  through exactly that path, which is why every command has an
//  `onRunningChanged` fallback and the pages can tell "asked and got nothing"
//  from "not asked yet".
// ─────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    // ── Demand ───────────────────────────────────────────────────────────────
    //     ServiceRef { service: RemotePairingService; active: root.onScreen }
    property int refCount: 0

    // Long, because nothing here changes without a person picking up a phone.
    // The sweep exists so the list catches up after they do.
    readonly property int sweepInterval: 15000
    readonly property int queryTimeout: 10000

    // ── What the machine says ────────────────────────────────────────────────

    // The devices, normalised by remotepairing.js.
    property var devices: []
    // True once a device read has come back, whatever it said. Lets the page
    // tell "no devices paired" from "not asked yet" — which look identical and
    // mean opposite things.
    property bool devicesChecked: false
    property string devicesError: ""

    property var status: ({ ok: false, connections: [], connectedIds: [], relay: "", lan: [] })

    // ── The pairing offer ────────────────────────────────────────────────────

    // The `apex-remote:` payload currently on screen, or "".
    property string payload: ""
    property real payloadExpiresMs: 0
    // Why there is no code, in the words the command used. Shown instead of a
    // QR, never beside one: "a wrong QR is worse than none" is the whole
    // premise, and so is a stale one.
    property string pairError: ""
    property bool pairing: false

    // Ticks while an offer is live, so the countdown moves.
    property real nowMs: Date.now()

    readonly property int secondsLeft: RP.secondsLeft(root.payloadExpiresMs, root.nowMs)
    readonly property string countdown: RP.countdown(root.secondsLeft)
    // A payload whose three minutes are up is not shown. It would scan, and
    // the daemon would refuse it, and the person would have no idea why.
    readonly property bool offerLive: root.payload !== "" && root.secondsLeft > 0

    readonly property var connectedIds: root.status.connectedIds || []
    readonly property string summary: RP.summary(root.devices, root.devicesChecked)
    readonly property string verificationNote: RP.verificationNote(root.devices)

    function deviceState(d) { return RP.deviceState(d, root.connectedIds) }
    function stateToken(s) { return RP.token(s) }
    function stateWeight(s) { return RP.weight(s) }
    function stateLabel(s) { return RP.label(s) }
    function lastSeen(d) { return RP.ago(d.lastSeenMs, root.nowMs) }

    readonly property bool active: root.refCount > 0

    // ── Reads ────────────────────────────────────────────────────────────────

    function refresh() {
        if (!root.active) return
        if (!root._devicesProc.running) {
            root._devicesBuf = ""
            root._devicesProc.command = RP.DEVICES_COMMAND
            root._devicesProc.running = true
        }
        if (!root._statusProc.running) {
            root._statusBuf = ""
            root._statusProc.command = RP.STATUS_COMMAND
            root._statusProc.running = true
        }
    }

    property string _devicesBuf: ""
    property Process _devicesProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._devicesBuf = this.text }
        onExited: function (code) {
            root.devicesChecked = true
            if (code === 0) {
                root.devices = RP.parseDevices(root._devicesBuf)
                root.devicesError = ""
            } else {
                root.devicesError = "apex remote devices exited " + code
            }
        }
        // The binary is not there at all. Neither `exited` nor
        // `streamFinished` fires; only this.
        onRunningChanged: if (!running && !root.devicesChecked) {
            root.devicesChecked = true
            root.devicesError = "apex remote is not available on this image"
        }
    }

    property string _statusBuf: ""
    property Process _statusProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._statusBuf = this.text }
        onExited: function (code) {
            root.status = code === 0
                ? RP.parseStatus(root._statusBuf)
                : ({ ok: false, connections: [], connectedIds: [], relay: "", lan: [] })
        }
    }

    // ── Minting a code ───────────────────────────────────────────────────────
    //
    // Called by the pairing page, never by a timer. See the header.
    function requestCode() {
        if (!root.active || root._pairProc.running) return
        root.pairing = true
        root.pairError = ""
        root._pairBuf = ""
        root._pairProc.command = RP.PAIR_COMMAND
        root._pairProc.running = true
    }

    // Mint one only if there is not already a usable one on screen. This is
    // what the page calls on becoming visible, so coming back to the page does
    // not invalidate the code somebody is mid-scan of.
    function ensureCode() {
        if (!root.offerLive) root.requestCode()
    }

    property string _pairBuf: ""
    property Process _pairProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._pairBuf = this.text }
        onExited: function (code) {
            root.pairing = false
            if (code !== 0) {
                root.payload = ""
                root.payloadExpiresMs = 0
                root.pairError = "apex remote pair exited " + code +
                    ". APEX Remote may not be enabled: `apex remote enable`."
                return
            }
            var text = RP.payloadOf(root._pairBuf)
            var offer = RP.decodeOffer(text)
            // Both have to hold. A payload that is not a decodable offer is a
            // truncated or prose-wrapped read, and drawing a QR from one is
            // the failure this whole feature exists to avoid.
            if (!text || !offer) {
                root.payload = ""
                root.payloadExpiresMs = 0
                root.pairError = "apex remote pair did not return a pairing code."
                return
            }
            root.payload = text
            root.payloadExpiresMs = offer.expires_ms
            root.pairError = ""
            root.nowMs = Date.now()
        }
        onRunningChanged: if (!running && root.pairing) {
            root.pairing = false
            root.pairError = "apex remote is not available on this image"
        }
    }

    // ── Revoking ─────────────────────────────────────────────────────────────
    //
    // The one command here that changes anything. Immediate on the daemon's
    // side: a connection the device is holding is dropped, not merely refused
    // next time. The record is kept, so the row stays and says "revoked"
    // rather than vanishing — which is the difference between "I revoked this"
    // and "where did that go".
    property string revoking: ""
    property string revokeError: ""

    function revoke(id) {
        if (!root.active || root._revokeProc.running || !id) return
        root.revoking = String(id)
        root.revokeError = ""
        root._revokeProc.command = RP.revokeCommand(id)
        root._revokeProc.running = true
    }

    property Process _revokeProc: Process {
        command: []
        running: false
        stdout: StdioCollector {}
        onExited: function (code) {
            if (code !== 0) root.revokeError = "apex remote revoke exited " + code
            root.revoking = ""
            // Re-read rather than edit the row in place: the daemon decides
            // what revoked means, and a list that agreed with itself instead
            // of with the daemon is the one that shows a revoked device as
            // still paired.
            root.refresh()
        }
        onRunningChanged: if (!running && root.revoking !== "") {
            root.revokeError = "apex remote is not available on this image"
            root.revoking = ""
        }
    }

    // ── Timers ───────────────────────────────────────────────────────────────

    // Reads only. Never `pair`.
    property Timer _sweep: Timer {
        interval: root.sweepInterval
        repeat: true
        running: root.active
        onTriggered: root.refresh()
    }

    // Moves the countdown, and is what notices an offer has expired. One
    // second, and only while there is something counting down.
    property Timer _tick: Timer {
        interval: 1000
        repeat: true
        running: root.active && root.payload !== ""
        onTriggered: root.nowMs = Date.now()
    }

    onActiveChanged: {
        if (root.active) {
            root.nowMs = Date.now()
            root.refresh()
        } else {
            // Demand dropped to zero: kill what is in flight rather than
            // letting it finish into a page nobody is looking at.
            root._devicesProc.running = false
            root._statusProc.running = false
            root._pairProc.running = false
        }
    }
}
