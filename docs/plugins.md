# Rime Shell plugins

Roadmap §16. A plugin is a directory with a manifest and one QML file:

```
~/.config/rime-shell/plugins/<id>/plugin.json
~/.config/rime-shell/plugins/<id>/<Entry>.qml
```

The shell finds them once at startup, validates each one, and mounts the ones it
grants. This repo ships one working example per extension point, and all three
are written to be read:

| Example | Point | Permissions | What it does |
|---|---|---|---|
| `plugins/rime-worldclock/` | `bar-widget` | `files` | A second timezone in the bar. |
| `plugins/rime-snippets/` | `launcher-provider` | `files` | Text snippets in the launcher; Enter copies one. |
| `plugins/rime-pomodoro/` | `quick-settings-tile` | none | A 25-minute focus timer as a tile. |

## What the permission model guarantees

QML plugins run **in-process** in the shell's own QML engine. There is no
sandbox, no separate address space and no syscall filter, so the guarantee is
narrower than "plugins are confined". Stated precisely:

* A plugin that did not declare `network` **cannot make a network call through
  the API**. `api.net.get()` refuses before it spawns anything, and the host,
  not the plugin, builds the argv and runs curl.
* A plugin is **refused at load** if its source reaches for raw engine power
  instead of the API: any import outside a small allowlist, `XMLHttpRequest`,
  dynamic QML construction, `eval`, `Loader`, `parent.parent` walking.
* **It is not a sandbox.** A plugin written specifically to defeat a textual
  scan runs with the shell's full authority.

The one-line version: *the permission model gates the API, and the scan defends
the API's monopoly. Neither one confines hostile code.* Real isolation needs an
out-of-process plugin runtime, which apiVersion 1 does not have. Install
plugins you would be willing to run as yourself, because that is what you are
doing.

## plugin.json

```json
{
  "id": "rime-worldclock",
  "name": "World Clock",
  "description": "A second timezone in the bar.",
  "version": "1.0.0",
  "apiVersion": "1.0",
  "entry": "Widget.qml",
  "extensionPoint": "bar-widget",
  "permissions": ["files"]
}
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | `[a-z0-9][a-z0-9-]*`, and must equal the directory name. |
| `name` | yes | Shown to a human. Max 64 chars, no control characters. |
| `version` | yes | The plugin's own version. Shape-checked only. |
| `apiVersion` | yes | `"MAJOR.MINOR"`. See the policy below. |
| `entry` | yes | A bare filename ending `.qml`. No path, no subdirectory. |
| `extensionPoint` | yes | One of `bar-widget`, `launcher-provider`, `quick-settings-tile`. |
| `permissions` | no | Array from the closed set below. Absent means none. |
| `network` | no | Hostnames the plugin may reach. Required with `network`. |

## Permissions

The vocabulary is the roadmap's: filesystem, network, location, system controls
and secrets. Only two are **implemented** in apiVersion 1. The shell refuses a
plugin that declares any of the other three at load, instead of accepting it and
silently granting nothing. A permission field that grants nothing still reads,
to you and to whoever reviews what a plugin asked for, as a capability someone
considered and approved.

| Permission | Status | What it grants |
|---|---|---|
| `network` | implemented | HTTPS GET to the hosts named in `network`, performed by the host. |
| `files` | implemented | Read-only access inside the plugin's own directory. |
| `system` | **not implemented** | Refused. See below. |
| `secrets` | **not implemented** | Refused: there is no secret store to broker. |
| `location` | **not implemented** | Refused: there is no geolocation source, and no precision control to offer one. |

A "system controls" permission meaning *run a command* would bypass the whole
model: a plugin that can spawn a process can fetch anything and read any file,
which makes `network` and `files` decorative in turn. **No permission may grant
a capability that subsumes the others.** `system` stays refused until there is
an enumerable set of system *actions* to expose (set brightness, switch a
profile) instead of a general escape hatch.

### network

`network` alone grants nothing; the plugin must name its hosts, matching the
roadmap's own examples ("Network: github.com").

```json
"permissions": ["network"],
"network": ["api.open-meteo.com"]
```

Matching is exact, lowercased, and against the **parsed host**: never a suffix
and never the whole URL string. `https://api.github.com.evil.com/` does not
match `api.github.com`. HTTPS only, port 443 only, no credentials in the URL,
and the host **follows no redirects** (an approved host that could redirect
anywhere would make the allowlist decorative).

```qml
api.net.get("https://api.open-meteo.com/v1/forecast?…", function (ok, body, err) {
    if (!ok) return          // refused, or the request failed
    const data = JSON.parse(body)
})
```

### files

Read-only, inside the plugin's own directory, and nothing else.

```qml
api.files.readText("config.json", function (ok, text, err) { … })
```

