import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/services/config_tab"

// What happens to a staged settings edit when the user goes somewhere else.
// Run through tests/run-settings-staged-test.sh (P0-023 criteria 3 and 4,
// P0-024 criterion 2).
//
// ── WHY THIS IS A LIVE RUN ──────────────────────────────────────────────────
//
// "Staged state survives navigation" is a statement about object lifetime, and
// no grep can answer it. Three things decide it and none of them are visible in
// the page's source:
//
//   1. LazyPage latches `active` on first reveal and never unloads, so a tab
//      switch inside ONE host keeps the page object alive.
//   2. The settings pages are presented in TWO hosts — the dashboard's Config
//      tab and the Nexus window — and each host's Repeater builds its OWN
//      instance from PageRegistry. Two instances, two sets of member state.
//   3. shell.qml builds both hosts per entry in Quickshell.screens, so an
//      output arriving or leaving destroys and rebuilds every one of them.
//      A display apply does exactly that, which is how a settings window can
//      be torn down by another settings page.
//
// So the suite holds two KeybindsPage instances the way the two hosts do, plus
// a real ShellConfig to switch tabs in, and asks the pages themselves.
//
// ── WHY IT ALSO BREAKS THE WRITE ────────────────────────────────────────────
//
// Criterion 4 — "a backend failure shows an error and keeps the user's intent
// recoverable" — is untestable while the write always succeeds. The runner
// chmods the config directory to 0500 before one of the applies, so the shell
// gets a real non-zero exit from a real failed write, and the run asserts that
// the staged edits are STILL THERE afterwards and that something says why.
// Then it puts the permissions back and applies again, which is criterion 6:
// the page has to read the effective state back rather than assume it landed.
//
// It breaks the LIVE pages' write the same way. Six of the ten persist through
// SettingsService, none of them stages anything, and until P0-023 that service
// never read its own exit code — so the slider moved, the shell reflowed, and
// the value was gone at the next login. The same directory holds both files, so
// one chmod covers both.
//
// It opens no window. There is no PanelWindow or Window here — the pages are
// instantiated inside a plain Item, which is enough to build every object and
// evaluate every binding, and the compositor behind it is headless and private.

