#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-lock-writes.sh — who may lock the session, and who may unlock it.
#
#  Since 2026-09-26 a correct password releases the lock a beat LATER (the
#  lock UI plays its exit first, Lockscreen.release()), and during that beat
#  LockState.locked is still true. A bare `LockState.locked = true` then
#  changes nothing — a lock asked for in that window (hypridle's
#  before_sleep_cmd, a lid closed just after Enter) was LOST and the release
#  unlocked anyway. So:
#
#   1. Nothing in src/ writes `LockState.locked` except LockState itself (its
#      lock(), which also cancels a pending release) and Lockscreen.qml (the
#      release, `= false`, and only that).
#   2. Every request for a lock — the IPC handler and the power menu — calls
#      LockState.lock().
#   3. The release unlocks only if it has not been cancelled: its timer
#      returns early unless LockState.unlocking is still set, and
#      LockState.lock() clears unlocking before anything else.
#   4. The IPC unlock() stays a no-op: it touches no lock state at all.
#
#  Since 2026-09-27 a fresh lock may wait for windows/LockCapture.qml's
#  picture of the desktop (the arrival's first frame) before it engages. A
#  lock that waits is a lock that can be lost, so two more rules:
#
#   5. IMMEDIATE — a lock asked for while locked (the release window
#      included: that is rule 3's hold), while a capture is already running,
#      or with no capture available engages AT ONCE; and _engage() sets
#      locked = true with no condition of its own.
#   6. BOUNDED — the waiting path always arms _captureCap before it asks for
#      the picture, the cap is at most 150 ms, and when it fires it engages,
#      unconditionally. Nothing the capture does (or fails to do) can hold the
#      session unlocked past it.
#
#  Each rule is mutated on a copy to prove it can fail (repo idiom: a mutant
#  that did not apply is reported as such, never as caught).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

check_tree() {   # check_tree <root> — one verdict line per rule: RULE PASS|FAIL detail
    python3 - "$1" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
def code(p):
    return "\n".join(l.split("//", 1)[0] for l in (root / p).read_text().split("\n"))
def verdict(rule, good, detail=""):
    print(rule, "PASS" if good else "FAIL", detail)

writers = []
for f in (root / "src").rglob("*.qml"):
    rel = str(f.relative_to(root))
    c = "\n".join(l.split("//", 1)[0] for l in f.read_text(errors="replace").split("\n"))
    for m in re.finditer(r'LockState\s*\.\s*locked\s*=(?!=)\s*([^\n;]+)', c):
        writers.append((rel, m.group(1).strip()))
bad_writers = [w for w in writers
               if not (w[0] == "src/windows/Lockscreen.qml" and w[1] == "false")]
verdict("WRITERS", not bad_writers, "; ".join("%s = %s" % w for w in bad_writers))

ipc = code("src/state/IpcManager.qml")
pm  = code("src/services/PowerMenu.qml")
lk  = re.search(r'target:\s*"lockscreen"(.*?)\n    \}', ipc, re.S)
lk  = lk.group(1) if lk else ""
lockfn = re.search(r'function\s+lock\s*\(\s*\)\s*\{([^}]*)\}', lk)
unlockfn = re.search(r'function\s+unlock\s*\(\s*\)\s*\{([^}]*)\}', lk)
verdict("CALLERS",
        bool(lockfn) and "LockState.lock()" in lockfn.group(1)
        and re.search(r'action\s*===\s*"lock"\)\s*\{[^}]*LockState\.lock\(\)', pm) is not None,
        "the IPC lock() and the power menu's lock must call LockState.lock()")

st = code("src/state/LockState.qml")

def body(src, head):
    """The brace-balanced body of the first `head {`, or None."""
    m = re.search(head + r'\s*\{', src)
    if not m: return None
    i = m.end(); depth = 1
    while i < len(src) and depth:
        depth += {"{": 1, "}": -1}.get(src[i], 0); i += 1
    return src[m.end():i - 1] if depth == 0 else None

lock_body = body(st, r'function\s+lock\s*\(\s*\)') or ""
engage_body = body(st, r'function\s+_engage\s*\(\s*\)') or ""
cap_body = body(st, r'property\s+Timer\s+_captureCap\s*:\s*Timer') or ""
ls = code("src/windows/Lockscreen.qml")
rel_timer = re.search(r'property\s+Timer\s+_release\s*:\s*Timer\s*\{(.*?)\n    \}', ls, re.S)
guarded = bool(rel_timer) and re.search(
    r'onTriggered\s*:\s*\{\s*if\s*\(\s*!\s*LockState\.unlocking\s*\)\s*return', rel_timer.group(1)) is not None
first = [l.strip() for l in lock_body.split("\n") if l.strip()]
verdict("CANCEL", guarded and bool(first) and re.fullmatch(r'root\.unlocking\s*=\s*false;?', first[0]) is not None,
        "the release must return unless still unlocking, and lock() must clear unlocking first")

imm = re.search(r'if\s*\(([^)]*)\)\s*\{\s*root\._engage\(\)\s*;?\s*return\s*;?\s*\}', lock_body)
cond = imm.group(1) if imm else ""
verdict("IMMEDIATE",
        bool(imm) and re.search(r'root\.locked\b', cond) is not None and re.search(r'root\.capturing\b', cond) is not None
        and re.search(r'!\s*root\.captureEnabled\b', cond) is not None and "&&" not in cond
        and re.search(r'^\s*root\.locked\s*=\s*true\s*;?\s*$', engage_body, re.M) is not None
        and not re.search(r'\bif\b|\breturn\b|\?', engage_body),
        "lock() must engage at once while locked, while capturing, or with no capture; _engage() must lock unconditionally")

iv = re.search(r'interval\s*:\s*(\d+)', cap_body)
defer = lock_body[imm.end():] if imm else ""
arm, ask = defer.find("root._captureCap.restart()"), defer.find("root.captureRequested(")
verdict("BOUNDED",
        bool(iv) and int(iv.group(1)) <= 150 and re.search(r'repeat\s*:\s*false', cap_body) is not None
        and re.search(r'onTriggered\s*:\s*root\._engage\(\)\s*$', cap_body, re.M) is not None
        and arm >= 0 and ask >= 0 and arm < ask,
        "the waiting path must arm a cap of at most 150 ms before asking, and the cap must engage unconditionally")

verdict("NOUNLOCK", bool(unlockfn) and "LockState" not in unlockfn.group(1),
        "the IPC unlock() must not touch lock state")
PY
}

