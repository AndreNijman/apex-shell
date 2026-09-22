# APEX Shell plugins

Roadmap §16. A plugin is a directory with a manifest and one QML file:

```
~/.config/apex-shell/plugins/<id>/plugin.json
~/.config/apex-shell/plugins/<id>/<Entry>.qml
```

The shell finds them once at startup, validates each one, and mounts the ones
it grants. There is one working example per extension point in this repo, and
all three are meant to be read:

| Example | Point | Permissions | What it does |
|---|---|---|---|
| `plugins/apex-worldclock/` | `bar-widget` | `files` | A second timezone in the bar. |
| `plugins/apex-snippets/` | `launcher-provider` | `files` | Text snippets in the launcher; Enter copies one. |
| `plugins/apex-pomodoro/` | `quick-settings-tile` | none | A 25-minute focus timer as a tile. |

## What the permission model actually guarantees

Read this before you believe anything else here.

QML plugins run **in-process** in the shell's own QML engine. There is no
sandbox, no separate address space, no syscall filter. So the guarantee is
narrower than "plugins are confined", and stating it precisely is the point:

* A plugin that did not declare `network` **cannot make a network call through
  the API**. `api.net.get()` refuses before anything is spawned, and the host —
  not the plugin — builds the argv and runs curl.
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
  "id": "apex-worldclock",
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
and secrets. Only two are **implemented** in apiVersion 1. Declaring any of the
other three is refused at load, rather than accepted and silently granting
nothing — a permission field that grants nothing still reads, to you and to
whoever reviews what a plugin asked for, as a capability that was considered
and approved.

| Permission | Status | What it grants |
|---|---|---|
| `network` | implemented | HTTPS GET to the hosts named in `network`, performed by the host. |
| `files` | implemented | Read-only access inside the plugin's own directory. |
| `system` | **not implemented** | Refused. See below. |
| `secrets` | **not implemented** | Refused — there is no secret store to broker. |
| `location` | **not implemented** | Refused — there is no geolocation source, and no precision control to offer one. |

`system` is the interesting refusal. A "system controls" permission meaning
*run a command* is not a permission at all — it is a bypass of the whole model,
because a plugin that can spawn a process can fetch anything and read any file,
which makes `network` and `files` decorative in turn. **No permission may grant
a capability that subsumes the others.** It stays refused until there is an
enumerable set of system *actions* to expose (set brightness, switch a profile)
instead of a general escape hatch.

### network

`network` alone grants nothing; the plugin must name its hosts, matching the
roadmap's own examples ("Network: github.com").

```json
"permissions": ["network"],
"network": ["api.open-meteo.com"]
```

