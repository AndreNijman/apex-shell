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
SURFACE=(ready capabilities windowsWanted titleWanted workspaces windows
         workspaceSlots specialWorkspaceOpen layoutWanted layoutName
         layoutWindowCount layouts
         focusedTitle focusedAppName focusedOutput focusedWorkspaceId
         windowBoxScript outputBoxScript)
METHODS=(focusWorkspace toggleSpecialWorkspace focusWindow closeWindow
         moveWindowToWorkspace toggleOverview setAccentBorder setGaps readGaps
         setLayout
         setKeyboardInterception)

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

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
