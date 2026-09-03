#!/usr/bin/env bash
# Static invariants for the CompositorService adapter layer (roadmap §17).
#
# ── Why this exists next to the behavioural test ─────────────────────────────
# run-compositor-facade-test.sh needs a Wayland session and skips on CI, which
# has none. A suite that skips is a suite that proves nothing, and this repo has
# already shipped assertions that passed because they never ran. Everything here
# is grep-able and runs headless, so the adapter layer has real CI coverage even
# though no runner has a compositor.
#
# It checks the properties a typo would break and a reviewer would not notice:
# that all four backends declare exactly the same capabilities, that the facade
# agrees with them, and that Hyprland's import stays inside Hyprland's backend.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
dir="$root/src/services/compositor"

pass=0
fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }

# want <description> <command...> — runs the command and records the verdict.
# Deliberately not `cmd; check $?`: ShellCheck SC2319 is right that a $? read
# after a `[ ]` is a trap waiting for someone to insert a line between them.
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

BACKENDS=(NullBackend HyprlandBackend NiriBackend LabwcBackend)

# ── The files exist ──────────────────────────────────────────────────────────
for b in "${BACKENDS[@]}"; do
    want "$b.qml exists and is non-empty" test -s "$dir/$b.qml"
done
want "CompositorService.qml exists and is non-empty" test -s "$dir/CompositorService.qml"
want "boxes.js exists and is non-empty"              test -s "$dir/boxes.js"

# ── The facade is reachable ──────────────────────────────────────────────────
want "CompositorService is registered in src/qmldir" \
    grep -q "^singleton CompositorService .*services/compositor/CompositorService.qml" "$root/src/qmldir"

# ── Capability parity ────────────────────────────────────────────────────────
# Every backend must declare the same key set as the facade's _CAPS schema. A
# missing key degrades to false through the facade and a misspelled one is
# invisible, so neither shows up as a bug until somebody logs into that session.
caps_of() {
    # Keys inside the capabilities/_CAPS object literal: `    name: value,`
    sed -n '/capabilities: ({/,/})/p;/_CAPS: ({/,/})/p' "$1" \
        | grep -oE '^\s+[a-zA-Z]+:' \
        | tr -d ' :' \
        | sort -u
}

schema="$(caps_of "$dir/CompositorService.qml")"
want "the facade declares a capability schema" test -n "$schema"

echo "        schema: $(echo "$schema" | tr '\n' ' ')"

for b in "${BACKENDS[@]}"; do
    got="$(caps_of "$dir/$b.qml")"
    if [ "$got" = "$schema" ]; then
        ok "$b declares exactly the schema capabilities"
    else
        bad "$b capability set differs from the schema"
        diff <(echo "$schema") <(echo "$got") | sed 's/^/        /'
    fi
done

# ── The Hyprland import stays in the Hyprland backend ────────────────────────
# This is the point of the whole exercise. Resolving the Quickshell.Hyprland
# singleton is what constructs it, and constructing it off Hyprland logs — which
# is why consumers used to carry `target: isHyprland ? Hyprland : null`. The
# facade loads backends by URL precisely so the import never resolves elsewhere.
want "HyprlandBackend imports Quickshell.Hyprland" \
    grep -q "^import Quickshell.Hyprland" "$dir/HyprlandBackend.qml"

# Anchored at column 0: a QML import is always there, and the facade
# *mentions* the import in a comment explaining why it is not one.
leaked="$(grep -l "^import Quickshell.Hyprland" "$dir"/*.qml 2>/dev/null | grep -v "HyprlandBackend.qml")"
want "no other adapter file imports Quickshell.Hyprland" test -z "$leaked"
[ -n "$leaked" ] && echo "        leaked into: $leaked"

# ── Backends are loaded by URL, never by type name ───────────────────────────
# A bare `HyprlandBackend {}` cannot work: the facade is reached through
# src/qmldir, so this directory is not on the import path. That failure mode
# ("is not a type") has already cost this repo a debugging session.
want "the facade selects its backend by URL" \
    grep -q 'source: root._backendUrl' "$dir/CompositorService.qml"

for b in "${BACKENDS[@]}"; do
    want "$b is reachable from the facade's selection" \
        grep -q "\"$b.qml\"" "$dir/CompositorService.qml"
done

# ── Every backend answers the facade's whole surface ─────────────────────────
# The facade reads these unconditionally; a backend missing one yields undefined,
# which propagates into the UI as a blank rather than an error.
#
# windowsPolled/titlePolled are in here rather than in the capability map on
# purpose. The map answers "what can this compositor do"; these two answer
# "what does it cost", which is a different question with a different consumer
# — the facade test, which cannot otherwise tell a backend that empties its
# window list without a ref from one whose list is live regardless.
SURFACE=(ready capabilities windowsWanted titleWanted workspaces windows
         workspaceSlots specialWorkspaceOpen layoutWanted layoutName
         layoutWindowCount layouts
         focusedTitle focusedAppName focusedOutput focusedWorkspaceId
         windowBoxScript outputBoxScript
         windowsPolled titlePolled
         screenShader nightLightActive
         displayName versionCommand)
METHODS=(focusWorkspace toggleSpecialWorkspace focusWindow closeWindow
         moveWindowToWorkspace toggleOverview setAccentBorder setGaps readGaps
         setLayout
         setKeyboardInterception
         setScreenShader refreshScreenShader setNightLight)

# The facade binds a Connections to `backend.focusMoved`. A backend that does
# not declare it makes that binding silently dead — popups would simply stop
# dismissing on that compositor, with nothing logged.
SIGNALS=(focusMoved)

