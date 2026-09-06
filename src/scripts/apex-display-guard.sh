#!/usr/bin/env bash
# ─── apex-display-guard ───────────────────────────────────────────────────────
# The half of a display transaction that has to outlive APEX Shell.
#
# A temporary display apply is only safe because something puts the old layout
# back when nobody confirms the new one. If that something is a QML Timer inside
# the shell, then the shell dying during the countdown leaves the machine on the
# unconfirmed layout — which is the layout the user could not confirm, quite
# possibly because they cannot see anything. "Press Apply, shell crashes, screen
# stays black until you find a TTY" is the failure this file exists to prevent.
#
# So the countdown has two owners:
#
#   the shell   draws the dialog, counts down on screen, and asks this script
#               for a verdict when the user answers.
#   this guard  is detached from the shell (setsid), holds the rollback model,
#               and restores it when the deadline passes with no verdict.
#
# Either can revert. Reverting twice is applying the same model twice, which is
# what the engine does anyway, so the race is harmless by construction rather
# than by locking.
#
# ── The transaction directory ────────────────────────────────────────────────
#
#   target.json    the model being tried
#   rollback.json  the model that was on screen before, restored on timeout
#   deadline       epoch seconds; after this the guard reverts
#   verdict        keep | revert | cancel   — written by the shell
#   state          pending | kept | reverted | cancelled  — written by the guard
#   guard.pid      the detached guard's pid, so `reconcile` can tell whether
#                  anyone is still watching
#
# It lives under $XDG_RUNTIME_DIR, which is wiped when the session ends. That is
# correct: a transaction only means anything while the compositor it was applied
# to is still running.
#
# ── What this does NOT cover ─────────────────────────────────────────────────
#
# The guard is detached from the shell, not from the session. If the compositor
# itself dies, the guard goes with it and cannot reach a compositor to revert
# through anyway. What survives that is the persisted layout on disk, and the
# engine persists on every apply — so a session that dies mid-countdown comes
# back on the unconfirmed layout. Closing that needs an `apply --no-persist` in
# apex-display-apply plus an owner outside the session; see the P0-018 report.
#
# usage:
#   apex-display-guard.sh spawn     <dir>            detach a guard for <dir>
#   apex-display-guard.sh run       <dir>            the countdown itself
#   apex-display-guard.sh verdict   <dir> <verdict>  keep | revert | cancel
#   apex-display-guard.sh status    <dir>            "<state> <seconds-left>"
#   apex-display-guard.sh reconcile <dir>            settle an abandoned txn
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

engine="${APEX_DISPLAY_ENGINE:-/usr/libexec/apex-display-apply}"

# Polling rather than a fifo or a signal: the shell may be gone when the verdict
# is written (the recovery path writes it too), and a reader that has to be
# alive to be told is the thing being replaced here.
poll="${APEX_DISPLAY_GUARD_POLL:-0.2}"

now() { printf '%s\n' "$(date +%s)"; }

# Written through a temp file and renamed. A guard that reads a half-written
# verdict reverts a layout the user just kept.
put() {
    local dir="$1" name="$2" value="$3"
    printf '%s\n' "$value" > "$dir/.$name.tmp" && mv -f "$dir/.$name.tmp" "$dir/$name"
}

get() {
    local dir="$1" name="$2"
    [ -f "$dir/$name" ] && tr -d '[:space:]' < "$dir/$name"
}

# ── Putting the old layout back ──────────────────────────────────────────────
#
# The one operation that must not fail quietly, and the one place it is
# implemented: the shell's Revert button, the guard's timeout and `reconcile`
# all come through here, so all three restore the same bytes the same way.
#
# The fallback is the part worth reading. A rollback names the resolution that
# was on screen, which is the whole point of it — restoring a layout at
# "whatever the compositor considers preferred" is how a revert changes your
# resolution. But a mode can stop being offered between the apply and the
# revert: the output was turned off and came back renegotiated, or the
# transaction is being settled after a reboot. wlr-randr then rejects the WHOLE
# invocation and the user is left on the layout they were trying to escape.
#
# So: try it exactly, and if the compositor will not take the mode, try again
# with the modes dropped. A revert that gets the picture back at the wrong
# refresh rate is a bad outcome; a revert that leaves the screen off is a much
# worse one.
restore() {
    local dir="$1"
    [ -s "$dir/rollback.json" ] || return 1
    if "$engine" apply --model "$dir/rollback.json" >>"$dir/guard.log" 2>&1; then
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$dir/rollback.json" "$dir/rollback-modeless.json" <<'PY' || return 1
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as fh:
    model = json.load(fh)
for o in model.get("outputs", []):
    o.pop("mode", None)
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(model, fh, indent=2)
PY
    echo "apex-display-guard: the recorded modes are no longer offered; restoring the layout without them" >&2
    "$engine" apply --model "$dir/rollback-modeless.json" >>"$dir/guard.log" 2>&1
}

