pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "pushtotalk.js" as Ptt
// The same table the session rows and the notifications read, so the name the
// indicator says out loud is the name the Agent Center shows. "OpenCode", not
// "Opencode".
import "agentstate.js" as AgentState
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// PushToTalkService — the microphone, the recorder and the route.
// Roadmap P1-023, specified in ROADMAP.md §8.2.
//
// The DECISIONS are not here. When the microphone may open, whose session the
// words go to, what closes it again and what a refusal says are all
// src/services/pushtotalk.js, driven by `node tests/push-to-talk-test.js`
// against the same file this imports — 51 assertions, 13 mutants, all caught.
// This file is the part that cannot be driven by a node process: three
// subprocesses and their failure modes. Every state transition below goes
// through `Ptt.reduce`, so there is exactly one copy of the machine and the
// suite drives it.
//
// ── The microphone is shell-side, structurally ───────────────────────────────
//
// §8.2's fourth requirement — the one the 3-line yaml omits — is "no permanent
// microphone access to all agents", and AgentHelpContent.qml already tells the
// user a sandboxed session has "No camera and no microphone". So the recorder
// runs HERE and only TEXT ever crosses to a session. Nothing under
// src/services/agents/ names an audio device, and check-push-to-talk.sh fails
// on a mention, not merely on a use.
//
// The contract is NOT implemented by muting the default Pipewire source while
// idle: that would mute every other application on the machine. It is
// implemented by the recorder simply not running — `running: root.micOpen`,
// bound to the reducer — and by the indicator watching that process rather
// than watching a Pipewire node.
//
// ── Speech-to-text is a hook, not an engine ──────────────────────────────────
//
// No roadmap item anywhere owns STT and §8.2 says "route", so this bundles
// nothing. `~/.config/apex-shell/push-to-talk-stt` holds one line: a command
// that reads audio on stdin and writes text on stdout. Unset is the normal
// state on a fresh machine, and the reducer says so out loud rather than
// opening a microphone that leads nowhere.
// ─────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // ── The machine's state, and the only writer of it ────────────────────────
    property var state: Ptt.initial()

    // Every transition, from every source, funnels through here. Written once
    // so that "the recorder died" and "the key was pressed" cannot take
    // different paths into the same state object.
    function _dispatch(event) {
        root.state = Ptt.reduce(root.state, event, root._env())
    }

    readonly property string phase: root.state ? root.state.phase : "idle"
    readonly property bool   micOpen: Ptt.micOpen(root.state)
    readonly property string indicatorLabel: Ptt.indicatorLabel(root.state)
    readonly property string lastError: root.state ? root.state.error : ""

    // The resolved destination while the microphone is open, "" otherwise. The
    // topbar indicator shows this; it is the "explicit routing target" half of
    // the acceptance criterion.
    readonly property string targetLabel:
        root.state && root.state.target ? root.state.target.label : ""

    // ── Where the words go ────────────────────────────────────────────────────
    // A session the user chose, which outranks whatever they are looking at.
    // "" means "use the focused session".
    property string pinnedTarget: ""

    // §8.2 says "the active project or focused agent session". Spawning a new
    // session for the active project is OUT OF SCOPE for v1 — half-building it
    // would mean voice could create agents, which is a much larger permission
    // question than routing to one that already exists.
    function _env() {
        var out = []
        var ss = AgentService.sessions || []
        for (var i = 0; i < ss.length; i++) {
            var s = ss[i]
            if (!s || s.id === undefined || s.id === null) continue
            out.push({
                id: s.id,
                // The reducer treats a missing `live` as live, so this is
                // passed explicitly: a session that has exited must not be a
                // valid destination.
                live: s.exit_code === null && s.exit_signal === null,
                agent: AgentState.agentName(s.agent || ""),
                project: root._basename(s.cwd)
            })
        }
        return {
            sessions: out,
            pinned: root.pinnedTarget === "" ? null : root.pinnedTarget,
            focused: AgentService.lastFocusedId === "" ? null : AgentService.lastFocusedId,
            sttConfigured: root.sttConfigured
        }
    }

    function _basename(p) {
        if (!p) return ""
        var parts = String(p).replace(/\/+$/, "").split("/")
        return parts[parts.length - 1] || p
    }

    // ── The public entry point, and the only one ──────────────────────────────
    // Reached from IpcManager's `voice-ptt` handler, which the compositor
    // keybind calls. One function for press and for press-again: the reducer
    // decides which of those this is.
    function toggle() {
        root._dispatch({ type: "toggle", now: Date.now() })
    }

    // ── The cap ───────────────────────────────────────────────────────────────
    // A toggle can be left on. The reducer owns the limit and the arithmetic;
    // this only has to ask it often enough that the answer is timely. One
    // second is finer than the number it guards by two orders of magnitude, and
    // the timer only runs while the microphone is open.
    property var _capTimer: Timer {
        interval: 1000
        repeat: true
        running: root.micOpen
        onTriggered: root._dispatch({ type: "tick", now: Date.now() })
    }
    readonly property int remainingMs: Ptt.remainingMs(root.state, Date.now())

    // ── Letting a refusal go ──────────────────────────────────────────────────
    // "error" is the only phase that does not end on its own, and the indicator
    // is in the top bar. Unset speech-to-text is the normal state of a fresh
    // install, so without this one press would pin "no speech-to-text command
    // is configured" into the notch until the next press showed it again.
    //
    // Six seconds is long enough to read a sentence and short enough that it
    // does not become furniture. The reducer refuses a dismiss on every other
    // phase, so this timer cannot drop a live microphone or lose words already
    // spoken however wrong its `running:` condition ever gets.
    property var _errorTimer: Timer {
        interval: 6000
        repeat: false
        running: root.phase === "error"
        onTriggered: root._dispatch({ type: "dismiss" })
    }

    // ── The STT hook ──────────────────────────────────────────────────────────
    readonly property string _sttPath:
        Quickshell.env("HOME") + "/.config/apex-shell/push-to-talk-stt"
    property string sttCommand: ""
    readonly property bool sttConfigured: root.sttCommand.trim() !== ""

    readonly property FileView _sttView: FileView {
        id: sttFile
        path: root._sttPath
        watchChanges: true
        // Absent is the normal state, not an error worth logging on every
        // login. The reducer reports it when the key is actually pressed,
        // which is the moment a person can do something about it.
        printErrors: false
        onFileChanged: sttFile.reload()
        onLoaded: root.sttCommand = sttFile.text().split("\n")[0].trim()
        onLoadFailed: root.sttCommand = ""
    }

    // ── The recorder ──────────────────────────────────────────────────────────
    // parecord and not pw-record: measured on this machine, parecord and
    // arecord are present and pw-record is not, so pw-record would be a
    // Containerfile change in exchange for nothing.
    //
    // `running: root.micOpen` is the whole privacy contract in one line. It is
    // asserted by tests/check-push-to-talk.sh against this block with the
    // comments stripped, because `running: true` here would be a permanently
    // hot microphone and nothing else in the tree would say so.
    readonly property string _wavPath: "/tmp/apex-ptt-" + Quickshell.env("USER") + ".wav"

    property var _recorder: Process {
        command: ["parecord", "--file-format=wav", "--channels=1",
                  "--rate=16000", root._wavPath]
        running: root.micOpen
        onExited: function (code, status) {
            // The recorder is STOPPED by the state leaving "recording", so on
            // the ordinary path it is already transcribing by the time this
            // fires and there is nothing to report. Only an exit while the
            // machine still believes it is recording is a real failure.
            if (root.phase === "recording")
                root._dispatch({ type: "fail", error: "the recorder stopped on its own" })
            else if (root.phase === "transcribing")
                root._stt.running = true
        }
    }

    // ── Transcription ─────────────────────────────────────────────────────────
    property string _sttBuf: ""
    property var _stt: Process {
        command: ["bash", "-c",
                  'cmd=$(head -n1 "$1"); [ -n "$cmd" ] || exit 3; ' +
                  'exec bash -c "$cmd" < "$2"',
                  "--", root._sttPath, root._wavPath]
        running: false
        stdout: SplitParser { onRead: function (line) { root._sttBuf += line + "\n" } }
        onStarted: root._sttBuf = ""
        onExited: function (code, status) {
            if (code !== 0) {
                root._dispatch({ type: "fail",
                                 error: "the speech-to-text command exited " + code })
                return
            }
            root._dispatch({ type: "transcript", text: root._sttBuf })
            if (root.phase === "delivering")
                root._deliver()
        }
    }

    // ── Delivery ──────────────────────────────────────────────────────────────
    // NOT BUILT YET, and said so rather than faked. There is no way to put text
    // into a session today: AgentService's whole action surface is
    // pause/resume/kill/focus/review, and apex-agent-core's Request enum has no
    // Input variant. `Attach` is already a bidirectional PTY byte stream, so the
    // write path exists and a `Request::Input { id, data }` reuses it — that is
    // the apex-os half of P1-023 and it is tracked on
    // task/p1-023-push-to-talk-daemon.
    //
    // Piping into `apex agent attach` is NOT the shortcut it looks like: its
    // reader loop keeps running after stdin EOF until the session itself
    // closes, and `replay` defaults non-zero, so it would hang and dump
    // scrollback into the transcript.
    //
    // Until the verb exists this fails with the reason, the indicator shows it,
    // and AgentHelpContent says so. A transcript that silently goes nowhere
    // would be the worse outcome by a long way.
    property var _delivery: Process {
        command: []
        running: false
        onExited: function (code, status) {
            if (code === 0) root._dispatch({ type: "delivered" })
            else root._dispatch({ type: "fail",
                                  error: "this build cannot type into a session yet" })
        }
    }

    function _deliver() {
        var t = root.state && root.state.target ? root.state.target.id : ""
        if (!t) {
            root._dispatch({ type: "fail", error: "the target went away" })
            return
        }
        root._delivery.command = ["apex", "agent", "input", String(t), root.state.text]
        root._delivery.running = true
    }
}