*Own directory only*, because "read any file the shell can read" is the version
that would be both useful and dangerous, and there is no UI here for scoping it.
*Read-only*, because the plugin directory holds the plugin's own source: a
plugin that could write there would pass the load-time scan and then rewrite its
entry `.qml` for the next start, which is time-of-check/time-of-use against the
only check there is.

**A plugin directory may contain no symlinks, at any depth.** One symlink and
the shell refuses the plugin. That rule makes "own directory" true on disk and
not only in the path text: the path rules reject `..`, absolute paths and
dot-components, and none of that resolves links. A plugin shipping `data` as a
symlink to `$HOME` would turn `readText("data/Documents/tax.pdf")` into a read
of your documents while containing nothing any string check could object to.
Only the filesystem knows, so discovery catches it.

## What a plugin may contain

One `.qml` file. Imports limited to `QtQuick`, `QtQuick.Layouts`,
`QtQuick.Shapes` and `QtQuick.Effects`. None of: relative imports, `Loader`,
`eval`, `new Function`, `XMLHttpRequest`, `Qt.createQmlObject`,
`Qt.createComponent`, `Qt.openUrlExternally`, `Qt.quit`, or `parent.parent`.

The single-file rule is a security rule. Once a plugin can pull in a second
file, the scan would have to prove it has seen everything that can ever execute
(through relative imports, through `Loader { source: }`, through a computed
string), and no textual scan can prove that. One file makes "what the scan saw"
and "what can run" the same set by construction.

A side effect: because the scan refuses relative imports, the shell's own
singletons are not in a plugin's scope at all. `Theme`, `CompositorService` and
the rest are reachable only through `import "../../"`, which no plugin may
write. A plugin gets what the host hands it and has no name for anything else.

**Prose mentioning a forbidden construct must be on its own `//` comment line.**
The scan strips whole comment lines before looking, so a plugin can document
what it does not do. It does not strip trailing comments or `/* block */`
comments, and a forbidden word in one refuses the plugin. Stripping from any
`//` to end of line would be a bypass: a `//` inside a string literal would
swallow whatever followed it on that line.

## Extension points

§16 names nine, and three exist. A name goes on `EXTENSION_POINTS` only once a
host mounts it, an example plugin uses it, and both halves of the suite assert
it. A name with no host behind it is a plugin that loads, is granted, and is
then mounted by nothing, which its author cannot tell apart from a bug in their
own code.

| Point | Since | The plugin… | The shell… |
|---|---|---|---|
| `bar-widget` | 1.0 | paints a rectangle in the bar. | gives it space and clamps its width. |
| `launcher-provider` | 1.1 | answers a query with rows. | draws the rows in the launcher. |
| `quick-settings-tile` | 1.1 | holds a state. | draws the tile. |

Understand that split before you write either of the new two. A `bar-widget`
plugin **owns its pixels**: whatever it draws is visibly a third-party widget in
a third-party widget's slot. The other two are **data** points: the plugin hands
back strings and the shell renders them in its own chrome, where nobody can tell
them from something the shell produced.

A provider row and a tile are therefore *less* capable (neither can paint, cover
anything, animate, or choose its own size) and *more* checked. Every string
crossing that boundary goes through `launcherResults()` or `quickTile()` in
`src/services/plugins/manifest.js`, and neither one passes the plugin's object
through: both build a **fresh object out of an allowlist of keys**, because
`AppLauncher.activate()` dispatches on fields it finds on a row (`entry` runs a
DesktopEntry, `exec` goes to `bash -c`), and a row that carried either would be
arbitrary command execution granted to a plugin that declared no permissions at
all. An allowlist cannot fall behind a launcher that learns a new row shape; a
delete-list can.

### The points that do not exist, and why

`panel`, `theme`, `background-service` and the project/agent integrations are
not built: they raise no permission problem and have no host yet.

**`notification-handler` is missing for a permission reason.** A plugin that
handles notifications reads their summary and body: 2FA codes, message previews,
password-reset links, the most sensitive text stream the shell touches. That
capability maps to **nothing** in the closed permission vocabulary. `secrets` is
the nearest in spirit, and it means a broker holding credentials the plugin
never sees, the opposite arrangement. Shipping the point means either inventing
a sixth permission, or handing over the shell's most sensitive stream with no
declaration at all. The second is worse, because a user reviewing what a plugin
asked for would see nothing. It stays unbuilt until the vocabulary has a word
for what it needs.

The asymmetry decides what a later version can do: *emitting* a notification is
a much smaller capability than reading them, and a later version could add it
under a name of its own. §16 names a handler, which is the reading direction.

## The bar-widget contract

A `bar-widget` plugin's root item declares one property, which the host assigns
once before the widget is on screen:

```qml
import QtQuick

Item {
    property var api: null

    implicitWidth:  row.implicitWidth
    implicitHeight: row.implicitHeight
    …
}
```

