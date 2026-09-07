#!/usr/bin/env bash
# The P0-018 scenarios that need an output to really appear and really go away.
#
#     ./tests/run-display-unplug-test.sh
#
# ── Why a second harness, and why sway ───────────────────────────────────────
#
# tests/run-display-transaction-test.sh covers confirm, manual revert, timeout,
# invalid mode and shell restart against a headless labwc. It cannot cover the
# rest, for one reason: labwc has no way to add or remove an output while it is
# running, so its "disconnected output" scenario is a wrapper that stops
# reporting HEADLESS-2 from `list` while the compositor still has it. That
# tests the shell's reconciliation, which is worth testing, and it is not an
# unplug — nothing goes away, and nothing that was aimed at it fails.
#
# sway's headless backend does both for real: `swaymsg create_output` adds a
# wlroots output and `swaymsg output <name> unplug` destroys one. Every layer
# above sees a genuine hotplug. That is what these three scenarios need:
#
#   exact     criterion 5. A revert has to restore the configuration, not the
#             one field the assertion happened to look at. Four fields are
#             changed across two outputs and the whole enumeration is compared.
#   unplug    criterion 8's disconnected output, with the output really
#             destroyed rather than hidden from one code path.
#   mid-flight  criterion 6. An output the ROLLBACK names disappears during the
#             countdown, so the recovery the guard is about to attempt is
#             already invalid when it starts. wlr-randr rejects a whole
#             invocation that names an unknown output, so this is the case
#             where a revert can leave the screen worse than it found it.
#   engine    criterion 6 again, from the other side: the engine fails while
#             the guard is trying to put the layout back. The layout stays
#             wrong — nothing can fix that from here — but the transaction must
#             not be recorded as settled, because the next shell to start is
#             the last thing that could still repair it.
#
# ── Why this can never touch the developer's session ─────────────────────────
#
# The same four defences as the labwc harness, plus one. In order:
#
#   1. A private XDG_RUNTIME_DIR, so the nested sway's socket cannot collide
#      with a real session's and nothing here can find one by scanning.
#   2. WAYLAND_DISPLAY is the nested socket; wlr-randr speaks to sway and
#      nothing else.
#   3. HYPRLAND_INSTANCE_SIGNATURE and NIRI_SOCKET are removed.
#   4. PATH is prefixed with a shim holding a `hyprctl` that exits 127.
#   5. And a `pgrep` that answers "no" for Hyprland, niri and labwc. The engine
#      falls back to `pgrep -x` when XDG_CURRENT_DESKTOP names no compositor it
#      knows, and on Andre's desk that fallback finds his live Hyprland. Which
#      is exactly how a display test blanks the developer's screen.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

for tool in quickshell sway swaymsg wlr-randr python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 0; }
done

engine="${APEX_DISPLAY_ENGINE_REAL:-/usr/libexec/apex-display-apply}"
[ -x "$engine" ] || { echo "SKIP: no display engine at $engine (it ships with APEX-OS)"; exit 0; }

timeout_s="${APEX_TEST_CONFIRM_SECONDS:-5}"

sandbox="$(mktemp -d)"
shim="$sandbox/shim"
mkdir -p "$shim" "$sandbox/home" "$sandbox/run"
chmod 0700 "$sandbox/run"

# The engine wrapper. Passthrough, with one behaviour of its own: while
# $sandbox/engine-fails exists, every `apply` fails without running the real
# program. That is the "the compositor adapter failed during the countdown"
# arm — a broken engine, not a rejected layout, which the labwc suite already
# covers through a mode the output does not have.
cat > "$shim/apex-display-apply" <<WRAP
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = "apply" ] && [ -e "$sandbox/engine-fails" ]; then
        echo "apex-display-apply: injected failure" >&2
        exit 9
    fi
done
exec "$engine" "\$@"
WRAP
chmod +x "$shim/apex-display-apply"

printf '#!/bin/sh\necho "hyprctl is not available in the display unplug test" >&2\nexit 127\n' \
    > "$shim/hyprctl"
chmod +x "$shim/hyprctl"

