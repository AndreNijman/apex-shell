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
    # used to be listed here, each with its own private detection, and the
    # coverage section below is what noticed that neither had a labwc branch.
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

# ── Every compositor has a branch in every dispatching script ────────────────
# The allowlist above only ever proved that a file STILL SPAWNS hyprctl. It
# could not see, and did not see, that PowerControl.sh's logout had no labwc
# branch at all, that its desktopmode passed a hardcoded `hyprland`, or that
# DpmsControl.sh fell out of its if/elif into `exit 0` on labwc. Three functions
# were dead on a session APEX ships and every assertion in this file passed.
#
# So this section asks the opposite question, by NAME and never by count: for
# each compositor APEX ships, does each dispatching script resolve a real,
# distinct command?
#
# It drives the scripts' own entry points rather than the resolver functions
# they call. Testing the resolver would reproduce the original hole one level
# down — apex_dpms_command could cover labwc perfectly while DpmsControl.sh
# still failed to call it.
COMPOSITORS=(hyprland niri labwc)

# Two words per compositor: the command names only that compositor's answer may
# contain. A branch that silently falls through to another compositor's tooling
# is the exact failure being guarded, and it is invisible to "is the output
# non-empty".
tools_of() {
    case "$1" in
        hyprland) printf '%s\n' hyprctl hyprland ;;
        niri)     printf '%s\n' niri ;;
        labwc)    printf '%s\n' labwc wlopm ;;
    esac
}

# script<TAB>verb pairs. Each must resolve differently on each compositor.
#
# Not listed, with reasons, because a silent omission is what the next audit
# finds:
#   src/scripts/screenshot.sh — covers labwc and niri through a generic
#     grim/slurp path that deliberately does NOT name them (grim speaks
#     wlr-screencopy, which all three implement). Demanding a named branch would
#     mean writing three identical ones.
#   src/scripts/GfxSwitch.sh — envycontrol; nothing about it is compositor-
#     dependent.
#   PowerControl.sh shutdown/reboot/suspend/lock/windows — systemctl, sudo and
#     the shell's own IPC. Same command on every compositor by design.
DISPATCH=(
    "src/scripts/DpmsControl.sh	off"
    "src/scripts/DpmsControl.sh	on"
    "src/scripts/PowerControl.sh	logout"
    "src/scripts/PowerControl.sh	desktopmode"
)

# ── The fixture ──────────────────────────────────────────────────────────────
# Two things make it safe to run a logout script on the developer's desktop.
#
# 1. APEX_COMPOSITOR_DRY_RUN makes apex_run print its argv and return instead of
#    exec'ing, and this file asserts below that no `exec` survives outside
#    apex_run — so "the dry run cannot act" is checked, not promised.
# 2. PATH is replaced with a directory holding only dirname/tr/mkdir. Even if
#    (1) were broken, apex_run's own `command -v` guard would find no hyprctl,
#    no labwc, no niri, no sudo and no loginctl, and return 127 before exec.
fix="$(mktemp -d)"
trap 'rm -rf "$fix"' EXIT
mkdir -p "$fix/bin" "$fix/wayland-sessions"
for u in dirname tr mkdir; do
    p="$(command -v "$u" 2>/dev/null)" && ln -sf "$p" "$fix/bin/$u"
done
# The session ids apex-session-select would validate against, so desktopmode has
# something installed to choose. apex-labwc, not labwc: that is the name APEX
# ships, and picking the wrong one is the bug this pair of names exists to catch.
for s in hyprland niri apex-labwc apex-gaming; do
    printf '[Desktop Entry]\nName=%s\n' "$s" > "$fix/wayland-sessions/$s.desktop"
done
printf '#!/bin/sh\nexit 0\n' > "$fix/apex-session-select"
chmod +x "$fix/apex-session-select"