for b in "${BACKENDS[@]}"; do
    missing=""
    for g in "${SIGNALS[@]}"; do
        grep -qE "^\s*signal $g\(" "$dir/$b.qml" || missing="$missing signal:$g"
    done
    for p in "${SURFACE[@]}"; do
        grep -qE "property .*\b$p\b|property $p" "$dir/$b.qml" || missing="$missing $p"
    done
    for m in "${METHODS[@]}"; do
        grep -qE "function $m\(" "$dir/$b.qml" || missing="$missing $m()"
    done
    if [ -z "$missing" ]; then
        ok "$b implements the full facade surface"
    else
        bad "$b is missing:$missing"
    fi
done

# ── The hyprctl boundary ─────────────────────────────────────────────────────
# 5.2's actual finish line: `hyprctl` is spawned from ONE directory. Everything
# else asks CompositorService, which refuses where the capability is false
# rather than spawning a doomed process — the failure mode that had a shell on
# sway polling `hyprctl -j activeworkspace` every four seconds forever.
#
# This is a boundary and not a ban. Two files outside the adapter still spawn
# it, each for a stated reason, and each is ASSERTED to still need it: an
# allowlist entry that outlives its file's migration silently re-permits
# something already fixed, which is how allowlists rot into decoration.
#
# Matching is command-shaped rather than "contains the word". Half of this
# shell's prose is about what it used to spawn, and the Display page's own
# error text reads "…nor hyprctl is available." — a check that fails on its own
# documentation is a check somebody deletes. So `hyprctl` has to be the FIRST
# WORD of a command: at the start of a line, or right after a quote, a pipe, a
# semicolon, an `&&`, a `(` or an `exec`. Comment lines are dropped too.
HYPRCTL_ALLOWED=(
    # `hyprctl binds -j` (the capture-conflict cache) and `hyprctl reload`.
    # Keybind generation is 5.3, not 5.2, and there is nothing to migrate these
    # onto: `binds` has no analogue anywhere else — labwc's bindings are
    # generated into rc.xml by apex-labwc-keybinds and niri live-reloads its
    # own config — so a capability here would wrap a one-backend feature in a
    # one-backend capability and answer false everywhere it was asked.
    "src/services/config_tab/KeybindService.qml"
    # `hyprctl dispatch exit` and `hyprctl dispatch dpms`. This file IS the
    # compositor adapter for the helper scripts, in the same sense
    # src/services/compositor/ is for QML — PowerControl.sh and DpmsControl.sh
    # used to be listed here, each with its own private detection, and neither
    # had a labwc branch at all.
    "src/scripts/compositor.sh"
)

# grep -E, so this is one alternation and not a backreference.
HYPRCTL_CMD='(^|["'"'"'`;|&(]|exec )[[:space:]]*hyprctl[[:space:]"]'

hyprctl_spawns_in() {
    grep -nE "$HYPRCTL_CMD" "$root/$1" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*(//|#)'
}

# Every shell file that spawns it, adapter and allowlist removed.
#
# src/ plus shell.qml. The entry point lives at the repo root and is as much
# "a file outside src/services/compositor/" as anything under src/ — it is
# clean today, so leaving it out was a hole in the enforcement rather than a
# leak, which is exactly the kind of gap this check exists to close.
#
# Rooting the scan at the repo instead would be worse, not better: it would
# newly match install.sh's `log_info "hyprctl dispatch exit"` and
# dots-extra/install-arch.sh's `["hyprctl", "binds", "-j"]`. Those are
# installers for a Hyprland desktop, not shell code that should be asking an
# adapter, and failing on them would make this check something to work around.
scan_files() {
    find "$root/src" -type f \( -name '*.qml' -o -name '*.sh' -o -name '*.js' \)
    [ -f "$root/shell.qml" ] && printf '%s\n' "$root/shell.qml"
}

leaks=""
while IFS= read -r f; do
    rel="${f#"$root"/}"
    case "$rel" in src/services/compositor/*) continue ;; esac
    allowed=0
    for a in "${HYPRCTL_ALLOWED[@]}"; do
        [ "$rel" = "$a" ] && allowed=1
    done
    [ "$allowed" -eq 1 ] && continue
    [ -n "$(hyprctl_spawns_in "$rel")" ] && leaks="$leaks $rel"
done < <(scan_files)

# The scan must actually reach the entry point. Asserted through the real
# scan_files, not a copy of it: a widening that silently matches nothing is the
# same class of nothing as an allowlist entry that outlived its file.
scan_reaches_shell_qml() { scan_files | grep -qx "$root/shell.qml"; }
want "the hyprctl scan reaches shell.qml" scan_reaches_shell_qml

want "nothing outside the adapter spawns hyprctl" test -z "$leaks"
if [ -n "$leaks" ]; then
    for rel in $leaks; do
        echo "        $rel:"
        hyprctl_spawns_in "$rel" | sed 's/^/          /'
    done
fi

# The allowlist cannot rot: an entry whose file no longer spawns hyprctl has
# been migrated, and leaving it listed re-permits a regression for free.
for a in "${HYPRCTL_ALLOWED[@]}"; do
    if [ ! -f "$root/$a" ]; then
        bad "allowlisted $a does not exist; drop it from HYPRCTL_ALLOWED"
    elif [ -z "$(hyprctl_spawns_in "$a")" ]; then
        bad "allowlisted $a no longer spawns hyprctl; drop it from HYPRCTL_ALLOWED"
    else
        ok "$a is allowlisted and still needs to be"
    fi
done

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