`api` is null until assigned, so bind defensively: a widget that renders blank
in that window looks broken, not pending. The object carries:

| Member | What it is |
|---|---|
| `api.apiVersion` | The version the host implements. |
| `api.id` | This plugin's id. |
| `api.theme` | `background`, `foreground`, `subtext`, `accent`, `icon`, `border`, `fontSize`, `smallFont`, `spacing`, `radius`. |
| `api.permissions` | What was granted, as an array. |
| `api.has(name)` | Whether a permission was granted. |
| `api.net.get(url, cb)` | Needs `network`. |
| `api.files.readText(name, cb)` | Needs `files`. |

`api.theme` is the surface that has to stay stable across apiVersion 1.x:
adding a key is a minor bump, removing or renaming one is a major bump.

The host clamps widget width. The right notch has a width budget shared with the
network, volume and battery icons, the clock and the notification bell, and a
plugin reporting an `implicitWidth` of ten thousand would push all of them off
screen.

## The launcher-provider contract

```qml
import QtQuick

Item {
    property var    api:     null    // assigned once by the host
    property string query:   ""      // WRITTEN by the host, debounced
    property var    results: []      // READ by the host
    function activate(index) { }     // optional; called on Enter
}
```

A provider never paints: its root item loads into an invisible host, so bindings
and timers run and nothing it contains can render. `visible` therefore means
nothing to a provider; `query` drives it.

A row is `{ title, subtitle, icon }`, and the host drops every other key.

| Field | Notes |
|---|---|
| `title` | Required. **Also the payload**: activating a row copies the title. |
| `subtitle` | Optional second line. The host appends `· <your plugin's name>`. |
| `icon` | An XDG icon **name**. Never a path; see below. |

**The title is the payload.** The contract has no separate value field on
purpose: a hidden payload would let a plugin display *"email signature"* and
copy something else, with the user's own Enter key as the gesture. A snippet's
row therefore shows the snippet text and puts the label underneath, and you copy
the thing you were looking at.

**The second line always ends in your plugin's name, as the host granted it.**
You cannot suppress or forge that part, so a row always says where it came from
and a plugin cannot claim to be the shell.

**`icon` is a name, not a path.** The launcher's delegate turns a leading `/`
into `file://` + the value and hands it to an `Image`, so a plugin-supplied path
would have the shell attempt to decode an arbitrary file as an image, and
`Image.status` coming back Ready or Error is a file-existence oracle over the
whole filesystem, for a plugin holding no `files` permission. Anything with a
slash, a scheme or a leading dash becomes `""`.

The host consults a provider:

* Never on an empty search box, never on a single character, and **never on a
  `?` answer query**: that mode belongs to the calculator and Wolfram|Alpha.
* Debounced by 120 ms, because a provider is third-party code on the keystroke
  path.
* At most **five rows per provider**, appended *after* the app results. A
  provider adds to the list and cannot reorder it.

### What the shell's own providers have that you do not

§15 turned the launcher into a command surface: apps, files, settings, windows,
clipboard, calculator, commands, projects, agents, SSH hosts and package search
are eleven **built-in** providers, and they use the contract above (`api`,
`query`, `results`, `activate(index)`) with no privileged side channel.
`tests/check-unified-search.sh` asserts each of them declares exactly those
members and that none of them so much as names `Process`, `Quickshell.Io`,
`FileView` or `Socket`.

They have one field that plugin rows do not:

| | plugin row | built-in row |
|---|---|---|
| `title` / `subtitle` / `icon` | yes | yes |
| what Enter does | copies the title | may name an `action` |

`action` is an id in a closed table the *host* owns (`ACTIONS` in
`src/services/search.js`). The table, not the row, owns the argv, the privilege
it needs, the preview text and whether the action is safe, changes the system,
or cannot be undone. A row names an action; it cannot invent one, alter one, or
pass anything but one capped string as its argument. The sanitiser drops the
field from any row that did not come from a built-in descriptor, so a plugin row
carrying one loses it without an error.

**Plugins do not get it yet.** A provider that could name an arbitrary command
would hold the `system` permission, and this shell refuses that at load for a
reason that has not changed: *no permission may grant a capability that subsumes
the others*. A plugin that can spawn a process can curl anything and read any
file, which would make `network` and `files` decorative.

**How plugins could get it.** The refusal note in `manifest.js` says `system`
stays unimplemented "until there is a specific, enumerable set of system ACTIONS
to expose rather than a general escape hatch". `ACTIONS` is now that set, so
handing it to plugins is a *permission* question: a later `apiVersion` can
implement an `actions` permission over the same host-owned table, scoped to the
classes it is willing to grant, starting with the `safe` ones. Nothing in the
row shape, the sanitiser or the hosts would need to change. The design must keep
out one thing: a provider that supplies the command.