label() {
    case "$1" in
        WRITERS)  echo "only LockState and Lockscreen's release (= false) write LockState.locked" ;;
        CALLERS)  echo "the IPC lock and the power menu both lock through LockState.lock()" ;;
        CANCEL)   echo "a lock asked for during the release cancels it (lock() clears unlocking first, the timer checks it)" ;;
        IMMEDIATE) echo "a lock while locked, while capturing, or with no capture engages at once; _engage() is unconditional" ;;
        BOUNDED)  echo "a lock waiting for its picture is capped (<= 150 ms, armed first) and the cap always engages" ;;
        NOUNLOCK) echo "the IPC unlock() is still a no-op" ;;
    esac
}

echo "── lock writes ──"
verdicts="$(check_tree .)"
while read -r rule verdict detail; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$(label "$rule")"; else bad "$(label "$rule") — $detail"; fi
done <<<"$verdicts"
[ "$(grep -c . <<<"$verdicts")" -eq 6 ] && ok "all six rules were evaluated" || bad "expected six verdicts, got: $verdicts"

echo "── self-test: can these checks fail? ──"
MW="$(mktemp -d)"; trap 'rm -rf "$MW"' EXIT INT TERM
mutant() {   # mutant <label> <file> <old> <new> <rule that must FAIL>
    rm -rf "$MW/t"; mkdir -p "$MW/t"; cp -r src "$MW/t/src"
    if ! python3 - "$MW/t/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s: sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
PY
    then bad "self-test $1: the mutation did not apply"; return; fi
    if check_tree "$MW/t" | grep -q "^$5 FAIL"; then ok "self-test $1: caught"
    else bad "self-test $1: SURVIVED"; fi
}
mutant "a direct write from IPC" src/state/IpcManager.qml "LockState.lock()" "LockState.locked = true" WRITERS
mutant "the power menu bypassing lock()" src/services/PowerMenu.qml "LockState.lock()" "LockState.locked = true" CALLERS
mutant "an unguarded release" src/windows/Lockscreen.qml "if (!LockState.unlocking) return" "if (false) return" CANCEL
mutant "lock() not cancelling" src/state/LockState.qml "        root.unlocking = false
        if (root.locked" "        if (root.locked" CANCEL
mutant "a lock while locked waiting for a picture" src/state/LockState.qml "if (root.locked || root.capturing ||" "if (root.capturing ||" IMMEDIATE
mutant "a second request made to wait" src/state/LockState.qml "if (root.locked || root.capturing ||" "if (root.locked ||" IMMEDIATE
mutant "an engage with a condition" src/state/LockState.qml "        root.revealScreens = ({})
        root.locked = true" "        root.revealScreens = ({})
        if (root.captureSeq > 0) root.locked = true" IMMEDIATE
mutant "an unbounded wait" src/state/LockState.qml "interval: 120" "interval: 5000" BOUNDED
mutant "a cap that does not engage" src/state/LockState.qml "onTriggered: root._engage()" "onTriggered: {}" BOUNDED
mutant "a wait with no cap armed" src/state/LockState.qml "        root._captureCap.restart()
" "" BOUNDED
mutant "an unlock over IPC" src/state/IpcManager.qml "            // Deliberately does nothing. See note above." "            LockState.unlocking = true" NOUNLOCK

echo
echo "check-lock-writes: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
