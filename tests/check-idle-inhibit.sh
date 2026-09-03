#!/usr/bin/env bash
# Static invariants for Caffeine's idle inhibition.
#
# ── Why this exists, and why it is greps and not a QML suite ─────────────────
# Caffeine has to keep working on every compositor APEX ships. Whether it
# ACTUALLY suppresses idle can only be measured against a live compositor and a
# live idle daemon (tests/measure-idle-inhibit.sh does that, manually, and its
# header records the numbers). No CI runner has either, so a behavioural suite
# here would skip — and a suite that skips proves nothing, which this repo has
# already shipped twice.
#
# What CAN be checked headlessly is the property the measurement established:
# that neither mechanism is conditional on anything except Caffeine itself.
# That is the whole bug this replaced. The logind inhibitor used to be gated
# `root.caffeine && Compositor.isLabwc`, on the belief that the Wayland surface
# inhibitor covered Hyprland — and Hyprland ignores idle inhibitors on
# layer-shell surfaces, which is what a bar is. So Caffeine did nothing at all
# on the primary compositor while the tile lit up.
#
# The failure mode is silent in both directions: nothing logs, nothing throws,
# the tile still toggles, and the screen locks anyway. So the gates are pinned
# EXACTLY, not merely checked for mentioning caffeine — `root.caffeine &&
# CompositorService.can.idleInhibit` would pass a substring test and reintroduce
# precisely the class of bug that motivated this file.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

shellstate="$root/src/state/ShellState.qml"
topbar="$root/src/windows/TopBar.qml"
quick="$root/src/services/home/QuickSettings.qml"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ── The files exist ──────────────────────────────────────────────────────────
for f in "$shellstate" "$topbar" "$quick"; do
    want "${f#"$root"/} exists and is non-empty" test -s "$f"
done

# ── Mechanism 1: the logind `idle` block inhibitor ───────────────────────────
# This is the one that works on every compositor. hypridle consults logind's
# BlockInhibited (measured: held -> no listener fires; released -> they fire),
# and it is not a compositor feature at all, which is why there is no
# capability for it.
want "ShellState holds a logind inhibitor" \
    grep -q 'systemd-inhibit' "$shellstate"
want "the logind inhibitor blocks idle specifically" \
    grep -q -- '--what=idle' "$shellstate"
want "the logind inhibitor is mode=block, not mode=delay" \
    grep -q -- '--mode=block' "$shellstate"

# Both halves of the parent-death guarantee: systemd-inhibit forks its payload,
# so the wrapper AND the payload each need one or a shell crash leaves an
# inhibitor behind and the machine never sleeps again.
pdeathsig_count() { [ "$(grep -c -- '--pdeathsig' "$shellstate")" -ge 2 ]; }
want "both the inhibitor and its payload carry --pdeathsig" pdeathsig_count

# ── The gate, pinned exactly ─────────────────────────────────────────────────
# Extract the `running:` line from inside the caffeineInhibitor Process block
# rather than grepping the whole file, so an unrelated `running:` elsewhere in
# this large singleton cannot satisfy or break the check.
inhibitor_gate() {
    awk '/readonly property Process caffeineInhibitor: Process \{/ {inb=1}
         inb && /^[[:space:]]*running:/ {
             line=$0
             sub(/^[[:space:]]+/, "", line)
             sub(/[[:space:]]+$/, "", line)
             print line
             exit
         }' "$shellstate"
}
gate="$(inhibitor_gate)"
echo "        logind gate: ${gate:-<none found>}"

gate_is_caffeine_only() { [ "$gate" = "running: root.caffeine" ]; }
want "the logind inhibitor is gated on Caffeine ALONE" gate_is_caffeine_only
if ! gate_is_caffeine_only; then
    echo "        expected exactly: running: root.caffeine"
    echo "        a second condition means Caffeine is dead on some session"
fi

# ── Mechanism 2: the Wayland surface inhibitor ───────────────────────────────
# Kept even though Hyprland ignores it on layer surfaces: it is what works on
# labwc, and it is the only route for an idle daemon that never asks logind
# (swayidle). The shell cannot know which daemon a session runs, so it holds
# both and gates neither.
want "the TopBar declares a Wayland IdleInhibitor" \
    grep -qE '^[[:space:]]*IdleInhibitor[[:space:]]*\{' "$topbar"
want "the TopBar imports the Wayland module the inhibitor needs" \
    grep -q '^import Quickshell.Wayland' "$topbar"

topbar_gate() {
    awk '/^[[:space:]]*IdleInhibitor[[:space:]]*\{/ {inb=1}
         inb && /^[[:space:]]*enabled:/ {
             line=$0
             sub(/^[[:space:]]+/, "", line)
             sub(/[[:space:]]+$/, "", line)
             print line
             exit
         }' "$topbar"
}
tgate="$(topbar_gate)"
echo "        wayland gate: ${tgate:-<none found>}"

tgate_is_caffeine_only() { [ "$tgate" = "enabled: ShellState.caffeine" ]; }
want "the Wayland inhibitor is gated on Caffeine ALONE" tgate_is_caffeine_only
if ! tgate_is_caffeine_only; then
    echo "        expected exactly: enabled: ShellState.caffeine"
fi

# ── Neither gate may name a compositor or a capability ───────────────────────
# Belt and braces over the exact-match checks above: those pin today's text,
# this one states the rule, so a reviewer reading a failure learns WHY rather
# than just that a string moved.
no_compositor_in() {
    ! grep -qE 'Compositor\.(is|name)|CompositorService\.(can|name)' <<<"$1"
}
want "the logind gate names no compositor and no capability" \
    no_compositor_in "$gate"
want "the Wayland gate names no compositor and no capability" \
    no_compositor_in "$tgate"

# ── The tile itself cannot disappear ─────────────────────────────────────────
# A capability that hides the Caffeine tile is a regression, not a migration.
# Unlike Filter and Night Light — which genuinely hide on can.screenShader and
# can.nightLight because those mechanisms exist on exactly one compositor —
# Caffeine works everywhere, so its tile is unconditional.
want "the Caffeine tile exists in QuickSettings" \
    grep -q 'label: "Caffeine"' "$quick"

# The tile is one QML line: `on: ...; icon: ...; label: "Caffeine"`. A
# `visible:` on that line is the only way to hide it in place.
caffeine_tile_unconditional() {
    ! grep -E 'label: "Caffeine"' "$quick" | grep -q 'visible:'
}
want "the Caffeine tile is not hidden behind a condition" caffeine_tile_unconditional
if ! caffeine_tile_unconditional; then
    echo "        the tile line carries a visible: gate:"
    grep -nE 'label: "Caffeine"' "$quick" | sed 's/^/          /'
fi

# ── The measurement harness is present and runnable ──────────────────────────
# The numbers in ShellState's comment are only trustworthy while the thing that
# produced them still exists and can be re-run. A comment claiming a
# measurement whose harness has been deleted is worse than no comment.
want "the idle-inhibit measurement harness exists and is executable" \
    test -x "$root/tests/measure-idle-inhibit.sh"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
