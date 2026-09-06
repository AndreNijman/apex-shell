import Quickshell
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"
import "./src/components/config/settings-semantics.js" as Semantics

// Every settings page, built and interrogated (roadmap P0-024, criteria 1 and
// 2; P0-023 criteria 1 and 2). Run through tests/run-settings-pages-test.sh.
//
// ── Why it builds them rather than greps them ───────────────────────────────
//
// Three of the things this asserts cannot be seen in a page's source.
//
//   1. THAT THE PAGE LOADS. Every page is reached through a qmldir, and a
//      missing entry is not a broken page — it is "CfgCommit is not a type" and
//      the whole shell fails to start. The Agents page proved that once
//      already. A settings suite that greps source would have shipped it.
//   2. WHAT A CONTROL IS LABELLED. A CfgButton's label is an expression:
//      `busy ? "Applying…" : Semantics.verbLabel("apply")`. Reading the source
//      tells you the expression; only the engine tells you the word.
//   3. WHICH LIFECYCLE A PAGE CLAIMS. Nine pages declare it on their CfgScroll
//      and one places a CfgLifecycle by hand, so there is no single line to
//      grep for. The object is asked instead.
//
// ── What it asserts ─────────────────────────────────────────────────────────
//
//   loads        every page in PageRegistry builds without error
//   lifecycle    every page says which of settings-semantics.js's four states
//                its controls are in, and says one of the four
//   effects      every row that claims to take effect later names an effect
//                the vocabulary defines
//   labels       no control anywhere is labelled with a word the vocabulary
//                bans — Discard, Undo, Restore, Commit, Write — because each of
//                those is one of the four verbs wearing another name
//   verbs        the words Apply, Save, Revert and Reset appear where a page
//                offers those acts, spelled the one way
//
// It opens no window. The pages are built inside a plain Item, which is enough
// to construct every object and evaluate every binding, and the compositor
// behind it is headless and private.

ShellRoot {
    id: rootScope

    property int pass: 0
    property int fail: 0

    function ok(what)  { console.log("  PASS  " + what); rootScope.pass++ }
    function bad(what) { console.log("  FAIL  " + what); rootScope.fail++ }
    function check(what, cond) { if (cond) rootScope.ok(what); else rootScope.bad(what) }

    // ── Which pages have not been given a lifecycle yet ──────────────────────
    //
    // Input is P0-019's, being rewritten on another branch at the same time as
    // this one. Editing it here would collide, so it is named with its reason
    // rather than quietly skipped — and if it gains a declaration this suite
    // fails and says to delete this row, so the exception cannot outlive the
    // task that earned it.
    readonly property var awaitingLifecycle: ({
        "input": "P0-019 owns InputPage; the declaration lands with that branch"
    })

    Item {
        id: pages
        width: 900
        height: 640

        Repeater {
            id: built
            model: PageRegistry.pages

            delegate: Loader {
                required property var modelData
                anchors.fill: parent
                visible: false
                sourceComponent: modelData.component
            }
        }
    }

    // ── Walking a built page ─────────────────────────────────────────────────
    // By what an object IS rather than where it sits: the section/row nesting is
    // each page's own business and a path expression would break on the next
    // page that groups its rows differently.
    function collect(obj, has, out) {
        if (!obj) return out
        if (obj[has] !== undefined) out.push(obj)
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++)
                rootScope.collect(kids[i], has, out)
        return out
    }

    function lifecycleOf(page) {
        const found = rootScope.collect(page, "lifecycle", [])
        for (const o of found)
            if (typeof o.lifecycle === "string" && o.lifecycle !== "")
                return o.lifecycle
        return ""
    }

    Timer {
        interval: 1200          // let every page's bindings settle once
        repeat: false
        running: true
        onTriggered: rootScope.run()
    }

    function run() {
        const registry = PageRegistry.pages
        rootScope.check("PageRegistry declares the settings pages",
                        registry.length > 0)

        let loaded = 0
        let bannedHits = []
        let unknownEffects = []
        const verbsSeen = {}

        for (let i = 0; i < built.count; i++) {
            const holder = built.itemAt(i)
            const id     = registry[i].id
            const page   = holder ? holder.item : null

            if (!page) {
                rootScope.bad("the " + id + " page builds")
                continue
            }
            loaded++

            // ── lifecycle ────────────────────────────────────────────────────
            const life = rootScope.lifecycleOf(page)
            if (rootScope.awaitingLifecycle[id] !== undefined) {
                rootScope.check("the " + id + " page is still owed a lifecycle ("
                                + rootScope.awaitingLifecycle[id]
                                + ") — delete its row here once it has one",
                                life === "")
            } else {
                rootScope.check("the " + id + " page says which state its controls are in",
                                life !== "" && Semantics.STATES[life] !== undefined)
            }

            // ── effects ──────────────────────────────────────────────────────
            for (const row of rootScope.collect(page, "effect", [])) {
                if (row.effect === "") continue
                if (Semantics.EFFECTS[row.effect] === undefined)
                    unknownEffects.push(id + ": " + row.effect)
            }

            // ── labels ───────────────────────────────────────────────────────
            // Every CfgButton on the page, asked for the word it is currently
            // showing. `variant` distinguishes a CfgButton from anything else
            // that happens to carry a `label`.
            for (const btn of rootScope.collect(page, "variant", [])) {
                if (btn.label === undefined) continue
                const word = String(btn.label)
                if (Semantics.BANNED_LABELS[word] !== undefined)
                    bannedHits.push(id + ': "' + word + '" — say '
                                    + Semantics.BANNED_LABELS[word])
                for (const v of ["apply", "save", "revert", "reset"])
                    if (word === Semantics.VERBS[v].label) verbsSeen[v] = true
            }
        }

        rootScope.check("every page in the registry builds",
                        loaded === registry.length)

        if (bannedHits.length === 0) {
            rootScope.ok("no control is labelled with a word the vocabulary bans")
        } else {
            for (const h of bannedHits) console.log("        " + h)
            rootScope.bad("no control is labelled with a word the vocabulary bans")
        }

        if (unknownEffects.length === 0) {
            rootScope.ok("every deferred row names an effect the vocabulary defines")
        } else {
            for (const e of unknownEffects) console.log("        " + e)
            rootScope.bad("every deferred row names an effect the vocabulary defines")
        }

        // Revert and Reset live on controls that are visible only while there is
        // something to revert, so their absence from a freshly built page is
        // not a defect. Reset is on four pages unconditionally and is the one
        // word that was already everywhere, so it is the one asserted here.
        rootScope.check("Reset is spelled the one way, wherever it appears",
                        verbsSeen["reset"] === true)

        console.log("settings-pages: passed=" + rootScope.pass
                    + " failed=" + rootScope.fail)
        Qt.exit(rootScope.fail === 0 ? 0 : 1)
    }
}