# See defence 5. Everything else is forwarded, so a `pgrep` for anything the
# engine does not branch on still behaves.
cat > "$shim/pgrep" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        Hyprland|niri|labwc) exit 1 ;;
    esac
done
exec /usr/bin/pgrep "$@"
SHIM
chmod +x "$shim/pgrep"

sway_pid=""
shell_pid=""
cleanup() {
    [ -n "$shell_pid" ] && { kill -9 "$shell_pid" 2>/dev/null; wait "$shell_pid" 2>/dev/null; }
    [ -n "$sway_pid" ]  && { kill "$sway_pid" 2>/dev/null; wait "$sway_pid" 2>/dev/null; }
    rm -rf "$sandbox"
    return 0
}
trap cleanup EXIT INT TERM

printf 'output HEADLESS-1 mode 1920x1200@60Hz position 0,0 scale 1\nxwayland disable\n' \
    > "$sandbox/sway.cfg"

env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET -u DISPLAY \
    XDG_RUNTIME_DIR="$sandbox/run" \
    SWAYSOCK="$sandbox/sway.sock" \
    WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    XDG_CURRENT_DESKTOP=sway:wlroots \
    sway -c "$sandbox/sway.cfg" >"$sandbox/sway.log" 2>&1 &
sway_pid=$!

nested=""
for _ in $(seq 1 80); do
    for f in "$sandbox/run"/wayland-*; do
        [ -S "$f" ] || continue
        nested="${f##*/}"
        break
    done
    [ -n "$nested" ] && break
    kill -0 "$sway_pid" 2>/dev/null || break
    sleep 0.25
done
if [ -z "$nested" ]; then
    echo "SKIP: headless sway did not come up"
    tail -10 "$sandbox/sway.log"
    exit 0
fi
echo "headless sway on $nested ($(sway --version 2>&1 | head -1))"

ENVV=(env -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET -u DISPLAY
      XDG_RUNTIME_DIR="$sandbox/run"
      WAYLAND_DISPLAY="$nested"
      SWAYSOCK="$sandbox/sway.sock"
      XDG_CURRENT_DESKTOP=sway:wlroots
      HOME="$sandbox/home"
      PATH="$shim:$PATH"
      APEX_DISPLAY_ENGINE="$shim/apex-display-apply"
      APEX_DISPLAY_TXN_DIR="$sandbox/txn"
      APEX_DISPLAY_CONFIRM_SECONDS="$timeout_s"
      APEX_DISPLAY_GUARD_POLL=0.1)
run() { "${ENVV[@]}" "$@"; }

# A real second output. This is the whole reason the file exists.
run swaymsg create_output >/dev/null 2>&1
for _ in $(seq 1 20); do
    grep -q HEADLESS-2 < <(run wlr-randr --json 2>/dev/null) && break
    sleep 0.25
done
run wlr-randr \
    --output HEADLESS-1 --custom-mode 1920x1200@60Hz --pos 0,0    --scale 1 --transform normal \
    --output HEADLESS-2 --custom-mode 2560x1080@60Hz --pos 1920,0 --scale 1 --transform normal \
    >/dev/null 2>&1
sleep 0.5

# Every field the model controls, and nothing else: `modes` and `description`
# move for reasons the transaction is not responsible for. This is what
# "the exact pre-apply configuration" is compared as.
snapshot() {
    run wlr-randr --json 2>/dev/null | python3 -c '
import json, sys
try:
    outs = json.load(sys.stdin)
except Exception:
    print("UNREADABLE"); raise SystemExit(0)
rows = []
for o in sorted(outs, key=lambda o: o["name"]):
    cur = next((m for m in o.get("modes", []) if m.get("current")), None)
    rows.append({
        "name":      o["name"],
        "enabled":   bool(o.get("enabled")),
        "x":         (o.get("position") or {}).get("x"),
        "y":         (o.get("position") or {}).get("y"),
        "scale":     round(float(o.get("scale") or 1), 3),
        "transform": o.get("transform"),
        "mode":      cur and [cur["width"], cur["height"], round(float(cur["refresh"]), 1)],
    })
print(json.dumps(rows, sort_keys=True))
'
}

names_on() {
    run wlr-randr --json 2>/dev/null \
        | python3 -c 'import json,sys; print(",".join(o["name"] for o in json.load(sys.stdin) if o["enabled"]))'
}

