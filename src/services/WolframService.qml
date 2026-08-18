pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "answer.js" as Answer

// ─────────────────────────────────────────────────────────────────────────────
// WolframService — plain-text answers from the Wolfram|Alpha Short Answers API.
//
// Only the launcher's "?" mode calls ask(); nothing here runs — no process, no
// timer, no network — until it does. That is deliberate: a normal app search
// must not pay for this.
//
// The API needs an AppID (free, developer.wolframalpha.com). It is user data,
// not shell configuration, so it lives in its own file written with umask 077
// rather than in settings.json, which is world-readable and rewritten wholesale
// on every appearance tweak.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: root

    readonly property string _cfgPath:
        Quickshell.env("HOME") + "/.config/apex-shell/src/user_data/wolfram.json"

    // ── Credentials ───────────────────────────────────────────────────────────
    property string appId: ""
    readonly property bool configured: appId !== ""

    // ── Result of the most recent ask() ───────────────────────────────────────
    property string queryText: ""   // the question the state below belongs to
    property bool   busy:      false
    property string answer:    ""
    property string error:     ""

    // Answers are cached for the shell's lifetime: retyping the same question
    // (or reopening the launcher) must not spend another API call — the free
    // tier is 2000 a month.
    property var  _cache:      ({})
    property var  _cacheOrder: []
    readonly property int _cacheMax: 64

    // Guards against a slow reply for an abandoned question overwriting a newer
    // one: every request carries a serial and only the current one is accepted.
    property int _serial: 0
    property int _inflight: 0

    function reset() {
        _serial++
        _inflight = 0
        _process.running = false
        busy      = false
        queryText = ""
        answer    = ""
        error     = ""
    }

    function ask(question) {
        var q = (question || "").trim()
        if (q === "") {
            reset()
            return
        }

        _serial++
        var serial = _serial
        queryText  = q

        if (_cache[q] !== undefined) {
            busy   = false
            answer = _cache[q]
            error  = ""
            return
        }

        answer = ""
        if (!configured) {
            busy  = false
            error = "Add a Wolfram|Alpha AppID in Settings → Misc to answer this"
            return
        }

        busy  = true
        error = ""
        _inflight = serial
        // argv, never a shell string: the question is arbitrary user input and
        // curl URL-encodes it itself. The trailing %{http_code} line is how the
        // API's meaning is read — 501 is "understood the request, no answer",
        // which is not a curl failure.
        _process.running = false
        _process.command = [
            "curl", "-sS", "-m", "10", "-G",
            "--data-urlencode", "appid=" + appId,
            "--data-urlencode", "i=" + q,
            "--data-urlencode", "units=metric",
            "-w", "\n%{http_code}",
            "https://api.wolframalpha.com/v1/result"
        ]
        _process.running = true
    }

    function _remember(q, text) {
        if (_cache[q] === undefined) {
            _cacheOrder.push(q)
            if (_cacheOrder.length > _cacheMax)
                delete _cache[_cacheOrder.shift()]
        }
        _cache[q] = text
    }

    function _finish(raw) {
        if (_inflight !== _serial) return   // a newer question is already in flight
        busy = false

        var read = Answer.describeAnswer(raw)
        answer = read.answer
        error  = read.error
        if (answer !== "") _remember(queryText, answer)
    }

    property var _process: Process {
        command: []
        running: false
        stdout: StdioCollector {
            id: outBuf
            onStreamFinished: root._finish(outBuf.text)
        }
    }

    // ── AppID persistence ─────────────────────────────────────────────────────
    function setAppId(id) {
        var v = (id || "").trim()
        if (v === root.appId) return
        root.appId = v
        // umask 077: the file holds a credential, so it is created 0600 even
        // though the surrounding config directory is not.
        _saveProc.command = ["bash", "-c",
            "umask 077 && mkdir -p \"$(dirname \"$2\")\" && printf '%s' \"$1\" > \"$2\"",
            "--", JSON.stringify({ appId: v }), root._cfgPath]
        _saveProc.running = false
        _saveProc.running = true
        // A new credential invalidates the "no AppID" answers already shown.
        root._cache      = ({})
        root._cacheOrder = []
    }

    property var _saveProc: Process { command: []; running: false }

    property var _loadProc: Process {
        command: ["bash", "-c", "cat \"$1\" 2>/dev/null || true", "--", root._cfgPath]
        running: false
        stdout: StdioCollector {
            id: loadBuf
            onStreamFinished: {
                try {
                    var o = JSON.parse(loadBuf.text.trim() || "{}")
                    if (typeof o.appId === "string") root.appId = o.appId.trim()
                } catch (e) {
                    console.log("WolframService: could not parse", root._cfgPath, e)
                }
            }
        }
    }

    Component.onCompleted: _loadProc.running = true
}
