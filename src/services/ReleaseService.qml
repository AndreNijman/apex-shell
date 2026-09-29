pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"
import "release.js" as R

// ─── ReleaseService ─────────────────────────────────────────────────────────
// After an update, open that release's page on rimeos.com — once, per user.
//
// Andre, 2026-09-29: "every update from now on after updating opens a page in
// your default browser on the website that has the update and what this update
// has". rimeos.com master spec §7.2: the image carries
// /usr/share/rime/release.json (rime-os files/scripts/stamp-release), and on
// the first desktop session after booting a new deployment the Shell compares
// its ID with this user's last-seen one and opens
// https://rimeos.com/updates/<id>?from=<previous> in the default browser.
// What to do in each case is release.js (tests/release-test.js); this file
// reads, probes, opens and remembers.
//
//   * Started once at login (shell.qml force-instantiates it, outside the
//     per-screen Variants, so two monitors never open two tabs), a few seconds
//     after the session is up and never under the lock screen.
//   * First install or update: `rpm-ostree status --json`, as the user. A
//     deployment that is neither booted nor staged is the one this boot came
//     from, so the machine was updated; none means a fresh install.
//   * The page is opened only once it answers 200: the site publishes on its
//     own schedule and a laptop can boot offline. Until then the release is
//     pending, retried every 20 minutes and on every start; opening it (or
//     showing the notification) is what marks it seen.
//   * Opened through /usr/libexec/rime-open-browser — the user's default
//     browser, as SUPER+W — detached, so the browser outlives a shell restart.
//     No opener, or "Open what's new after an update" turned off: a
//     notification with "See what changed" instead (spec §7.2 step 5, §7.4).
//   * A rollback gets a small notice and no page (§7.2 step 6).
//
// State: ~/.local/state/rime/releases.json { lastBooted, lastOpenedNotes,
// pending }. The spec's `autoOpenNotes` lives in SettingsService instead
// (openReleaseNotes), where every other setting is written. Nothing is sent
// anywhere: the only network request is the probe of the public page.
//
// Test hooks (tests/run-release-service-test.sh): RIME_RELEASE_JSON,
// RIME_RELEASE_OPENER, RIME_RELEASE_DELAY_MS; curl, rpm-ostree and notify-send
// are found on PATH.
// ────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    readonly property string releasePath: Quickshell.env("RIME_RELEASE_JSON") || "/usr/share/rime/release.json"
    readonly property string statePath: Quickshell.env("HOME") + "/.local/state/rime/releases.json"
    readonly property string opener: Quickshell.env("RIME_RELEASE_OPENER") || "/usr/libexec/rime-open-browser"
    readonly property int startDelay: parseInt(Quickshell.env("RIME_RELEASE_DELAY_MS") || "8000", 10)

    // What is known, for the settings page and the tests.
    property var booted: null            // the image's release.json
    property var state: null             // this user's releases.json (null: none yet)
    property bool hasRollback: false
    property string lastAction: ""       // the last decision taken (for tests and logs)
    property string lastUrl: ""
    readonly property bool pending: !!(root.state && root.state.pending)

    // ── The sequence: release.json → state → deployments → decide ───────────
    property bool _busy: false
    property bool _wantCheck: false
    function check() {
        // The settings file is read asynchronously at start: deciding before it
        // has been read would take "Open what's new" as its default (on) for a
        // user who turned it off (measured: a 100 ms start opened the page).
        if (!SettingsService._loaded) { root._wantCheck = true; return }
        if (root._busy || LockState.locked) return
        root._busy = true
        root._readRelease.running = true
    }
    Connections {
        target: SettingsService
        function on_LoadedChanged() { if (SettingsService._loaded && root._wantCheck) { root._wantCheck = false; root.check() } }
    }

    Timer {
        id: startTimer
        interval: Math.max(0, root.startDelay)
        running: true
        onTriggered: root.check()
    }
    // Under the lock screen, wait for the unlock: the page is for a person
    // who is looking.
    Connections {
        target: LockState
        function onLockedChanged() { if (!LockState.locked && !startTimer.running) root.check() }
    }
    Timer {
        interval: 20 * 60 * 1000
        repeat: true
        running: root.pending
        onTriggered: root.check()
    }

    property Process _readRelease: Process {
        command: ["cat", root.releasePath]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.booted = JSON.parse(this.text) } catch (e) { root.booted = null }
                root._readState.running = true
            }
        }
    }
    property Process _readState: Process {
        command: ["cat", root.statePath]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = String(this.text).trim()
                if (t === "") root.state = null
                else { try { root.state = JSON.parse(t) } catch (e) { root.state = null } }
                root._deployments.running = true
            }
        }
    }
    property Process _deployments: Process {
        command: ["rpm-ostree", "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                let rb = false
                try {
                    const d = JSON.parse(this.text)
                    const deps = (d && d.deployments) || []
                    for (let i = 0; i < deps.length; i++)
                        if (!deps[i].booted && !deps[i].staged) rb = true
                } catch (e) { rb = false }   // not an ostree system, or no answer: not an update
                root.hasRollback = rb
                root._decide()
            }
        }
    }

    function _decide() {
        const d = R.decide(root.booted, root.state, root.hasRollback, SettingsService.openReleaseNotes)
        root.lastAction = d.action
        root.lastUrl = d.url
        if (d.action !== "none" || d.state) console.info("ReleaseService:", d.action, d.url || "", "booted",
                                                         root.booted ? root.booted.id : "(none)")
        if (d.action === "open") {
            if (d.state) root._save(d.state)      // pending until it has opened
            root._probe(d.url)
            return
        }
        if (d.action === "notify") {
            root._notifyUpdated(d.url)
            root._save(R.opened(d.state, root.booted.id))
            root._busy = false
            return
        }
        if (d.state) root._save(d.state)
        if (d.action === "rollback") {
            root._notify("Rime rolled back",
                         "This computer started Rime " + root.booted.id + ", an older release than the last one it ran.", "")
        }
        root._busy = false
    }

    // ── The page must answer before it is opened ───────────────────────────
    property string _probeUrl: ""
    function _probe(url) {
        root._probeUrl = url
        // The canonical page, without ?from= (the site computes that part in
        // the browser; the page itself is what must exist).
        const canonical = url.split("?")[0]
        // Redirects are followed (a trailing-slash rule, a move to another
        // host), but only a final 200 AT THIS RELEASE'S PAGE counts: a redirect
        // to /updates/latest or a front page would otherwise pass for it.
        // (rimeos.com, measured on its Pages build: the canonical URL is 200,
        // an unknown ID a plain 404, a trailing slash a 308 to the canonical.)
        root._probeProc.command = ["curl", "-sL", "-o", "/dev/null", "-w", "%{http_code} %{url_effective}",
                                   "--max-time", "10", canonical]
        root._probeProc.running = true
    }
    property Process _probeProc: Process {
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = String(this.text).trim().split(" ")
                const landed = (parts[1] || "").split("?")[0].replace(/\/+$/, "")
                const want = root._probeUrl.split("?")[0].replace(/\/+$/, "")
                const code = landed === want ? parts[0] : "redirected:" + landed
                if (code === "200") {
                    root._openProc.command = ["sh", "-c",
                        "h=\"$1\"; [ -x \"$h\" ] || h=xdg-open; command -v \"$h\" >/dev/null 2>&1 || exit 127; " +
                        "setsid -f \"$h\" \"$2\" >/dev/null 2>&1 </dev/null",
                        "sh", root.opener, root._probeUrl]
                    root._openProc.running = true
                } else {
                    console.info("ReleaseService: " + root._probeUrl.split("?")[0] + " answered '" + code
                                 + "', holding it pending")
                    root.lastAction = "pending"
                    root._busy = false
                }
            }
        }
    }
    property Process _openProc: Process {
        onExited: function (code) {
            if (code === 0) {
                root.lastAction = "opened"
            } else {
                // No browser to hand it to: say it instead, with the way there.
                root.lastAction = "notified"
                root._notifyUpdated(root._probeUrl)
            }
            root._save(R.opened(root.state, root.booted.id))
            root._busy = false
        }
    }

    // ── Notifications ──────────────────────────────────────────────────────
    function _notifyUpdated(url) {
        root._notify("Rime updated", "This computer is now on Rime " + root.booted.id + ".", url)
    }
    // notify-send -A waits for the choice and prints it: "open" → the page.
    property string _notifyUrl: ""
    function _notify(summary, body, url) {
        root._notifyUrl = url
        const argv = ["notify-send", "-a", "Rime", "-i", "system-software-update"]
        if (url !== "") argv.push("-A", "open=See what changed")
        argv.push(summary, body)
        root._notifyProc.command = argv
        root._notifyProc.running = true
    }
    property Process _notifyProc: Process {
        stdout: StdioCollector {
            onStreamFinished: {
                if (String(this.text).trim() === "open" && root._notifyUrl !== "")
                    Quickshell.execDetached([root.opener, root._notifyUrl])
            }
        }
    }

    // ── State ──────────────────────────────────────────────────────────────
    function _save(st) {
        root.state = st
        root._saveProc.command = ["bash", "-c",
            "mkdir -p \"$(dirname \"$2\")\" && printf '%s\\n' \"$1\" > \"$2.tmp\" && mv -f \"$2.tmp\" \"$2\"",
            "--", JSON.stringify(st), root.statePath]
        // A restart, not a second start: a write still in flight is superseded
        // by this one (it carries the whole state), never silently dropped.
        root._saveProc.running = false
        root._saveProc.running = true
    }
    property Process _saveProc: Process {}
}