# resolve <scripts-root> <script> <verb> <compositor> — the command that script
# would run. Empty when it resolves nothing, which is what a missing branch does.
resolve() {
    env -i \
        PATH="$fix/bin" \
        APEX_COMPOSITOR="$4" \
        APEX_COMPOSITOR_DRY_RUN=1 \
        APEX_SESSION_LOGOUT="$fix/absent-session-logout" \
        APEX_SESSION_HELPER="$fix/apex-session-select" \
        APEX_SESSION_DIR="$fix/wayland-sessions" \
        APEX_DESKTOP_SESSION_STATE="$fix/absent-desktop-session" \
        "$BASH" "$1/$2" "$3" 2>/dev/null
}
# By absolute path: `env -i` resolves the program it runs against the PATH it
# just set, and that PATH deliberately holds nothing but dirname, tr and mkdir.

# covers <scripts-root> <script> <verb> — quiet; 0 only when every compositor in
# COMPOSITORS resolves a non-empty command, no two resolve the same one, and no
# command names a compositor other than its own.
covers() {
    local sroot="$1" script="$2" verb="$3"
    local c out seen="" t others=""
    for c in "${COMPOSITORS[@]}"; do
        out="$(resolve "$sroot" "$script" "$verb" "$c")"
        [ -n "$out" ] || return 1
        case "$seen" in *"[$out]"*) return 1 ;; esac
        seen="${seen}[$out]"
        others=""
        for t in "${COMPOSITORS[@]}"; do
            [ "$t" = "$c" ] && continue
            others="$others $(tools_of "$t")"
        done
        for t in $others; do
            # Herestring, not `printf | grep -q`: under `set -o pipefail` a
            # producer killed by grep's early exit turns the verdict upside
            # down, and this file runs with pipefail on.
            grep -qw -- "$t" <<< "$out" && return 1
        done
    done
    return 0
}

for d in "${DISPATCH[@]}"; do
    script="${d%%	*}"; verb="${d##*	}"
    if covers "$root" "$script" "$verb"; then
        ok "$script $verb resolves a distinct command on ${COMPOSITORS[*]}"
    else
        bad "$script $verb does not cover ${COMPOSITORS[*]}"
        for c in "${COMPOSITORS[@]}"; do
            echo "          $c -> $(resolve "$root" "$script" "$verb" "$c")"
        done
    fi
done

# ── The dry run is only safe while apex_run is the only exec ─────────────────
# One `exec` in compositor.sh (inside apex_run) and none anywhere else. A new
# `exec sudo …` in PowerControl.sh would be invisible to the coverage probe and
# would make running this check on a live desktop destructive.
execs_in() {
    grep -nE '(^|["'"'"'`;|&(]|then |else |do )[[:space:]]*exec[[:space:]]' "$root/$1" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*#'
}
for f in src/scripts/PowerControl.sh src/scripts/DpmsControl.sh; do
    hits="$(execs_in "$f")"
    if [ -z "$hits" ]; then
        ok "$f execs nothing outside apex_run"
    else
        bad "$f execs outside apex_run"
        echo "$hits" | sed 's/^/          /'
    fi
done
adapter_execs="$(execs_in src/scripts/compositor.sh)"
want "compositor.sh keeps exactly one exec (apex_run's)" \
    test "$(grep -c . <<< "$adapter_execs")" -eq 1

# ── Prose cannot satisfy any of the above ────────────────────────────────────
# Five checks in this repo have been satisfied by a file's own comments. So:
# delete labwc's real DPMS branch, leave behind a comment that names labwc,
# wlopm and --off, and require the coverage check to FAIL anyway.
mut="$fix/mutant"
mkdir -p "$mut/src"
cp -r "$root/src/scripts" "$mut/src/scripts"
grep -v '^ *labwc:o' "$root/src/scripts/compositor.sh" > "$mut/src/scripts/compositor.sh"
cat >> "$mut/src/scripts/compositor.sh" <<'MUTANT'
# labwc: wlopm --off '*' / wlopm --on '*', which speaks
# zwlr-output-power-management-v1. Everything a grep could want, and no code.
MUTANT
mutant_lost_labwc() { ! covers "$mut" src/scripts/DpmsControl.sh off; }
want "a labwc branch replaced by a comment about labwc still fails" mutant_lost_labwc

# ...and the mutant must fail for the RIGHT reason: the harness itself has to
# still pass on the unmutated copy, or the assertion above would hold even if
# `covers` were broken outright.
mutant_control() { covers "$mut" src/scripts/PowerControl.sh logout; }
want "the same harness still passes on the copy's untouched script" mutant_control

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
