import Quickshell
import QtQuick
// The same module set run-compositor-facade-test.sh declares. PluginWidgets
// imports "../../", and reaching src/qmldir pulls in the whole singleton graph
// — PageRegistry wants DataPage out of src/services, and so on down. Importing
// only what this file names directly gets "DataPage is not a type" from four
// levels away, which reads as a bug in the plugin platform and is not one.
import "./src/components"
import "./src/services"
import "./src/services/home"
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
// ── It writes nothing outside its own fixture tree ───────────────────────────
// The harness builds a fixture tree under XDG_RUNTIME_DIR and passes its path
// in APEX_PLUGIN_FIXTURES; this file points PluginService.pluginDir at that and
// rescans. The last two phases then point it at the checkout's own plugins/
// directory (APEX_PLUGIN_REPO) to exercise the plugin this repo ships — read
// only, and nothing in this file ever writes to either location.
//
// On a normal install the shell is checked out AT ~/.config/apex-shell, so that
// second directory is the very path PluginService defaults to. Reading it is
// the point; the suite must never modify it.
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
//   5. Each of the three extension points mounts through the host the shell
//      really uses, and a plugin lands only on the point it declared.
//   6. THE ROW ALLOWLIST, end to end. One fixture passes every static check and
//      then hands back rows carrying `exec`, `entry` and a `command` array —
//      the fields AppLauncher.activate() dispatches on. The node suite proves
//      the sanitiser drops them; this proves nothing puts them back on the way
//      through a real Loader, a real property written by the host, and a real
//      array read back out.
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

    // The repo's own plugins/ directory. On a normal install the shell is
    // checked out at ~/.config/apex-shell, so this is literally the path
    // PluginService defaults to — which is what makes the last two phases a
    // test of the shipped plugin rather than of another fixture.
    readonly property string repoPlugins: Quickshell.env("APEX_PLUGIN_REPO")

    function stateOf(id) {
        const r = PluginService.recordFor(id)
        return r ? r.state : "absent"
    }
    function reasonOf(id) {
        const r = PluginService.recordFor(id)
        return r ? r.reason : "absent"
    }

    // The three extension-point hosts, exactly as the shell instantiates them.
    // Loading the first is what drives the crash-isolation case: the Loader
    // inside it is the thing that meets the broken plugin.
    //
    // The other two are here because they are the points where the SHELL draws
    // plugin-supplied strings, and the node suite can only check the sanitiser
    // by calling it. These check that nothing puts the dangerous fields back on
    // the way through a real Loader, a real property written by the host, and a
    // real array read back out.
    property Item host: PluginWidgets {}
    property PluginLauncher providerHost: PluginLauncher {}
    property PluginTiles    tileHost:     PluginTiles {}

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
            check("fourteen plugin directories were found",
                  PluginService.found.length === 14)
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

            // The case no textual path check can catch: a symlinked
            // subdirectory makes "data/secret.txt" resolve outside the plugin
            // while containing no "..", no absolute prefix and no
            // dot-component. Discovery refuses the whole plugin instead.
            check("a symlink in the plugin directory is refused",
                  root.stateOf("linky") === "refused"
                  && root.reasonOf("linky") === "entry-outside-plugin")

            // A refused plugin must never be handed to the QML engine.
            const bad = PluginService.recordFor("sneaky")
            check("a refused plugin has no entry URL", String(bad.entryUrl) === "")
            break
        }

        case 3: {
            // ── The extension points ─────────────────────────────────────────
            // Only granted plugins are mounted, and only at the point they
            // declared. `broken` is still among the bar widgets at this point:
            // it passed every static check, and the Loader has not reported
            // back yet.
            const bars      = PluginService.pluginsFor("bar-widget")
            const providers = PluginService.pluginsFor("launcher-provider")
            const tiles     = PluginService.pluginsFor("quick-settings-tile")

            check("the three points partition the granted plugins",
                  bars.length + providers.length + tiles.length
                  === PluginService.loaded.length)
            check("refused plugins are not in any mounted set",
                  bars.concat(providers, tiles)
                      .filter(function (r) { return r.pluginId === "sneaky" }).length === 0)

            // An extension point is part of the grant, so a plugin cannot land
            // on a point it did not ask for. That is the property every host
            // relies on when it calls pluginsFor() and trusts what comes back.
            check("a bar widget is not mounted as a provider",
                  providers.filter(function (r) { return r.pluginId === "good" }).length === 0)
            check("a provider is not mounted as a bar widget",
                  bars.filter(function (r) { return r.pluginId === "provider" }).length === 0)
            check("a provider is not mounted as a tile",
                  tiles.filter(function (r) { return r.pluginId === "provider" }).length === 0)
            check("both providers are mounted", providers.length === 2)
            check("both tile plugins are mounted", tiles.length === 2)
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
            // ── The launcher-provider point, through its real host ───────────
            // Ask a question. The host debounces by 120 ms and this driver
            // ticks at 700, so the rows are ready by the next phase.
            check("providers are quiet until asked",
                  root.providerHost.rows.length === 0)
            root.providerHost.query = "ab"
            break
        }

        case 9: {
            const rows = root.providerHost.rows
            check("a provider's rows reach the host", rows.length > 0)
            check("every row is a plugin row",
                  rows.filter(function (r) { return r.kind === "plugin" }).length
                  === rows.length)

            const mine = rows.filter(function (r) { return r.pluginId === "provider" })
            check("the provider contributed both its rows", mine.length === 2)
            check("a row's title is the plugin's title", mine[0].name === "hit for ab")
            check("a row's second line carries the subtitle and the plugin's name",
                  mine[0].detail === "sub · Provider")
            check("a row with no subtitle still names its plugin",
                  mine[1].detail === "Provider")
            check("an icon name survives", mine[0].icon === "firefox")

            // ── THE case the allowlist exists for ────────────────────────────
            // `nasty` passes every static check and then hands back rows
            // carrying the fields AppLauncher.activate() dispatches on. `exec`
            // reaches `bash -c "setsid " + exec`, so a row that kept it would
            // be arbitrary command execution granted to a plugin that declared
            // no permissions at all — the `system` permission this shell
            // refuses at load, through the back door.
            const bad = rows.filter(function (r) { return r.pluginId === "nasty" })
            check("the hostile provider's rows arrived at all", bad.length === 2)
            check("no row carries an exec string",
                  rows.filter(function (r) { return r.exec !== undefined }).length === 0)
            check("no row carries a DesktopEntry",
                  rows.filter(function (r) { return r.entry !== undefined }).length === 0)
            check("no row carries a command array",
                  rows.filter(function (r) { return r.command !== undefined }).length === 0)
            check("no row carries a hidden value",
                  rows.filter(function (r) { return r.value !== undefined }).length === 0)
            check("no row carries a launcher id",
                  rows.filter(function (r) { return r.id !== undefined }).length === 0)
            check("a filesystem path is not an icon", bad[0].icon === "")
            check("a newline in a title is stripped", bad[1].name === "twolines")
            check("provenance cannot be forged",
                  bad[1].detail === "System Settings · Nasty")

            // Activation reaches the plugin, by index into ITS array. The
            // fixture changes its first title once activated, so the effect is
            // observable through the host rather than by reaching inside it.
            root.providerHost.notifyActivated("provider", 1)
            break
        }

        case 10: {
            const mine = root.providerHost.rows
                             .filter(function (r) { return r.pluginId === "provider" })
            check("activation reached the plugin", mine[0].name === "used ab")

            // An answer query belongs to the calculator and Wolfram|Alpha. A
            // provider row appearing there would sit exactly where the answer
            // goes, so the host stops asking.
            root.providerHost.query = "?ab"
            break
        }

        case 11: {
            check("an answer query yields no provider rows",
                  root.providerHost.rows.length === 0)
            root.providerHost.query = "a"
            break
        }

        case 12: {
            check("a one-character query yields no provider rows",
                  root.providerHost.rows.length === 0)

            // ── The quick-settings-tile point, through its real host ─────────
            const tiles = root.tileHost.tiles
            check("tiles reach the host", tiles.length === 2)

            const t = tiles.filter(function (x) { return x.pluginId === "tiler" })[0]
            const i = tiles.filter(function (x) { return x.pluginId === "inert" })[0]
            check("a tile starts off",            t.on === false)
            check("a tile carries its label",     t.label === "Fixture")
            check("a tile carries its glyph",     t.icon === "X")
            // Boolean("true") is true. A plugin declaring `property var on`
            // with a string in it must not light the tile up.
            check("a non-boolean `on` does not light the tile", i.on === false)
            check("an empty label falls back to the plugin's name",
                  i.label === "Inert")
            check("no tile carries a command",
                  tiles.filter(function (x) { return x.command !== undefined }).length === 0)

            root.tileHost.toggle("tiler")
            // `inert` declares no toggle(). Clicking its tile must be a log
            // line, not an exception that takes the grid holding the Wi-Fi and
            // Airplane Mode toggles down with it.
            root.tileHost.toggle("inert")
            root.tileHost.toggle("no-such-plugin")
            break
        }

        case 13: {
            const tiles = root.tileHost.tiles
            const t = tiles.filter(function (x) { return x.pluginId === "tiler" })[0]
            check("clicking a tile reaches the plugin", t.on === true)
            check("and the redrawn tile shows the new state", t.sublabel === "running")
            check("a tile with no toggle() did not take the grid down",
                  tiles.length === 2)
            check("the shell survived all three clicks",
                  root.stateOf("good") === "loaded")

            // Rescanning is idempotent — a settings page offering a refresh
            // button must not multiply the records.
            check("records match the loaded plus refused split",
                  PluginService.records.length
                  === PluginService.loaded.length + PluginService.refused.length)
            PluginService.rescan()
            break
        }

        case 14: {
            check("a rescan does not duplicate records",
                  PluginService.records.length === 14)

            // ── The plugins this repo actually ships ─────────────────────────
            // Everything above ran against fixtures this harness wrote, which
            // proves the platform and proves nothing about the three examples.
            // Point the real thing at the real directory: on a normal install
            // the shell lives at ~/.config/apex-shell, so repoPlugins IS the
            // path PluginService would use by itself.
            PluginService.pluginDir = root.repoPlugins
            PluginService.rescan()
            break
        }

        case 15: {
            // One example per extension point, and every one of them granted.
            // A point whose example is refused is a point nobody has actually
            // run a plugin against.
            check("three plugins ship with this repo",
                  PluginService.found.length === 3)
            check("the bar widget example is granted",
                  root.stateOf("apex-worldclock") === "loaded")
            check("the launcher provider example is granted",
                  root.stateOf("apex-snippets") === "loaded")
            check("the quick-settings tile example is granted",
                  root.stateOf("apex-pomodoro") === "loaded")

            const wc = PluginService.recordFor("apex-worldclock")
            const sn = PluginService.recordFor("apex-snippets")
            const pm = PluginService.recordFor("apex-pomodoro")

            check("the world clock is a bar widget",
                  wc.grant.extensionPoint === "bar-widget")
            check("the snippets plugin is a launcher provider",
                  sn.grant.extensionPoint === "launcher-provider")
            check("the pomodoro is a quick-settings tile",
                  pm.grant.extensionPoint === "quick-settings-tile")

            check("the world clock holds exactly the files permission",
                  wc.grant.permissions.length === 1
                  && wc.grant.permissions[0] === "files")
            check("the snippets plugin holds exactly the files permission",
                  sn.grant.permissions.length === 1
                  && sn.grant.permissions[0] === "files")
            // The tile example holds nothing, which is the demonstration: the
            // whole round trip works with no permission granted, so nothing
            // about the point is hiding behind one.
            check("the pomodoro holds no permissions",
                  pm.grant.permissions.length === 0)

            check("no shipped example asked for a network host",
                  wc.grant.networkHosts.length === 0
                  && sn.grant.networkHosts.length === 0
                  && pm.grant.networkHosts.length === 0)

            // The compatibility policy, live: the world clock still declares
            // 1.0 and is still granted by a 1.1 host, and the two plugins that
            // need a 1.1 extension point say so.
            check("an apiVersion 1.0 plugin is still granted by this host",
                  wc.grant.apiVersion === "1.0")
            check("the two new examples declare 1.1",
                  sn.grant.apiVersion === "1.1" && pm.grant.apiVersion === "1.1")

            check("each example reaches its own point",
                  PluginService.pluginsFor("bar-widget").length === 1
                  && PluginService.pluginsFor("launcher-provider").length === 1
                  && PluginService.pluginsFor("quick-settings-tile").length === 1)
            check("each example has a URL to load",
                  String(wc.entryUrl) !== "" && String(sn.entryUrl) !== ""
                  && String(pm.entryUrl) !== "")

            root.providerHost.query = "shrug"
            break
        }

        case 16: {
            // The hosts mounted all three and no Loader reported an error, so
            // each parsed and constructed. A plugin that failed here would have
            // turned into a load-error refusal, exactly like `broken` did.
            check("every shipped example survived being mounted",
                  root.stateOf("apex-worldclock") === "loaded"
                  && root.stateOf("apex-snippets")   === "loaded"
                  && root.stateOf("apex-pomodoro")   === "loaded")

            // And the shipped provider actually answers. This is the end of the
            // chain the static suites cannot reach: a real plugin reading a
            // real file through the `files` gate, matching a real query, and
            // its rows arriving sanitised in the real host.
            const rows = root.providerHost.rows
            check("the shipped provider produced a row", rows.length === 1)
            check("its row came from the snippets plugin",
                  rows[0].pluginId === "apex-snippets")
            check("its row names the snippet it matched",
                  rows[0].detail === "shrug · Snippets")
            check("its title is the snippet text, which is what Enter copies",
                  rows[0].name !== "" && rows[0].name !== "shrug")

            const tiles = root.tileHost.tiles
            check("the shipped tile reached the grid", tiles.length === 1)
            check("it is off, and costs nothing, until a user clicks it",
                  tiles[0].on === false && tiles[0].sublabel === "")
            check("it carries the plugin's label", tiles[0].label === "Pomodoro")
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