Matching is exact, lowercased, and against the **parsed host** — never a suffix
and never the whole URL string. `https://api.github.com.evil.com/` does not
match `api.github.com`. HTTPS only, port 443 only, no credentials in the URL,
and **redirects are not followed** (an approved host that could redirect
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

Two limits worth understanding. *Own directory only*, because "read any file
the shell can read" is the version that would be genuinely useful and genuinely
dangerous, and there is no UI here for scoping it. *Read-only*, because the
plugin directory holds the plugin's own source — a plugin that could write
there would pass the load-time scan and then rewrite its entry `.qml` for the
next start, which is time-of-check/time-of-use against the only check there is.

**A plugin directory may contain no symlinks, at any depth.** One present and
the plugin is refused. This is what makes "own directory" true rather than
merely textual: the path rules reject `..`, absolute paths and dot-components,
and none of that resolves links. A plugin shipping `data` as a symlink to
`$HOME` would turn `readText("data/Documents/tax.pdf")` into a read of your
documents while containing nothing any string check could object to. Only the
filesystem knows, so discovery is where it is caught.

## What a plugin may contain

One `.qml` file. Imports limited to `QtQuick`, `QtQuick.Layouts`,
`QtQuick.Shapes` and `QtQuick.Effects`. None of: relative imports, `Loader`,
`eval`, `new Function`, `XMLHttpRequest`, `Qt.createQmlObject`,
`Qt.createComponent`, `Qt.openUrlExternally`, `Qt.quit`, or `parent.parent`.

Single-file is not a style preference. The moment a plugin can pull in a second
file, the scan would have to prove it has seen everything that can ever execute
— through relative imports, through `Loader { source: }`, through a computed
string — and that proof is not available textually. One file makes "what the
scan saw" and "what can run" the same set by construction.

A useful side effect: because relative imports are refused, the shell's own
singletons are not in a plugin's scope at all. `Theme`, `CompositorService` and
the rest are reachable only through `import "../../"`, which no plugin may
write. A plugin gets what the host hands it and has no name for anything else.

**Prose mentioning a forbidden construct must be on its own `//` comment
line.** The scan strips whole comment lines before looking, so a plugin can
document what it does not do — but trailing comments and `/* block */` comments
are not stripped, and a forbidden word in one will refuse the plugin. Stripping
from any `//` to end of line would be a bypass: a `//` inside a string literal
would swallow whatever followed it on that line.

## Extension points

§16 names nine. Three exist. A name is only added to `EXTENSION_POINTS` once a
host mounts it, an example plugin uses it, and both halves of the suite assert
it — a name with no host behind it is a plugin that loads, is granted, and is
then mounted by nothing, which to its author is indistinguishable from a bug in
their own code.

| Point | Since | The plugin… | The shell… |
|---|---|---|---|
| `bar-widget` | 1.0 | paints a rectangle in the bar. | gives it space and clamps its width. |
| `launcher-provider` | 1.1 | answers a query with rows. | draws the rows in the launcher. |
| `quick-settings-tile` | 1.1 | holds a state. | draws the tile. |

That split is the thing to understand before writing either of the new two. A
`bar-widget` plugin **owns its pixels**: whatever it draws is visibly a
third-party widget in a third-party widget's slot. The other two are **data**
points — the plugin hands back strings and the shell renders them in its own
chrome, where they are indistinguishable from something the shell produced.

So a provider row and a tile are strictly *less* capable (neither can paint,
cover anything, animate, or choose its own size) and strictly *more* checked.
Every string crossing that boundary goes through `launcherResults()` or
`quickTile()` in `src/services/plugins/manifest.js`, and neither one passes the
plugin's object through: both build a **fresh object out of an allowlist of
keys**. That is not fastidiousness. `AppLauncher.activate()` dispatches on
fields it finds on a row — `entry` runs a DesktopEntry, `exec` goes to `bash -c`
— so a row that carried either would be arbitrary command execution granted to
a plugin that declared no permissions at all. An allowlist cannot fall behind a
launcher that learns a new row shape; a delete-list can.

### The points that do not exist, and why

`panel`, `theme`, `background-service` and the project/agent integrations are
simply not built. No permission problem, no host yet.

**`notification-handler` is different, and this is the one worth reading.** A
plugin that handles notifications reads their summary and body: 2FA codes,
message previews, password-reset links — the most sensitive text stream the
shell touches. That is a capability, and it maps to **nothing** in the closed
permission vocabulary. `secrets` is the nearest in spirit and is defined as a
broker holding credentials the plugin never sees, which is the opposite
arrangement. So shipping it means either inventing a sixth permission, or
handing over the shell's most sensitive stream with no declaration at all — and
the second is worse, because a user reviewing what a plugin asked for would see
nothing. It stays unbuilt until the vocabulary has a word for what it needs.

Note the asymmetry, because it decides what a later version can do: *emitting* a
notification is a much smaller capability than reading them, and could be added
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

`api` is null until assigned, so bind defensively — a widget that renders blank
in that window looks broken rather than pending. The object carries:

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

Widget width is clamped by the host. The bar's notch has a width budget shared
with the clock, the battery and the tray, and a plugin reporting an
`implicitWidth` of ten thousand would push all of them off screen.

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

A provider never paints — its root item is loaded into an invisible host, so
bindings and timers run and nothing it contains can be rendered. `visible`
therefore means nothing to a provider; it is driven entirely by `query`.

A row is `{ title, subtitle, icon }` and every other key is dropped.

| Field | Notes |
|---|---|
| `title` | Required. **Also the payload** — activating a row copies the title. |
| `subtitle` | Optional second line. The host appends `· <your plugin's name>`. |
| `icon` | An XDG icon **name**. Never a path; see below. |

**The title is the payload.** There is no separate value field, deliberately: a
contract with a hidden payload would let a plugin display *"email signature"*
and copy something else entirely, with the user's own Enter key as the gesture.
So a snippet's row shows the snippet text and puts the label underneath — you
copy the thing you were looking at.

**The second line always ends in your plugin's name, as the host granted it.**
You cannot suppress or forge that part, so a row always says where it came from
and a plugin cannot claim to be the shell.

**`icon` is a name, not a path.** The launcher's delegate turns a leading `/`
into `file://` + the value and hands it to an `Image`, so a plugin-supplied path
would have the shell attempt to decode an arbitrary file as an image — and
`Image.status` coming back Ready or Error is a file-existence oracle over the
whole filesystem, for a plugin holding no `files` permission. Anything with a
slash, a scheme or a leading dash becomes `""`.

When you are asked:

* Never on an empty search box, never on a single character, and **never on a
  `?` answer query** — that mode belongs to the calculator and Wolfram|Alpha.
* Debounced by 120 ms, because a provider is third-party code on the keystroke
  path.
* At most **five rows per provider**, appended *after* the app results. A
  provider adds to the list and cannot reorder it.

### What the shell's own providers have that you do not

§15 turned the launcher into a command surface: apps, files, settings, windows,
clipboard, calculator, commands, projects, agents, SSH hosts and package search
are now eleven **built-in** providers, and they use the contract above —
`api`, `query`, `results`, `activate(index)` — with no privileged side channel.
`tests/check-unified-search.sh` asserts each of them declares exactly those
members and that none of them so much as names `Process`, `Quickshell.Io`,
`FileView` or `Socket`.

They have one field you do not, and it is worth being precise about what it is:

| | plugin row | built-in row |
|---|---|---|
| `title` / `subtitle` / `icon` | yes | yes |
| what Enter does | copies the title | may name an `action` |

`action` is **not a command**. It is an id in a closed table the *host* owns
(`ACTIONS` in `src/services/search.js`), and the table — not the row — owns the
argv, the privilege it needs, the preview text and whether the action is safe,
changes the system, or cannot be undone. A row names an action; it cannot
invent one, alter one, or pass anything but one capped string as its argument.
The sanitiser drops the field from any row that did not come from a built-in
descriptor, so a plugin row carrying one gets silence rather than an error.

**Why you do not get it yet.** A provider that could name an arbitrary command
would hold the `system` permission, and this shell refuses that at load for a
reason that has not changed: *no permission may grant a capability that
subsumes the others*. A plugin that can spawn a process can curl anything and
read any file, which would make `network` and `files` decorative.

**What would have to happen for you to get it.** The refusal note in
`manifest.js` says `system` stays unimplemented "until there is a specific,
enumerable set of system ACTIONS to expose rather than a general escape hatch".
`ACTIONS` is now that set. So handing it to plugins is a *permission* question
and not an architecture one: a later `apiVersion` can implement an `actions`
permission over the same host-owned table, scoped to the classes it is willing
to grant — most obviously the `safe` ones. Nothing in the row shape, the
sanitiser or the hosts would need to change. What must not happen is the thing
this design deliberately avoids: letting a provider supply the command.

**Every action shows itself before it runs.** A row whose action changes the
system is not run by Enter at all — Enter opens a preview naming what will
happen, what privilege it needs, whether it can be undone, and the exact argv.
Committing needs a second, different gesture (Ctrl+Enter, or the preview's own
Run control), and the rule refuses any commit where the open preview is not the
preview for the row under the selection. That applies to built-in rows; a
plugin row copies its title and is `safe` by construction.

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
shell draws **its own tile** around them, with the same component the Wi-Fi and
Bluetooth toggles use. So a plugin tile cannot cover the grid, cannot animate,
cannot be a different size, and cannot draw something that looks like the
Airplane Mode switch. The quick-settings grid is where a user goes to change
their machine's state, and it is the worst surface in the shell on which to let
third-party code paint arbitrary pixels.

Plugin tiles are always **last** in the grid, so a plugin appearing cannot move
Wi-Fi.

`on` is compared with `=== true` and not coerced — `Boolean("false")` is `true`,
and truthiness is the wrong tool for the value that decides what a user is being
told about their own machine.

**A plugin tile cannot flip a system switch.** Not Wi-Fi, not Bluetooth, not
brightness, not a power profile. Every one of those is a command, and *run a
command* is the `system` permission, which is **not implemented** and refused at
load. So the honest description of this point is not "plugins can add quick
settings", it is "plugins can add a tile": it surfaces information the plugin
has, and acting on a click means acting inside whatever the plugin was granted.
`plugins/apex-pomodoro` holds no permissions at all, which is the point — if the
round trip works with nothing granted, nothing about it is hiding behind a
permission.

## Versioning and compatibility policy

`apiVersion` is `"MAJOR.MINOR"`. The host implements `1.1`.

* **MAJOR must match exactly.** A major bump means the API changed shape and
  old plugins cannot be carried forward, so they are refused loudly rather than
  loaded into an API that no longer means what they expect.
* **MINOR must be ≤ the host's.** Minor bumps are additive, so a plugin written
  against 1.0 runs on a 1.3 host. The reverse is refused: a 1.3 plugin on a 1.0
  host wants API that does not exist, and letting it load turns into an
  undefined property deep inside third-party code, which presents as "the shell
  is broken".

Refusing forward-dated plugins is the main reason the field exists — a check
that only caught major bumps would let the common case through.

`1.0` → `1.1` is that policy being used rather than described: two extension
points were added and nothing was removed or renamed. `apex-worldclock` still
declares `1.0` and is still granted. A plugin that needs one of the new points
should declare `1.1`, so an older host refuses it with *"built for a different
plugin API"* rather than *"unknown extension point"* — the second message tells
an author their manifest is wrong, and the first tells them the truth, which is
that their shell is older than their plugin.

## Crash isolation

Each plugin sits in its own `Loader`, loaded asynchronously, at every extension
point. A plugin whose QML fails to parse, names a missing type, or throws while
its bindings are set up puts that Loader into `Loader.Error`: the bar keeps
running, the other plugins keep running, and the failure is recorded against
that plugin.

The two data points get a second layer, which matters more than it sounds: the
sanitisers return an empty array or `null` for anything they cannot use and
never throw. So a provider that hands back garbage while you are typing loses
its rows rather than breaking the launcher's search, and a tile plugin whose
properties are nonsense loses its tile rather than breaking the grid that holds
the Wi-Fi and Airplane Mode toggles.

What this does **not** survive: a plugin that hard-crashes the process — an
infinite loop in a binding, a real segfault down in Qt — takes the shell with
it, because it is running in the shell's process. That is the same boundary as
the permission model, for the same reason.

## Refusals

Refusals are machine-readable reason codes, logged with the plugin id.
`describeRefusal()` in `src/services/plugins/manifest.js` turns each into a
line for a human; that file is also the complete list.

## Tests

| Suite | Runs where | Covers |
|---|---|---|
| `node tests/plugin-manifest-test.js` | headless, every push | Manifest validation, the apiVersion policy, the source scan, the network and files gates, and the row/tile allowlists. |
| `./tests/check-plugin-platform.sh` | headless, every push | That the decisions are wired to something, that every extension point has exactly one host, and that the shipped examples obey their own rules. |
| `./tests/run-plugin-host-test.sh` | needs Wayland | Discovery on a real filesystem, crash isolation in a real Loader, and each point mounting through its real host. |

The third one skips on CI because no runner has a compositor, which is exactly
why the first two carry the security-relevant assertions. A suite that skips
proves nothing.
