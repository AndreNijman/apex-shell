import Quickshell
import QtQuick
// The same module set run-compositor-facade-test.sh declares. PluginWidgets
// imports "../../", and reaching src/qmldir pulls in the whole singleton graph
// — PageRegistry wants DataPage out of src/services, and so on down. Importing
// only what this file names directly gets "DataPage is not a type" from four
// levels away, which reads as a bug in the plugin platform and is not one.
import "./src/components"
import "./src/services"
import "./src/nexus"
import "./src/popups"
import "./src/modules/Right"
import "./src"

// ─────────────────────────────────────────────────────────────────────────────
// Behavioural test for the APEX Shell plugin platform — roadmap §16.
//
//     ./tests/run-plugin-host-test.sh
// Exit status 0 = all assertions passed, 1 = at least one failed.
//
// ── It never touches the real plugin directory ───────────────────────────────
// The harness builds a fixture tree under XDG_RUNTIME_DIR and passes its path
// in APEX_PLUGIN_FIXTURES; this file points PluginService.pluginDir at that and
// rescans. Nothing here reads or writes ~/.config/apex-shell/plugins beyond the
// single directory listing the singleton does when it is constructed.
//
// ── And it makes no network call ─────────────────────────────────────────────
// The granted-network path is checked BY SHAPE — the plugin holds the
// permission, the host is in its list — and never by fetching. Suites in this
// repo run against the developer's real machine, so the rule is: assert the
// refusals, and check the capable paths without invoking them. The one time
// that rule was broken, a test set the live Hyprland gaps to zero.
//
// What it proves that the headless halves cannot:
//   1. Discovery actually finds plugins on a real filesystem, and a directory
//      with no plugin.json is not one.
//   2. Each refusal reason arrives on the right fixture, through the real
//      FileView/Process path rather than a string handed to a function.
//   3. CRASH ISOLATION: a plugin that passes every static check and then fails
//      to load puts its Loader in Loader.Error, is recorded as refused, and
//      does not take the shell — or the other plugins — down with it. The
//      other assertions running after it are the proof.
//   4. The permission gates refuse through the real api object a plugin is
//      handed, not through a directly-called validator.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0

    function check(name, cond) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else      { root.failed++; console.log("  FAIL  " + name) }
    }

    readonly property string fixtures: Quickshell.env("APEX_PLUGIN_FIXTURES")

    function stateOf(id) {
        const r = PluginService.recordFor(id)
        return r ? r.state : "absent"
    }
    function reasonOf(id) {
        const r = PluginService.recordFor(id)
        return r ? r.reason : "absent"
    }

    // The widget host, exactly as the bar instantiates it. Loading it here is
    // what drives the crash-isolation case: the Loader inside it is the thing
    // that meets the broken plugin.
    property Item host: PluginWidgets {}

    // ── Async results, filled in by the callbacks below ──────────────────────
    property string netQuietErr:   "<pending>"
    property bool   netQuietCalled: false
    property string fileGoodText:  "<pending>"
    property bool   fileGoodOk:     false
    property string fileEscapeErr: "<pending>"
    property string fileQuietErr:  "<pending>"

    property int phase: 0

    property Timer driver: Timer {
        interval: 700
        repeat: true
        running: true
        onTriggered: root.step()
    }

    function step() {
        switch (root.phase++) {

        case 0: {
            // Point the platform at the fixtures and rescan. Everything after
            // this concerns the fixture tree only.
            check("the harness supplied a fixture directory", root.fixtures !== "")
            PluginService.pluginDir = root.fixtures
            PluginService.rescan()
            break
        }

        case 1: {
            // ── Discovery ────────────────────────────────────────────────────
            check("the scan completed", PluginService.scanned)
            check("nine plugin directories were found",
                  PluginService.found.length === 9)
            // A directory with a .qml but no plugin.json is not a plugin, and
            // must not appear even as a refusal — there is nothing to refuse.
            check("a directory with no manifest is not enumerated",
                  root.stateOf("nomanifest") === "absent")
            break
        }

        case 2: {
            // ── Grants ───────────────────────────────────────────────────────
            check("a valid plugin loads",              root.stateOf("good")  === "loaded")
            check("a plugin asking for nothing loads", root.stateOf("quiet") === "loaded")
            check("a network plugin loads",            root.stateOf("netty") === "loaded")

            // ── Refusals, each on the fixture built to trigger it ────────────
            check("a future apiVersion is refused",
                  root.stateOf("oldapi") === "refused"
                  && root.reasonOf("oldapi") === "api-version-unsupported")
            check("reaching past the API is refused",
                  root.stateOf("sneaky") === "refused"
                  && root.reasonOf("sneaky") === "forbidden-import")
            check("an unimplemented permission is refused",
                  root.stateOf("secretive") === "refused"
                  && root.reasonOf("secretive") === "permission-not-implemented")
            check("a second .qml is refused",
                  root.stateOf("twofiles") === "refused"
                  && root.reasonOf("twofiles") === "extra-qml")
            check("an id that does not match its directory is refused",
                  root.stateOf("mismatch") === "refused"
                  && root.reasonOf("mismatch") === "id-directory-mismatch")

            // A refused plugin must never be handed to the QML engine.
            const bad = PluginService.recordFor("sneaky")
            check("a refused plugin has no entry URL", String(bad.entryUrl) === "")
            break
        }

        case 3: {
            // ── The extension point ──────────────────────────────────────────
            // Only granted bar-widget plugins are mounted. `broken` is still
            // among them at this point: it passed every static check, and the
            // Loader has not reported back yet.
            const mounted = PluginService.widgetsFor("bar-widget")
            check("only granted plugins reach the extension point",
                  mounted.length === PluginService.loaded.length)
            check("refused plugins are not in the mounted set",
                  mounted.filter(function (r) { return r.pluginId === "sneaky" }).length === 0)
            break
        }

        case 4: {
            // ── CRASH ISOLATION ──────────────────────────────────────────────
            // `broken` passes the manifest checks and the source scan, then
            // fails in the QML engine. The Loader catches it, the record turns
            // into a refusal, and — the part that matters — this process is
            // still alive to assert it. Every assertion after this one is a
            // second proof of the same thing.
            check("a plugin that fails to load is recorded as refused",
                  root.stateOf("broken") === "refused")
            check("and the reason names the load failure",
                  root.reasonOf("broken") === "load-error")
            check("the shell survived it",
                  root.stateOf("good") === "loaded" && root.stateOf("quiet") === "loaded")
            check("the widget host is still alive", root.host !== null)
            break
        }

        case 5: {
            // ── The network gate, through the real api object ────────────────
            const quiet = PluginService.recordFor("quiet")
            const netty = PluginService.recordFor("netty")

            check("a plugin without the permission reports not having it",
                  quiet.api.has("network") === false)
            check("a plugin with it reports having it",
                  netty.api.has("network") === true)

            // The refusal path is invoked for real: this must return without
            // spawning anything.
            quiet.api.net.get("https://api.github.com/user", function (ok, body, err) {
                root.netQuietCalled = true
                root.netQuietErr = err
            })

            // The GRANTED path is deliberately NOT invoked — see the header.
            // Checked by shape instead: the grant carries the host, so
            // permitsUrl would allow it.
            check("the granted plugin's host is in its grant",
                  netty.grant.networkHosts.indexOf("api.github.com") >= 0)
            check("and a host it did not name is not",
                  netty.grant.networkHosts.indexOf("evil.com") < 0)
            break
        }

        case 6: {
            check("the refused network call came back", root.netQuietCalled)
            check("it was refused, not attempted",
                  root.netQuietErr.indexOf("did not declare") >= 0)

            // ── The files gate ───────────────────────────────────────────────
            const good  = PluginService.recordFor("good")
            const quiet = PluginService.recordFor("quiet")

            good.api.files.readText("config.json", function (ok, text) {
                root.fileGoodOk   = ok
                root.fileGoodText = text
            })
            good.api.files.readText("../../../../etc/passwd", function (ok, text, err) {
                root.fileEscapeErr = err
            })
            quiet.api.files.readText("config.json", function (ok, text, err) {
                root.fileQuietErr = err
            })
            break
        }

        case 7: {
            check("a plugin with `files` reads its own directory",
                  root.fileGoodOk && root.fileGoodText.indexOf("world") >= 0)
            check("traversal out of the plugin directory is refused",
                  root.fileEscapeErr.indexOf("inside the plugin") >= 0)
            check("a plugin without `files` is refused",
                  root.fileQuietErr.indexOf("did not declare") >= 0)

            // ── The API surface a plugin is promised ─────────────────────────
            const good = PluginService.recordFor("good")
            check("the api carries the version",  good.api.apiVersion === PluginService.apiVersion)
            check("the api carries the plugin id", good.api.id === "good")
            check("the api carries a theme",      good.api.theme.foreground !== undefined)
            check("the api reports its permissions",
                  good.api.permissions.length === 1 && good.api.permissions[0] === "files")
            break
        }

        case 8: {
            // Rescanning is idempotent — a settings page offering a refresh
            // button must not multiply the records.
            check("records match the loaded plus refused split",
                  PluginService.records.length
                  === PluginService.loaded.length + PluginService.refused.length)
            PluginService.rescan()
            break
        }

        case 9: {
            check("a rescan does not duplicate records",
                  PluginService.records.length === 9)
            break
        }

        default: {
            root.driver.running = false
            console.log("passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
        }
        }
    }
}
