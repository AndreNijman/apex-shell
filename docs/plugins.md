# APEX Shell plugins

Roadmap §16. A plugin is a directory with a manifest and one QML file:

```
~/.config/apex-shell/plugins/<id>/plugin.json
~/.config/apex-shell/plugins/<id>/<Entry>.qml
```

The shell finds them once at startup, validates each one, and mounts the ones
it grants. `plugins/apex-worldclock/` in this repo is a working example and is
meant to be read.

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
| `extensionPoint` | yes | `"bar-widget"` is the only one in apiVersion 1. |
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

## The widget contract

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

## Versioning and compatibility policy

`apiVersion` is `"MAJOR.MINOR"`. The host implements `1.0`.

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

## Crash isolation

Each plugin sits in its own `Loader`, loaded asynchronously. A plugin whose QML
fails to parse, names a missing type, or throws while its bindings are set up
puts that Loader into `Loader.Error`: the bar keeps running, the other plugins
keep running, and the failure is recorded against that plugin.

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
| `node tests/plugin-manifest-test.js` | headless, every push | Manifest validation, the apiVersion policy, the source scan, the network and files gates. |
| `./tests/check-plugin-platform.sh` | headless, every push | That the decisions are wired to something, and that the shipped example obeys its own rules. |
| `./tests/run-plugin-host-test.sh` | needs Wayland | Discovery on a real filesystem, and crash isolation in a real Loader. |

The third one skips on CI because no runner has a compositor, which is exactly
why the first two carry the security-relevant assertions. A suite that skips
proves nothing.
