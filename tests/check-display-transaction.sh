#!/usr/bin/env bash
# Static invariants for the display apply transaction (P0-018).
#
# ── Why this exists next to the behavioural suite ────────────────────────────
# run-display-transaction-test.sh needs a wlroots session and the installed
# display engine, and skips without them — which is every CI runner. A suite
# that skips is a suite that proves nothing, and this repo has already shipped
# assertions that passed because they never ran.
#
# So the properties that a refactor would quietly undo are checked here, by
# grep, headless: that the confirmation is a window of its own and not a
# section of a page, that shell.qml builds one per output, that the countdown
# has a second owner outside this process, and that a temporary apply cannot
# write the persisted model.
#
# The bug being guarded against is the one that was reported: the user pressed
# Apply, no confirmation appeared, and fifteen seconds later the layout they
# wanted was gone.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

svc="$root/src/services/config_tab/DisplayService.qml"
page="$root/src/services/config_tab/pages/DisplayPage.qml"
win="$root/src/windows/DisplayConfirm.qml"
guard="$root/src/scripts/apex-display-guard.sh"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# Code lines only. Half of this repo's prose is about what it used to do, and a
# check a comment can satisfy is a check that stops being one.
code() { grep -vE '^\s*(//|#)' "$1" 2>/dev/null; }

# ── The files exist ──────────────────────────────────────────────────────────
want "DisplayConfirm.qml exists and is non-empty"      test -s "$win"
want "apex-display-guard.sh exists and is non-empty"   test -s "$guard"
want "apex-display-guard.sh is executable"             test -x "$guard"

# ── The confirmation is a window, on every output ────────────────────────────
#
# This is the bug. The Keep/Revert buttons used to live in a CfgSection inside
# DisplayPage, which is presented in two places and neither survives its own
# apply: the dashboard's Config tab is a popup that PopupDismiss closes on
# CompositorService.focusMoved, which a monitor reconfiguration can raise, and
# the Nexus window is one-per-output, so an apply that disables that output
# destroys it. Both are also scrolled, and Apply is at the bottom of the page
# while the confirmation was at the top.
want "the confirmation is a PanelWindow" \
    grep -qE '^\s*PanelWindow\s*\{' "$win"
want "the confirmation is an overlay layer surface" \
    grep -q "WlrLayershell.layer: WlrLayer.Overlay" "$win"
want "shell.qml builds a DisplayConfirm per output" \
    grep -qE 'DisplayConfirm \{ *screen: modelData' "$root/shell.qml"

# Inside the Variants delegate, which is what "per output" means here. A
# DisplayConfirm moved out to the top level would be a single window on the
# first screen, and this check would still see the line above.
delegate_has_confirm() {
    grep -q "DisplayConfirm" < <(awk '/Variants \{/,/^    \}$/' "$root/shell.qml")
}
want "the DisplayConfirm is inside the per-screen Variants delegate" delegate_has_confirm

# The page may still MENTION the countdown — it is useful to see there — but it
# must not be the only place it can be answered.
want "the Display page no longer owns the only Revert button" \
    test "$(code "$page" | grep -c 'DisplayService.revertApplied()')" -eq 0
want "the confirmation window answers with the service's own verbs" \
    bash -c 'grep -q "DisplayService.confirm()" "$1" && grep -q "DisplayService.revertApplied()" "$1"' _ "$win"

# A user who cannot read the screen has to be told, in words, that waiting is
# safe. That sentence is the whole reason the dialog is not just a spinner.
want "the dialog says what happens if the user does nothing" \
    grep -q "If you do nothing" "$win"
want "the dialog is answerable from the keyboard" \
    bash -c 'grep -q "Keys.onReturnPressed" "$1" && grep -q "Keys.onEscapePressed" "$1"' _ "$win"

# ── A safe active output ─────────────────────────────────────────────────────
# The dialog must not be aimed at an output this very apply is turning off.
want "the service picks the output the dialog is safe on" \
    grep -q "readonly property string confirmScreen" "$svc"
want "the safe output is chosen from the live screen list" \
    bash -c 'grep -q "Quickshell.screens" < <(sed -n "/property string confirmScreen/,/^    }/p" "$1")' _ "$svc"
want "the safe output skips one the pending model disables" \
    bash -c 'grep -q "enabled === false" < <(sed -n "/property string confirmScreen/,/^    }/p" "$1")' _ "$svc"

# The settings window has to come back too, or the user cannot reach the page
# again after an apply rebuilt the screen list.
want "Nexus maps itself when it is born already live" \
    grep -q "Component.onCompleted: if (root.live) root.windowVisible = true" "$root/src/nexus/Nexus.qml"
want "Nexus falls back to a screen that still exists" \
    grep -q "readonly property string effectiveScreen" "$root/src/nexus/NexusState.qml"