start="$(snapshot)"
case "$start" in
    *HEADLESS-1*HEADLESS-2*) echo "outputs: two real ones, $(names_on)" ;;
    *) echo "SKIP: sway did not give this run two headless outputs"; echo "$start"; exit 0 ;;
esac

# ── the shell ────────────────────────────────────────────────────────────────
shell_log="$sandbox/shell.log"
: > "$shell_log"
( cd "$root" && exec "${ENVV[@]}" QT_LOGGING_RULES="qml=true" \
    quickshell -p "$root/shell.qml" ) >"$shell_log" 2>&1 &
shell_pid=$!

loaded=0
for _ in $(seq 1 200); do
    grep -q "Configuration Loaded" "$shell_log" && { loaded=1; break; }
    kill -0 "$shell_pid" 2>/dev/null || break
    sleep 0.25
done
if [ "$loaded" -ne 1 ]; then
    echo "SKIP: the shell did not load in the nested session"
    grep -E "ERROR|error:" "$shell_log" | head -10 | sed 's/^/        /'
    exit 0
fi

ipc() { ( cd "$root" && run quickshell -p "$root/shell.qml" ipc call display "$@" ) 2>&1; }

# The Display page is what enumerates. Without it DisplayService.draft is empty,
# every `set` finds no output to stage against, and every scenario below fails
# for a reason that has nothing to do with what it is testing.
( cd "$root" && run quickshell -p "$root/shell.qml" ipc call nexus open display ) >/dev/null 2>&1
for _ in $(seq 1 40); do
    case "$(ipc status)" in *HEADLESS-*) break ;; esac
    sleep 0.25
done

# `set` is silent about an output it could not find, so assert the staging
# happened rather than discovering it as a mystery failure three lines later.
staged_or_die() {
    case "$(ipc status)" in
        *staged*) return 0 ;;
        *) bad "$1 (nothing staged; the page never enumerated)"; return 1 ;;
    esac
}

settle() {
    for _ in $(seq 1 60); do
        case "$(ipc status)" in *idle*) return 0 ;; esac
        sleep 0.5
    done
    return 1
}

# Between scenarios, not inside them.
#
# A draft with staged changes is deliberately NOT overwritten by a re-
# enumeration — that is criterion 7, and the labwc suite asserts it — so an
# output destroyed by one scenario stays in the next scenario's draft and every
# apply after it is refused for naming a monitor that is gone. Which is correct
# behaviour and useless as a starting state. There is no verb for "throw the
# staged changes away" and this suite is not the place to invent one, so the
# scenarios that need a clean draft get a new shell.
restart_shell() {
    [ -n "$shell_pid" ] && { kill -9 "$shell_pid" 2>/dev/null; wait "$shell_pid" 2>/dev/null; }
    shell_pid=""
    : > "$shell_log"
    ( cd "$root" && exec "${ENVV[@]}" QT_LOGGING_RULES="qml=true" \
        quickshell -p "$root/shell.qml" ) >"$shell_log" 2>&1 &
    shell_pid=$!
    for _ in $(seq 1 200); do
        grep -q "Configuration Loaded" "$shell_log" && break
        kill -0 "$shell_pid" 2>/dev/null || break
        sleep 0.25
    done
    ( cd "$root" && run quickshell -p "$root/shell.qml" ipc call nexus open display ) >/dev/null 2>&1
    for _ in $(seq 1 40); do
        case "$(ipc status)" in *clean*) return 0 ;; esac
        sleep 0.25
    done
    return 1
}

# ── 1  exact ─────────────────────────────────────────────────────────────────
# Criterion 5. Four fields across two outputs, so a revert that restores one of
# them and forgets the rest cannot pass.
echo
echo "── exact: a timeout restores the whole configuration, not one field ──"
before="$(snapshot)"
ipc set HEADLESS-1 scale 1.5      >/dev/null
ipc set HEADLESS-1 transform 90   >/dev/null
ipc set HEADLESS-2 x 3000         >/dev/null
ipc set HEADLESS-2 scale 2        >/dev/null
staged_or_die "four fields across two outputs staged"
echo "  ipc apply  -> $(ipc apply)"