**Every action shows itself before it runs.** Enter does not run a row whose
action changes the system: it opens a preview naming what will happen, what
privilege it needs, whether it can be undone, and the exact argv. Committing
needs a second, different gesture (Ctrl+Enter, or the preview's own Run
control), and the rule refuses any commit where the open preview is not the
preview for the row under the selection. That applies to built-in rows; a plugin
row copies its title and is `safe` by construction.

## The quick-settings-tile contract

```qml
import QtQuick

Item {
    property var    api:      null   // assigned once by the host
    property bool   on:       false  // READ by the host
    property string icon:     ""     // a glyph
    property string label:    ""     // falls back to your plugin's name
    property string sublabel: ""     // optional second line
    function toggle() { }            // called when the tile is clicked
}
```

This is the tightest of the three points: you hand back four values and the
shell draws **its own tile** around them, with the same component (`TglBtn`) the
Wi-Fi and Bluetooth toggles use. A plugin tile therefore cannot cover the grid,
animate, change size, or draw something that looks like the Airplane Mode
switch. Users change their machine's state in the quick-settings grid, which
makes it the worst surface in the shell on which to let third-party code paint
arbitrary pixels.

Plugin tiles are always **last** in the grid, so a plugin appearing cannot move
Wi-Fi.

The host compares `on` with `=== true` and does not coerce it:
`Boolean("false")` is `true`, and truthiness is the wrong tool for the value
that decides what the tile tells a user about their own machine.

**A plugin tile cannot flip a system switch.** Wi-Fi, Bluetooth, brightness and
power profiles are all commands, and *run a command* is the `system` permission,
which is **not implemented** and refused at load. This point lets a plugin add a
tile, which is less than adding a quick setting: the tile surfaces information
the plugin has, and acting on a click means acting inside whatever the plugin
was granted. `plugins/rime-pomodoro` holds no permissions at all on purpose: if
the round trip works with nothing granted, nothing about it hides behind a
permission.

## Versioning and compatibility policy

`apiVersion` is `"MAJOR.MINOR"`. The host implements `1.1`.

* **MAJOR must match exactly.** A major bump means the API changed shape and old
  plugins cannot be carried forward, so the host refuses them loudly instead of
  loading them into an API that no longer means what they expect.
* **MINOR must be ≤ the host's.** Minor bumps are additive, so a plugin written
  against 1.0 runs on a 1.3 host. The host refuses the reverse: a 1.3 plugin on
  a 1.0 host wants API that does not exist, and letting it load turns into an
  undefined property deep inside third-party code, which presents as "the shell
  is broken".

Refusing forward-dated plugins is the main reason the field exists: a check that
only caught major bumps would let the common case through.

`1.0` → `1.1` applied that policy: it added two extension points and removed or
renamed nothing. `rime-worldclock` still declares `1.0` and is still granted. A
plugin that needs one of the new points should declare `1.1`, so an older host
refuses it with *"built for a different plugin API"* rather than *"unknown
extension point"*. The second message tells an author their manifest is wrong;
the first tells them what happened: their shell is older than their plugin.

## Crash isolation

Each plugin sits in its own `Loader`, loaded asynchronously, at every extension
point. A plugin whose QML fails to parse, names a missing type, or throws while
its bindings are set up puts that Loader into `Loader.Error`: the bar keeps
running, the other plugins keep running, and the shell records the failure
against that plugin.

The two data points get a second layer: the sanitisers return an empty array or
`null` for anything they cannot use, and never throw. A provider that hands back
garbage while you are typing loses its rows instead of breaking the launcher's
search, and a tile plugin whose properties are nonsense loses its tile instead
of breaking the grid that holds the Wi-Fi and Airplane Mode toggles.

Crash isolation does **not** survive a plugin that hard-crashes the process (an
infinite loop in a binding, a real segfault down in Qt): that takes the shell
with it, because the plugin runs in the shell's process. The permission model
stops at the same boundary for the same reason.

## Refusals

Refusals are machine-readable reason codes, logged with the plugin id.
`describeRefusal()` in `src/services/plugins/manifest.js` turns each into a
line for a human; that file is also the complete list.

## Tests

| Suite | Runs where | Covers |
|---|---|---|
| `node tests/plugin-manifest-test.js` | headless, in CI | Manifest validation, the apiVersion policy, the source scan, the network and files gates, and the row/tile allowlists. |
| `./tests/check-plugin-platform.sh` | headless, in CI | That the decisions are wired to something, that every extension point has exactly one host, and that the shipped examples obey their own rules. |
| `./tests/run-plugin-host-test.sh` | needs Wayland | Discovery on a real filesystem, crash isolation in a real Loader, and each point mounting through its real host. |

The third one skips on CI because no runner has a compositor, which is why the
first two carry the security-relevant assertions: a suite that skips proves
nothing.