ShellRoot {
    id: rootScope

    property int pass: 0
    property int fail: 0
    property int step: 0

    function ok(what)  { console.log("  PASS  " + what); rootScope.pass++ }
    function bad(what) { console.log("  FAIL  " + what); rootScope.fail++ }
    function check(what, cond) { if (cond) rootScope.ok(what); else rootScope.bad(what) }

    // The action driven throughout. Terminal is bound by default to SUPER+T, so
    // SUPER+SHIFT+T is a real change and collides with nothing in the defaults.
    readonly property string action: "app-terminal"
    readonly property string newMods: "SUPER + SHIFT"
    readonly property string newKey:  "T"

    // ── The two hosts ────────────────────────────────────────────────────────
    // hostA stands for the dashboard's Config tab and hostB for the Nexus
    // window. Nothing here fakes the hosts: these are the same KeybindsPage
    // component both Repeaters build, instantiated twice, which is the whole
    // situation.
    Item {
        id: stage
        width: 900
        height: 640

        KeybindsPage { id: pageA; anchors.fill: parent }

        // hostB is behind a Loader so the run can destroy and rebuild it, which
        // is what a display apply does to every Nexus on the machine.
        Loader {
            id: hostB
            anchors.fill: parent
            active: true
            sourceComponent: Component { KeybindsPage {} }
        }

        // The real dashboard Config tab, for the tab-switch half. Its pages are
        // built by the same PageRegistry Repeater the shipped one uses.
        ShellConfig { id: cfg; anchors.fill: parent; onScreen: false }
    }

    // Find the KeybindsPage inside a host by what it is rather than by where it
    // sits: the Repeater/LazyPage nesting is an implementation detail of the
    // host and a path expression would break the next time one is added.
    function findKeybindsPage(obj) {
        if (!obj) return null
        if (obj._pending !== undefined && obj.hasPending !== undefined)
            return obj
        const kids = obj.children
        if (kids) {
            for (let i = 0; i < kids.length; i++) {
                const hit = rootScope.findKeybindsPage(kids[i])
                if (hit) return hit
            }
        }
        return null
    }

    function pendingCount(page) {
        return page && page._pending ? Object.keys(page._pending).length : -1
    }

    // ── Reading back what is actually on disk ────────────────────────────────
    // Criterion 6. Not the service's own in-memory map, which would agree with
    // itself by construction — the file, read by a separate process.
    property string savedJson: ""
    property var readBack: Process {
        command: ["bash", "-c",
                  "cat \"$HOME/.config/apex-shell/src/user_data/keybinds.json\" 2>/dev/null || echo '{}'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: rootScope.savedJson = text.trim()
        }
    }

    // The other file a settings page persists through. Six of the ten pages
    // write here and none of them could report a failure before P0-023, so a
    // home directory the shell could not write to looked exactly like one it
    // could until the next login threw the changes away.
    property string savedSettings: ""
    property var readSettings: Process {
        command: ["bash", "-c",
                  "cat \"$HOME/.config/apex-shell/src/user_data/settings.json\" 2>/dev/null || echo '{}'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: rootScope.savedSettings = text.trim()
        }
    }

    function savedSetting(key) {
        try {
            const j = JSON.parse(rootScope.savedSettings)
            return j[key] !== undefined ? j[key] : null
        } catch (e) {
            return "unparseable"
        }
    }

    // The lifecycle line the Keybinds page places itself, found by what it is.
    // A refused write with NO draft has nowhere else to appear: the commit bar
    // hides itself when the count is zero, and the per-row reset and Misc's
    // "reset all shortcuts" both write without staging anything.
    function lifecycleOf(page) {
        if (!page) return null
        if (page.lifecycle !== undefined && page.error !== undefined) return page
        const kids = page.children
        if (kids)
            for (let i = 0; i < kids.length; i++) {
                const hit = rootScope.lifecycleOf(kids[i])
                if (hit) return hit
            }
        return null
    }

    function savedCombo(act) {
        try {
            const j = JSON.parse(rootScope.savedJson)
            if (!j[act]) return ""
            return (j[act].mods || "") + "|" + (j[act].key || "")
        } catch (e) {
            return "unparseable"
        }
    }

    // The failing write is a real EACCES from a real filesystem rather than a
    // flag a service was told to honour.
    //
    // The DIRECTORY and the FILES, because they refuse different things. A
    // directory at 0500 stops a redirect that has to CREATE the file, which is
    // what the first keybinds write does; it does not stop a redirect that
    // truncates one already there, because that needs permission on the file
    // and not on the directory. Only doing the directory made two of these
    // assertions pass for the wrong reason and then fail once the file existed.
    property var chmodProc: Process { command: []; running: false }
    function setConfigWritable(on) {
        const dir = "\"$HOME/.config/apex-shell/src/user_data\""
        chmodProc.command = ["bash", "-c", on
            ? "chmod 0700 " + dir + "; chmod 0600 " + dir + "/*.json 2>/dev/null; true"
            : "chmod 0400 " + dir + "/*.json 2>/dev/null; chmod 0500 " + dir + "; true"]
        chmodProc.running = false
        chmodProc.running = true
    }

    property var savedPageA: null

    Timer {
        id: driver
        interval: 250
        repeat: true
        running: true

        property int waited: 0

        onTriggered: {
            driver.waited++
            if (driver.waited > 120) {          // 30 seconds
                rootScope.bad("the run did not settle at step " + rootScope.step)
                rootScope.finish()
                return
            }
            // Nothing can be asserted until the defaults have been merged with
            // whatever is on disk; before that every page reads as unbound.
            if (Object.keys(KeybindService.keybinds).length === 0)
                return

            switch (rootScope.step) {

            // ── 1. staging is visible where it was staged ────────────────────
            case 0:
                rootScope.check("nothing is staged when the page opens",
                                pageA.hasPending === false)
                rootScope.check("the second host starts clean too",
                                hostB.item && hostB.item.hasPending === false)
                // The Config tab opens on its first page, so the Keybinds page
                // does not exist until somebody selects it — which is the same
                // first visit a user's is.
                cfg._page = "keybinds"
                rootScope.step = 1
                driver.waited = 0
                return

            case 1:
                if (rootScope.findKeybindsPage(cfg) === null) return
                pageA._addPending(rootScope.action, rootScope.newMods, rootScope.newKey)
                rootScope.step = 2
                driver.waited = 0
                return

            case 2:
                rootScope.check("the page that took the edit is holding it",
                                pageA.hasPending === true
                                && rootScope.pendingCount(pageA) === 1)

                // ── 2. the OTHER surface, on the same machine ───────────────
                // The user staged this in the dashboard and pressed "Open in
                // window". Same setting, same session, other object.
                rootScope.check("the other settings surface is holding it too",
                                hostB.item && hostB.item.hasPending === true)

                // ── 3. tab switch inside one host ───────────────────────────
                rootScope.savedPageA = rootScope.findKeybindsPage(cfg)
                if (!rootScope.savedPageA) {
                    rootScope.bad("the Config tab built no Keybinds page to switch away from")
                    rootScope.finish()
                    return
                }
                rootScope.check("the tab's own Keybinds page sees the staged edit",
                                rootScope.savedPageA.hasPending === true)
                cfg._page = "misc"
                rootScope.step = 3
                driver.waited = 0
                return

            case 3:
                cfg._page = "keybinds"
                rootScope.step = 4
                driver.waited = 0
                return

            case 4: {
                const back = rootScope.findKeybindsPage(cfg)
                rootScope.check("the Keybinds page survives a tab switch away and back",
                                back !== null && back === rootScope.savedPageA)
                rootScope.check("and it still holds the staged edit",
                                back !== null && back.hasPending === true)

                // ── 4. the host is destroyed and rebuilt ────────────────────
                // A display apply removes and re-adds every output, so both
                // hosts are rebuilt from scratch. The user did not navigate;
                // the machine did.
                hostB.active = false
                rootScope.step = 5
                driver.waited = 0
                return
            }

            case 5:
                hostB.active = true
                rootScope.step = 6
                driver.waited = 0
                return

            case 6:
                rootScope.check("a rebuilt settings window still holds the staged edit",
                                hostB.item && hostB.item.hasPending === true)

                // ── 5. the write fails ─────────────────────────────────────
                rootScope.setConfigWritable(false)
                rootScope.step = 7
                driver.waited = 0
                return

            case 7:
                if (driver.waited < 3) return    // let the chmod land
                KeybindService.lastError = ""
                pageA._applyPending()
                rootScope.step = 8
                driver.waited = 0
                return

            case 8:
                if (driver.waited < 8) return    // let the write fail and report
                // A STRING, not merely "not empty". Before the service had a
                // lastError at all this read `undefined !== ""`, which is true,
                // and the assertion passed against a property that did not
                // exist.
                rootScope.check("a refused write says so, in words",
                                typeof KeybindService.lastError === "string"
                                && KeybindService.lastError.length > 0)
                rootScope.check("a refused write keeps the staged edit",
                                pageA.hasPending === true
                                && rootScope.pendingCount(pageA) === 1)
                rootScope.setConfigWritable(true)
                rootScope.step = 9
                driver.waited = 0
                return

            // ── 6. and then it works ───────────────────────────────────────
            case 9:
                if (driver.waited < 3) return
                pageA._applyPending()
                rootScope.step = 10
                driver.waited = 0
                return

            case 10:
                if (driver.waited < 8) return
                rootScope.check("a write that succeeded clears the error",
                                typeof KeybindService.lastError === "string"
                                && KeybindService.lastError === "")
                rootScope.check("applying clears the staged edits",
                                pageA.hasPending === false)
                rootScope.check("the other surface cleared with it",
                                hostB.item && hostB.item.hasPending === false)
                rootScope.readBack.running = false
                rootScope.readBack.running = true
                rootScope.step = 11
                driver.waited = 0
                return

            case 11:
                if (rootScope.savedJson === "") return
                rootScope.check("the applied combo is what is on disk, read by another process",
                                rootScope.savedCombo(rootScope.action)
                                    === rootScope.newMods + "|" + rootScope.newKey)
                rootScope.check("the in-memory map agrees with the file",
                                KeybindService.keybinds[rootScope.action]
                                && KeybindService.keybinds[rootScope.action].mods === rootScope.newMods
                                && KeybindService.keybinds[rootScope.action].key === rootScope.newKey)
                // ── 7. the live pages' write ───────────────────────────────
                // Six pages persist through SettingsService and none of them
                // stages anything, so this is the other half of criterion 4.
                // 23 is not the shipped default, so a file that reads 23 was
                // written by this and not by the loader.
                SettingsService.set("cornerRadius", 23)
                rootScope.step = 12
                driver.waited = 0
                return

            case 12:
                if (driver.waited < 8) return    // past the 350ms debounce
                rootScope.savedSettings = ""
                rootScope.readSettings.running = false
                rootScope.readSettings.running = true
                rootScope.step = 13
                driver.waited = 0
                return

            case 13:
                if (rootScope.savedSettings === "") return
                rootScope.check("a live page's write reaches the file",
                                rootScope.savedSetting("cornerRadius") === 23,
                                String(rootScope.savedSetting("cornerRadius")))
                rootScope.check("and reports no error when it worked",
                                typeof SettingsService.lastError === "string"
                                && SettingsService.lastError === "")
                rootScope.setConfigWritable(false)
                rootScope.step = 14
                driver.waited = 0
                return

            case 14:
                if (driver.waited < 3) return
                SettingsService.set("cornerRadius", 29)
                rootScope.step = 15
                driver.waited = 0
                return

            case 15:
                if (driver.waited < 10) return
                rootScope.check("a live page's refused write says so, in words",
                                typeof SettingsService.lastError === "string"
                                && SettingsService.lastError.length > 0,
                                String(SettingsService.lastError))

                // ── 8. a refused write with nothing staged ─────────────────
                // The per-row reset writes without staging, so the commit bar
                // is not there to carry the failure. It has to land on the
                // page's lifecycle line instead.
                KeybindService.lastError = ""
                KeybindService.resetBinding(rootScope.action)
                rootScope.step = 16
                driver.waited = 0
                return

            case 16: {
                if (driver.waited < 10) return
                rootScope.check("a refused reset says so even with nothing staged",
                                typeof KeybindService.lastError === "string"
                                && KeybindService.lastError.length > 0)
                const line = rootScope.lifecycleOf(pageA)
                rootScope.check("the Keybinds page has a lifecycle line to say it on",
                                line !== null)
                rootScope.check("and the refusal is on it",
                                line !== null && line.error === KeybindService.lastError
                                && line.error !== "")
                rootScope.setConfigWritable(true)
                rootScope.finish()
                return
            }
            }
        }
    }

    function finish() {
        driver.running = false
        console.log("settings-staged: passed=" + rootScope.pass
                    + " failed=" + rootScope.fail)
        Qt.exit(rootScope.fail === 0 ? 0 : 1)
    }
}