# ── The countdown has an owner outside this process ──────────────────────────
#
# Criterion 6. A QML Timer cannot revert a layout for a shell that is no longer
# running, and "the shell crashed while my screen was black" is the failure the
# countdown exists to prevent.
want "the service detaches a guard for the transaction" \
    grep -qE 'bash "\$5" spawn "\$1"' "$svc"
want "the guard detaches itself from the shell's process group" \
    grep -qE '^\s*setsid -f bash "\$0" run "\$dir"' "$guard"
# Through an interpreter, never on the mode bit. The shipped tree is
# /usr/share/apex-shell and nothing in the build asserts +x, while `setsid -f`
# reports success whether or not the child execs — so a lost bit would leave the
# countdown with one owner again and say nothing.
want "neither caller relies on the guard being executable" \
    bash -c '! grep -qE "^\s*setsid -f \"" "$1"' _ "$guard"
want "the guard reverts when the deadline passes with no verdict" \
    bash -c 'grep -q "settle_revert \"\$dir\"" < <(sed -n "/^cmd_run()/,/^}/p" "$1")' _ "$guard"
# Recording `reverted` after a restore that did nothing is worse than recording
# nothing: `reconcile` reads that word at the next shell start, concludes the
# transaction is settled, and the machine keeps a layout nobody confirmed with a
# note saying it was put back. Every path that records the outcome has to be the
# one that knows whether the restore worked.
want "no path records a revert without checking that it happened" \
    bash -c '! grep -nE "^\s+restore \"\\\$dir\"\s*$" "$1"' _ "$guard"
want "a failed restore is recorded as such, not as a revert" \
    bash -c 'grep -q "state revert-failed" < <(sed -n "/^settle_revert()/,/^}/p" "$1")' _ "$guard"
want "a failed restore is retried before it is given up on" \
    bash -c 'grep -q "APEX_DISPLAY_GUARD_RESTORE_TRIES" < <(sed -n "/^settle_revert()/,/^}/p" "$1")' _ "$guard"
want "reconcile treats a failed revert as work still to do" \
    bash -c 'grep -q "revert-failed" < <(sed -n "/^cmd_reconcile()/,/^}/p" "$1")' _ "$guard"
want "the shell tells the user when the previous layout could not be restored" \
    grep -q 'revert-failed' "$svc"
want "the shell settles an abandoned transaction at startup" \
    grep -q '"reconcile", root.txnDir' "$svc"
want "the countdown is derived from a deadline, not decremented" \
    bash -c 'grep -q "_deadline" < <(sed -n "/property var _countdown/,/^    }/p" "$1")' _ "$svc"

# One implementation of "put it back", used by the button, the deadline and the
# startup reconciliation. Two would agree until one of them was edited.
want "the shell reverts through the guard rather than the engine" \
    grep -qE '\["bash", root.guard, "restore", root.txnDir\]' "$svc"
want "the guard falls back when the recorded mode is gone" \
    bash -c 'grep -q "rollback-modeless.json" < <(sed -n "/^restore()/,/^}/p" "$1")' _ "$guard"
# wlr-randr rejects the whole invocation over one unknown output, so a monitor
# unplugged during the countdown makes the revert fail outright and the machine
# keeps the layout nobody confirmed. Reproduced live in
# tests/run-display-unplug-test.sh; this is the static half.
want "the guard falls back when an output in the rollback is gone" \
    bash -c 'grep -q "rollback-present.json" < <(sed -n "/^restore()/,/^}/p" "$1")' _ "$guard"
want "the pruned rollback is built from a fresh enumeration, not the stale one" \
    bash -c 'grep -q "\\\$engine\" list" < <(sed -n "/^restore()/,/^}/p" "$1")' _ "$guard"

# ── A temporary apply is temporary ───────────────────────────────────────────
#
# The apply used to write display.json before the engine had been asked whether
# the layout was even valid, so a mode the panel does not have was rejected on
# screen and applied at the next login.
want "the apply runs the engine against the transaction file" \
    grep -qE 'apply --model "\$1/target.json"' "$svc"
apply_leaves_model_alone() {
    ! grep -q "root.modelPath" < <(sed -n '/function _begin()/,/^    }/p' "$svc")
}
want "the apply never names the persisted model" apply_leaves_model_alone
want "only Keep promotes the tried layout to the persisted model" \
    bash -c 'grep -q "target.json" < <(sed -n "/function confirm()/,/^    }/p" "$1")' _ "$svc"

# ── The engine is asked before it is told (P0-018) ───────────────────────────
#
# The temporary apply must not persist, or a session that dies during the
# countdown comes back on the layout nobody confirmed. That is one flag in the
# engine — but the shell and the OS image land independently, and this shell
# also runs on images that predate it, where argparse answers an unknown flag
# with exit 2. An unconditional flag would turn every temporary apply into a
# failure on those machines, so it is probed for and only then passed.
want "the shell asks the engine whether it takes --no-persist" \
    bash -c 'sed -n "/property var _capabilityProc/,/^    }/p" "$1" | grep -q -- "--help"' _ "$svc"