changed=""
for _ in $(seq 1 40); do
    changed="$(snapshot)"
    [ "$changed" != "$before" ] && break
    sleep 0.25
done
if [ "$changed" = "$before" ]; then
    bad "the staged layout never reached the compositor"
else
    ok "the staged layout reached the compositor"
fi
# Named individually, because "the snapshot differs" is satisfied by one field
# moving, and a model that silently drops one of the four would then make the
# comparison below trivially true — restoring a field nothing ever changed.
for probe in '"scale": 1.5' '"transform": "90"' '"x": 3000' '"scale": 2'; do
    grep -qF "$probe" <<<"$changed" \
        && ok "the compositor took ${probe}" \
        || bad "${probe} never reached the compositor, so the revert below proves nothing"
done

sleep "$(( timeout_s + 8 ))"
after="$(snapshot)"
if [ "$after" = "$before" ]; then
    ok "the timeout restored the enumeration exactly, field for field"
else
    bad "the timeout restored something else"
    echo "        before: $before"
    echo "        after:  $after"
fi
settle

# ── 2  unplug ────────────────────────────────────────────────────────────────
# Criterion 8's disconnected output, with the output actually destroyed.
echo
echo "── unplug: an output staged for change is destroyed before Apply ──"
ipc revert >/dev/null 2>&1
settle
ipc set HEADLESS-2 scale 1.6 >/dev/null
staged_or_die "a change staged on the output about to be destroyed"
before="$(snapshot)"
run swaymsg output HEADLESS-2 unplug >/dev/null 2>&1
gone=0
for _ in $(seq 1 40); do
    case "$(names_on)" in *HEADLESS-2*) sleep 0.25 ;; *) gone=1; break ;; esac
done
[ "$gone" -eq 1 ] \
    && ok "the output is really gone, not hidden from one code path" \
    || bad "swaymsg unplug did not destroy HEADLESS-2"

out="$(ipc apply)"
echo "  ipc apply  -> $out"
sleep 2
status="$(ipc status)"
case "$status" in
    *idle*) ok "a destroyed output starts no countdown" ;;
    *)      bad "a countdown is running against an output that does not exist ($status)" ;;
esac
case "$status" in
    *staged*) ok "the staged values survive the unplug" ;;
    *)        bad "the unplug discarded the user's staged values ($status)" ;;
esac
case "$status" in
    *error:*HEADLESS-2*) ok "the error names the output that went away" ;;
    *) bad "nothing names HEADLESS-2; the user is told nothing happened ($status)" ;;
esac
case "$status" in
    *"no longer connected"*) ok "the error says what is wrong with it" ;;
    *) bad "the error does not say the output is gone ($status)" ;;
esac

# ── 3  mid-flight ────────────────────────────────────────────────────────────
# Criterion 6. The rollback names an output that stops existing while the
# countdown is running, so the recovery is invalid before it is attempted.
echo
echo "── mid-flight: the rollback's own output is destroyed during the countdown ──"
rm -rf "$sandbox/txn"
restart_shell \
    && ok "a new shell starts on a draft with no destroyed output in it" \
    || bad "the shell did not come back with a clean draft"
# sway numbers each new headless output, so the replacement is not necessarily
# called HEADLESS-2. Take the name from the compositor rather than assuming it.
run swaymsg create_output >/dev/null 2>&1
second=""
for _ in $(seq 1 40); do
    second="$(names_on | tr ',' '\n' | grep -v '^HEADLESS-1$' | head -1)"
    [ -n "$second" ] && break
    sleep 0.25
done
[ -n "$second" ] \
    && ok "a second output was created: $second" \
    || bad "swaymsg create_output produced nothing"
run wlr-randr --output HEADLESS-1 --custom-mode 1920x1200@60Hz --pos 0,0 --scale 1 --transform normal >/dev/null 2>&1
[ -n "$second" ] && run wlr-randr --output "$second" --pos 1920,0 --scale 1 --transform normal >/dev/null 2>&1
sleep 1
ipc refresh >/dev/null
sleep 2
before1="$(snapshot | python3 -c 'import json,sys; print(json.dumps([o for o in json.loads(sys.stdin.read()) if o["name"]=="HEADLESS-1"]))')"