cmd_run() {
    local dir="$1"
    [ -d "$dir" ] || exit 1
    put "$dir" guard.pid "$$"
    put "$dir" state pending

    local deadline verdict
    deadline="$(get "$dir" deadline)"
    [ -n "$deadline" ] || deadline="$(( $(now) + 15 ))"

    while :; do
        verdict="$(get "$dir" verdict)"
        case "$verdict" in
            keep)
                put "$dir" state kept
                return 0
                ;;
            revert)
                # The shell normally applies the rollback itself so the picture
                # comes back at once rather than up to one poll later. Doing it
                # again here costs one idempotent apply and covers the shell
                # dying between writing the verdict and acting on it.
                restore "$dir"
                put "$dir" state reverted
                return 0
                ;;
            cancel)
                # The apply never reached the hardware — the engine refused it.
                # There is nothing to put back.
                put "$dir" state cancelled
                return 0
                ;;
        esac
        if [ "$(now)" -ge "$deadline" ]; then
            restore "$dir"
            put "$dir" state reverted
            return 0
        fi
        sleep "$poll"
    done
}

cmd_spawn() {
    local dir="$1"
    [ -d "$dir" ] || { echo "apex-display-guard: no such transaction: $dir" >&2; return 1; }
    # setsid, so the guard is not in the shell's process group and does not die
    # with it. `-f` also forks, so this returns immediately and the shell is not
    # holding a child for fifteen seconds.
    #
    # Not systemd-run: the guard needs WAYLAND_DISPLAY and the rest of the
    # session environment to reach a compositor at all, and a user unit starts
    # from the user manager's environment rather than this one.
    #
    # `bash "$0"`, not `"$0"`: this file is shipped inside /usr/share/apex-shell
    # and nothing in the build asserts its mode bit. `setsid -f` returns 0
    # whether or not the child managed to exec, so a lost +x would produce no
    # guard, silently, with every test still green — and the failure would only
    # show up as a machine left on a layout nobody confirmed.
    setsid -f bash "$0" run "$dir" >/dev/null 2>&1 </dev/null
}

cmd_verdict() {
    local dir="$1" v="$2"
    case "$v" in
        keep|revert|cancel) ;;
        *) echo "apex-display-guard: unknown verdict $v" >&2; return 2 ;;
    esac
    [ -d "$dir" ] || return 0
    put "$dir" verdict "$v"
}

cmd_status() {
    local dir="$1" state deadline left
    if [ ! -d "$dir" ] || [ ! -s "$dir/rollback.json" ]; then
        echo "none 0"
        return 0
    fi
    state="$(get "$dir" state)"
    [ -n "$state" ] || state=pending
    deadline="$(get "$dir" deadline)"
    left=0
    if [ -n "$deadline" ]; then
        left=$(( deadline - $(now) ))
        [ "$left" -lt 0 ] && left=0
    fi
    echo "$state $left"
}

# Settle a transaction nobody is watching any more.
#
# The shell runs this at startup. Two things can have happened while it was
# gone: the guard did its job (state is already kept or reverted, nothing to
# do), or the guard died with the shell — a `kill -9` on the process group, a
# machine that lost power — and the layout on screen is one nobody confirmed.
# In that second case the deadline decides, exactly as the guard would have.
cmd_reconcile() {
    local dir="$1" state pid left
    read -r state left < <(cmd_status "$dir")
    if [ "$state" != "pending" ]; then
        echo "$state $left"
        return 0
    fi
    pid="$(get "$dir" guard.pid)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        # Still watched. The shell re-attaches to the countdown instead.
        echo "pending $left"
        return 0
    fi
    if [ "$left" -gt 0 ]; then
        # Abandoned but not yet expired: adopt it rather than reverting a
        # layout the user may still be about to confirm.
        cmd_spawn "$dir"
        echo "pending $left"
        return 0
    fi
    restore "$dir"
    put "$dir" state reverted
    echo "reverted 0"
}

# The shell's own Revert comes through here rather than running the engine
# itself, so "put it back" is one implementation with one fallback rather than
# two that agree until one of them is edited.
cmd_restore() {
    local dir="$1"
    if restore "$dir"; then
        put "$dir" state reverted
        echo "reverted"
        return 0
    fi
    echo "apex-display-guard: could not restore the previous layout" >&2
    return 1
}

action="${1:-}"
dir="${2:-}"
case "$action" in
    run)       cmd_run       "$dir" ;;
    spawn)     cmd_spawn     "$dir" ;;
    restore)   cmd_restore   "$dir" ;;
    verdict)   cmd_verdict   "$dir" "${3:-}" ;;
    status)    cmd_status    "$dir" ;;
    reconcile) cmd_reconcile "$dir" ;;
    *)
        echo "usage: $0 {spawn|run|restore|verdict|status|reconcile} <dir> [verdict]" >&2
        exit 2
        ;;
esac
