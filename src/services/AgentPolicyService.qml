pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "agentpolicy.js" as Policy

// ─── AgentPolicyService ───────────────────────────────────────────────────────
// The APEX sandbox default for new agent sessions (ROADMAP.md §42.1, P0-016):
// what it is, what changing it would mean, and the password that gates one
// direction of the change.
//
// Separate from AgentService, which polls the runtime for what is RUNNING. This
// one owns a single file and a single decision, and the two have different
// costs: AgentService forks `apex agent list` every two seconds while somebody
// is looking, and this reads one small JSON file when it changes and never
// otherwise. Folding a settings read into a poller would have made it a poll.
//
// ── WHY THE RUNTIME'S OWN CONFIGURATION FILE ────────────────────────────────
//
// `~/.config/apex/agent.json` is what `apex agent run` reads for a default, and
// it is the only thing that can answer criterion 2. A setting stored in the
// shell's own configuration would be read by nothing: `a` launches from a
// terminal that never asks the shell anything, and a session started that way
// has to come up unconfined for the toggle to have meant anything.
//
// It also answers criterion 6 for free. The file is on disk, under $HOME, and
// the runtime reads it at every `apex agent run` — so the setting survives a
// logout, a reboot and a reinstall of the shell, without this service having to
// be running at all.
//
// The path is resolved the way apexd/apex-agent-core/src/paths.rs resolves it:
// $XDG_CONFIG_HOME when it is set and non-empty, otherwise $HOME/.config. A
// shell that guessed ~/.config would edit the wrong file for anybody who moves
// their config root, and would then report a setting no session has.
//
// ── WHAT GUARANTEES THE PROMPT IS OUT OF AN AGENT'S REACH ───────────────────
//
// Criterion 4 says the authentication happens outside the agent PTY, and three
// separate facts are what make that true rather than one:
//
//   1. The prompt is not drawn by this process. `pkcheck --allow-user-
//      interaction` asks polkitd, which asks the session's registered
//      authentication agent, which is a different process with its own Wayland
//      surface. The password goes keyboard → compositor → that surface. A PTY
//      is a file descriptor pair between apex-agentd and the agent program;
//      nothing written into it reaches another process's window.
//
//   2. The subject checked is this shell, and the only thing that starts the
//      check is a click on the toggle. There is no IPC verb, no CLI entry point
//      and no D-Bus method that reaches `authenticateAndSet` — an agent that
//      wanted the mode would have to be at the keyboard.
//
//   3. The file itself is outside a default session's world. `project` masks
//      the rest of $HOME with a tmpfs, so a session started under the default
//      policy cannot see ~/.config/apex at all, let alone write it.
//
// The honest limit, which is worth writing down where the next reader will find
// it: point 3 protects the transition AWAY from the default, not the state
// after it. A session that is ALREADY unrestricted is the user for filesystem
// purposes and can edit the file directly. That is what unrestricted means; the
// gate exists so nothing arrives there without a person, and the durable fix
// for the rest is on the runtime side, where the write can be owned by `apex`.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // apexd/apex-agent-core/src/paths.rs: config_file() is
    // config_home().join("apex/agent.json"), and config_home() is
    // $XDG_CONFIG_HOME or $HOME/.config.
    readonly property string configHome: {
        const x = Quickshell.env("XDG_CONFIG_HOME")
        return (x && x !== "") ? x : (Quickshell.env("HOME") + "/.config")
    }
    readonly property string configPath: root.configHome + "/apex/agent.json"

    // The polkit action id, matching dots-extra/polkit/org.apexos.shell.agent.policy.
    readonly property string actionId: "org.apexos.shell.agent.set-always-unrestricted"

    // ── What the file says ────────────────────────────────────────────────────
    property string _text: ""
    property bool loaded: false

    // The sandbox a NEW session gets, which is not always the key in the file:
    // `Config::normalise` resets all six dimensions when it meets a stored
    // default this build cannot enforce. agentpolicy.js carries that reasoning.
    readonly property string defaultSandbox: Policy.effectiveDefault(root._text)
    readonly property bool alwaysUnrestricted:
        root.defaultSandbox === Policy.UNRESTRICTED

    // Why the toggle cannot be switched on, or "". Shown next to a disabled
    // control rather than discovered after a click that failed.
    readonly property string enableRefusal: {
        const r = Policy.enableRefused(root._text)
        return r === null ? "" : r
    }

    // ── What happened to the last attempt ─────────────────────────────────────
    // "" while nothing is wrong. Cleared when a change succeeds, so a stale
    // refusal cannot sit under a toggle that has since moved.
    property string lastError: ""
    property bool busy: false

    readonly property FileView _file: FileView {
        id: configFile
        path: root.configPath
        watchChanges: true
        // The file does not exist until something writes it, which is the
        // normal state on a machine where nobody has changed a default.
        printErrors: false
        onFileChanged: configFile.reload()
        onLoaded: {
            root._text = configFile.text()
            root.loaded = true
        }
        onLoadFailed: {
            root._text = ""
            root.loaded = true
        }
    }

    // ── Changing it ───────────────────────────────────────────────────────────

    // The public entry point, and the only one. `on` is where the user wants to
    // end up; whether that needs a password is agentpolicy.js's decision and not
    // this function's opinion.
    function setAlwaysUnrestricted(on) {
        if (root.busy)
            return
        root.lastError = ""

        const want = on ? Policy.UNRESTRICTED : Policy.DEFAULT_SANDBOX
        if (want === root.defaultSandbox)
            return

        const proposed = Policy.nextConfig(root._text, on)
        if (!proposed.ok) {
            root.lastError = proposed.reason
            return
        }

        // Criterion 5: switching off is immediate and asks for nothing. The
        // scope of that is deliberately this branch and not a flag read further
        // down — a single write path with an `if (needsAuth)` inside it is one
        // careless edit away from prompting on the way out.
        if (!Policy.requiresAuth(root.defaultSandbox, want)) {
            root._write(proposed.text)
            return
        }

        root._pendingText = proposed.text
        root._authErr = ""
        root.busy = true
        root._authProc.running = false
        root._authProc.running = true
    }

    property string _pendingText: ""
    property string _authErr: ""

    // Its own Process, not the one that writes. A shared Process is how a second
    // click while the dialog is open cancels the dialog by reassigning
    // `command` out from under it.
    property Process _authProc: Process {
        // `exec` so the shell is replaced and the pid pkcheck reports as its
        // parent is the one it was told to check. `$$` is that shell, which is
        // this shell's child — polkit resolves the session from it either way,
        // and passing a pid keeps pkcheck from having to guess a subject.
        command: ["sh", "-c",
                  'exec pkcheck --action-id "$1" --process $$ --allow-user-interaction',
                  "--", root.actionId]
        running: false
        // Collected rather than parsed line by line: the one thing read out of
        // it is whether polkit said the action is not registered, and that
        // arrives as a single GDBus error on one line.
        stderr: StdioCollector { onStreamFinished: root._authErr = this.text }
        onExited: function(code) {
            const outcome = Policy.authOutcome(code, root._authErr)
            if (outcome !== Policy.AUTH_GRANTED) {
                root.busy = false
                root._pendingText = ""
                root.lastError = Policy.authMessage(outcome)
                return
            }
            root._write(root._pendingText)
            root._pendingText = ""
        }
    }

    // Atomic, and private. `umask 077` so a file created here is 0600 and the
    // directory 0700, matching paths::ensure_private_dir — the file records how
    // much of the machine the user's agents may touch, and it is nobody else's
    // business. The JSON goes in as a positional argument and never into the
    // command string, so a value in it cannot become shell syntax.
    property Process _writeProc: Process {
        command: []
        running: false
        onExited: function(code) {
            root.busy = false
            if (code !== 0) {
                root.lastError = "Could not write " + root.configPath + "."
                return
            }
            // Do not move the toggle here. The displayed state follows the
            // file, and the file is what the runtime will read: a control that
            // flipped on the strength of an exit code would show a mode the
            // next session might not have.
            root._file.reload()
        }
    }

    function _write(text) {
        root.busy = true
        root._writeProc.command = ["sh", "-c",
            'umask 077; d=$(dirname "$1"); mkdir -p "$d" || exit 1; '
          + 'printf %s "$2" > "$1.tmp" && mv "$1.tmp" "$1"',
            "--", root.configPath, text]
        root._writeProc.running = false
        root._writeProc.running = true
    }
}