want "the probe looks for the flag by name" \
    grep -q 'indexOf("--no-persist")' "$svc"
want "the temporary apply passes --no-persist when the engine takes it" \
    bash -c 'sed -n "/function _begin()/,/^    }/p" "$1" | grep -q -- "engineCanSkipPersist ? \"--no-persist\"" ' _ "$svc"
# Unconditional is the failure mode, not the goal: it would break every apply on
# an older image. The flag must never appear in _begin() except behind the probe.
np_is_gated() {
    local n
    n="$(sed -n '/function _begin()/,/^    }/p' "$svc" | grep -c -- '--no-persist')"
    [ "$n" -eq 1 ]
}
want "the flag appears in the apply exactly once, behind the probe" np_is_gated
# P0-018 item 4, in as many words: a rollback SHOULD rewrite the kanshi profile,
# whatever state the machine was left in. The guard restores with a plain apply.
guard_still_persists() { ! code "$guard" | grep -q -- '--no-persist'; }
want "the guard's restore does NOT skip persistence" guard_still_persists
# And Keep is still the only thing that promotes, through `save`, which never
# touches hardware.
want "Keep still persists through the save verb" \
    bash -c 'sed -n "/function confirm()/,/^    }/p" "$1" | grep -q "save --model"' _ "$svc"

# ── The staged values survive a failure ──────────────────────────────────────
want "the draft is reconciled against the hardware before applying" \
    grep -q "function problemsWith(" "$svc"
want "an output that went away is named in the error" \
    grep -q "is no longer connected" "$svc"
want "a mode the output does not have is named in the error" \
    grep -q "does not offer" "$svc"
want "a refused apply says the staged values are kept" \
    grep -q "still staged" "$svc"

# THE DISPLAY PAGE STILL MUST NOT APPLY AUTOMATICALLY. Duplicated from ci.yml
# on purpose: this is the file a reviewer opens for display invariants.
if grep -qE "onTriggered:\s*root\.apply\(\)" "$svc"; then
    bad "DisplayService applies from a timer; display changes must be explicit"
else
    ok "DisplayService never applies from a timer"
fi

# ── The shipped countdown is fifteen seconds ─────────────────────────────────
# The page promises it and the user was told it. The environment override
# exists so the behavioural suite does not sit through it six times, and a
# default that drifted would make every one of those runs a lie.
want "the countdown defaults to 15 seconds" \
    bash -c 'grep -qE ": 15$" < <(sed -n "/readonly property int confirmTotal/,/^    }/p" "$1")' _ "$svc"

# ── The guard is asked to work, not just to contain the right words ──────────
#
# Five checks in this repo have been satisfied by a file's own comments, so the
# detachment is exercised rather than grepped: spawn one, and see whether a
# process is still watching the transaction after the caller has returned.
#
# Nothing here can reach a compositor. APEX_DISPLAY_ENGINE is /bin/true, so the
# worst a guard can do is write files in a temp directory — and the verdict is
# written immediately, so it exits at once rather than sitting on a deadline.
mut="$(mktemp -d)"
trap 'rm -rf "$mut"' EXIT

arm_txn() {
    local dir="$1"
    mkdir -p "$dir"
    printf '{"outputs":[]}\n' > "$dir/rollback.json"
    printf '{"outputs":[]}\n' > "$dir/target.json"
    printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$dir/deadline"
    rm -f "$dir/verdict" "$dir/state" "$dir/guard.pid"
}

# spawns <guard-script> — 0 when a guard is genuinely watching afterwards.
spawns() {
    local script="$1" dir="$mut/txn"
    rm -rf "$dir"
    arm_txn "$dir"
    APEX_DISPLAY_ENGINE=/bin/true APEX_DISPLAY_GUARD_POLL=0.1 \
        bash "$script" spawn "$dir" >/dev/null 2>&1
    local pid=""
    for _ in $(seq 1 30); do
        [ -f "$dir/guard.pid" ] && pid="$(tr -d '[:space:]' < "$dir/guard.pid")"
        [ -n "$pid" ] && break
        sleep 0.1
    done
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # Stand it down rather than leaving it to sit out the hour.
    APEX_DISPLAY_ENGINE=/bin/true bash "$script" verdict "$dir" cancel >/dev/null 2>&1
    return 0
}

want "the real guard keeps watching after spawn returns" spawns "$guard"

# Take the detachment away and leave behind a comment that says setsid and
# names the run verb. Everything a grep could want, and no code.
cp "$guard" "$mut/mutant.sh"
grep -v '^\s*setsid -f bash' "$guard" > "$mut/mutant.sh"
cat >> "$mut/mutant.sh" <<'MUTANT'
# The guard is detached with `setsid -f bash "$0" run "$dir"` so it is not in
# the shell's process group and does not die with it.
MUTANT
mutant_does_not_spawn() { ! spawns "$mut/mutant.sh"; }
want "a detachment replaced by a comment about detachment spawns nothing" mutant_does_not_spawn

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
