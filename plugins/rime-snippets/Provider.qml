import QtQuick

// ─── Snippets ─────────────────────────────────────────────────────────────────
// The reference `launcher-provider` plugin (roadmap §16). Type in the launcher
// and the text snippets that match appear below the app results; Enter copies
// the one on screen.
//
// It is here to be READ as much as to be used, so it exercises each part of the
// launcher-provider contract exactly once:
//
//   * `property var api` — the host assigns the capability object here, once,
//     before this plugin is asked anything. Same handshake as a bar widget.
//   * `property string query` — the host WRITES this, debounced, whenever the
//     launcher's search text changes. It is empty whenever the launcher is not
//     consulting providers: on an empty search box, on a one-character search,
//     and on a "?" answer query.
//   * `property var results` — the host READS this. An array of
//     `{ title, subtitle, icon }`. Every other key is dropped, and the host
//     builds its own row objects from what survives; see the PLUGIN OUTPUT
//     section of src/services/plugins/manifest.js for why.
//   * `function activate(index)` — optional. The host has already copied the
//     row's title and closed the launcher; this says which of THIS plugin's
//     rows was chosen, by index into the array above.
//   * `api.files.readText()` — the `files` permission, declared in plugin.json.
//     Reads snippets.json out of this plugin's own directory. There is no
//     built-in fallback list on purpose: remove `files` from the manifest and
//     this provider returns nothing at all, which is the gate working and is
//     worth seeing.
//
// ── The title is the payload ──────────────────────────────────────────────────
// A row's `title` is both what the launcher DISPLAYS and what activating it
// copies. There is no separate value field. So a snippet's row puts the snippet
// TEXT on the first line and its human label on the second — you copy the thing
// you were looking at. A contract with a hidden payload would let a plugin show
// "email signature" and copy something else entirely, with the user's own Enter
// key as the gesture.
//
// ── This plugin never paints ───────────────────────────────────────────────────
// A launcher provider's root item is loaded into an invisible host. Bindings and
// timers run; nothing here can put a pixel on screen. So there is no Text, no
// Rectangle and no use for api.theme — the shell draws the rows.
// ──────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    // ── The handshake ─────────────────────────────────────────────────────────
    property var api: null

    // Written by the host. Empty means "not being asked".
    property string query: ""

    // ── Loaded from this plugin's own directory ───────────────────────────────
    // [{ label, text }]. Empty until the read lands, and empty forever if the
    // `files` permission is not held.
    property var snippets: []

    // ── What the host renders ─────────────────────────────────────────────────
    // A function rather than a block binding: `property var x: { … }` is the
    // one genuinely ambiguous corner of QML's grammar, and a reference plugin
    // should not be teaching it.
    readonly property var results: root._match(root.query, root.snippets)

    function _match(q, list) {
        const out = []
        if (typeof q !== "string" || q === "")
            return out
        const needle = q.toLowerCase()
        for (var i = 0; i < list.length; i++) {
            const s = list[i]
            if (!s)
                continue
            const label = String(s.label || "")
            const text  = String(s.text  || "")
            if (text === "")
                continue
            if (label.toLowerCase().indexOf(needle) < 0
                && text.toLowerCase().indexOf(needle) < 0)
                continue
            // title is the payload; subtitle is the label. The host appends
            // this plugin's name to whatever subtitle it is given, so a row
            // always says where it came from.
            out.push({ "title": text, "subtitle": label })
        }
        return out
    }

    // ── Activation ────────────────────────────────────────────────────────────
    // The chosen snippet moves to the front, so the ones actually used rank
    // first next time. Nothing is persisted: writing would need the plugin
    // directory to be writable, and it is deliberately not — see permitsPath()
    // in manifest.js for why a plugin that could rewrite its own source between
    // the load-time scan and the next start is a problem rather than a feature.
    function activate(index) {
        const rows = root.results
        if (index < 0 || index >= rows.length)
            return
        const chosen = rows[index].title
        const next = []
        for (var i = 0; i < root.snippets.length; i++)
            if (String(root.snippets[i].text || "") === chosen)
                next.push(root.snippets[i])
        for (var j = 0; j < root.snippets.length; j++)
            if (String(root.snippets[j].text || "") !== chosen)
                next.push(root.snippets[j])
        root.snippets = next
    }

    // ── Reading the snippet file ──────────────────────────────────────────────
    // `api` arrives after this component is constructed, so the read hangs off
    // the change rather than Component.onCompleted, which runs first and would
    // see null.
    onApiChanged: {
        if (!root.api)
            return

        // A well-behaved plugin checks before it calls, so a refusal is a
        // branch rather than a surprise.
        if (!root.api.has("files"))
            return

        root.api.files.readText("snippets.json", function (ok, text) {
            if (!ok || !text)
                return
            try {
                const cfg = JSON.parse(text)
                if (!cfg || !Array.isArray(cfg.snippets))
                    return
                const out = []
                for (var i = 0; i < cfg.snippets.length && out.length < 200; i++) {
                    const s = cfg.snippets[i]
                    if (!s || typeof s.text !== "string" || s.text === "")
                        continue
                    out.push({
                        "label": typeof s.label === "string" ? s.label : "",
                        "text":  s.text
                    })
                }
                root.snippets = out
            } catch (e) {
                // A malformed file is the user's typo. The provider stays quiet
                // rather than breaking the launcher's search.
            }
        })
    }
}