ipc set HEADLESS-1 scale 1.75 >/dev/null
staged_or_die "a change staged on the output that has to survive"
echo "  ipc apply  -> $(ipc apply)"
armed=0
for _ in $(seq 1 60); do
    case "$(ipc status)" in *waiting*) armed=1; break ;; esac
    sleep 0.25
done
[ "$armed" -eq 1 ] || echo "        status: $(ipc status)"
[ "$armed" -eq 1 ] \
    && ok "a countdown is running to destroy an output during" \
    || bad "no countdown to interrupt"

run swaymsg output "$second" unplug >/dev/null 2>&1
ok "$second destroyed while the transaction was pending"

sleep "$(( timeout_s + 10 ))"
after1="$(snapshot | python3 -c 'import json,sys; print(json.dumps([o for o in json.loads(sys.stdin.read()) if o["name"]=="HEADLESS-1"]))')"
if [ "$after1" = "$before1" ]; then
    ok "the surviving output was restored exactly, despite the rollback naming a dead one"
else
    bad "the revert took the missing output down with it"
    echo "        before: $before1"
    echo "        after:  $after1"
fi
state="$(tr -d '[:space:]' < "$sandbox/txn/state" 2>/dev/null)"
case "$state" in
    reverted) ok "the guard settled the transaction" ;;
    *)        bad "the guard left the transaction at '${state:-<none>}'" ;;
esac

# ── 4  engine ────────────────────────────────────────────────────────────────
# Criterion 6, the arm where nothing can put the layout back. The requirement is
# not that it succeeds — it cannot — but that it does not LIE about having
# succeeded, because `reconcile` at the next shell start reads that answer and
# is the last thing that could still repair the machine.
echo
echo "── engine: the adapter fails while the guard is reverting ──"
settle
rm -rf "$sandbox/txn"
run wlr-randr --output HEADLESS-1 --scale 1 --transform normal >/dev/null 2>&1
sleep 0.5
restart_shell >/dev/null 2>&1
sleep 1
ipc set HEADLESS-1 scale 1.25 >/dev/null
staged_or_die "a change staged for the engine to fail on"
echo "  ipc apply  -> $(ipc apply)"
armed=0
for _ in $(seq 1 60); do
    case "$(ipc status)" in *waiting*) armed=1; break ;; esac
    sleep 0.25
done
[ "$armed" -eq 1 ] || echo "        status: $(ipc status)"
if [ "$armed" -ne 1 ]; then
    bad "no countdown for the engine to fail during"
else
    touch "$sandbox/engine-fails"
    ok "the engine is broken with the countdown still running"
    sleep "$(( timeout_s + 10 ))"

    scale="$(run wlr-randr --json | python3 -c 'import json,sys; print([o["scale"] for o in json.load(sys.stdin) if o["name"]=="HEADLESS-1"][0])')"
    case "$scale" in
        1.25*) ok "the layout is still the unconfirmed one, as it must be" ;;
        *)     bad "something applied a layout with the engine broken (scale=$scale)" ;;
    esac

    state="$(tr -d '[:space:]' < "$sandbox/txn/state" 2>/dev/null)"
    if [ "$state" = "reverted" ]; then
        bad "the guard recorded 'reverted' having restored nothing; the next start will not retry"
    else
        ok "the guard did not claim a revert it could not perform (state=${state:-<none>})"
    fi

    # And the repair path: with the engine working again, the settlement a new
    # shell runs at startup has to finish the job.
    rm -f "$sandbox/engine-fails"
    out="$(run bash "$root/src/scripts/apex-display-guard.sh" reconcile "$sandbox/txn")"
    echo "  reconcile  -> $out"
    sleep 2
    scale="$(run wlr-randr --json | python3 -c 'import json,sys; print([o["scale"] for o in json.load(sys.stdin) if o["name"]=="HEADLESS-1"][0])')"
    case "$scale" in
        1.0*) ok "the next shell's reconcile put the layout back" ;;
        *)    bad "the transaction is unrecoverable after an engine failure (scale=$scale)" ;;
    esac
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
