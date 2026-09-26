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
#      LockState.lock() clears unlocking.
#   4. The IPC unlock() stays a no-op: it touches no lock state at all.
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
lock_body = re.search(r'function\s+lock\s*\(\s*\)\s*\{([^}]*)\}', st)
ls = code("src/windows/Lockscreen.qml")
rel_timer = re.search(r'property\s+Timer\s+_release\s*:\s*Timer\s*\{(.*?)\n    \}', ls, re.S)
guarded = bool(rel_timer) and re.search(
    r'onTriggered\s*:\s*\{\s*if\s*\(\s*!\s*LockState\.unlocking\s*\)\s*return', rel_timer.group(1)) is not None
verdict("CANCEL",
        guarded and bool(lock_body) and re.search(r'unlocking\s*=\s*false', lock_body.group(1)) is not None
        and re.search(r'locked\s*=\s*true', lock_body.group(1)) is not None,
        "the release must return unless still unlocking, and lock() must clear unlocking")

verdict("NOUNLOCK", bool(unlockfn) and "LockState" not in unlockfn.group(1),
        "the IPC unlock() must not touch lock state")
PY
}

label() {
    case "$1" in
        WRITERS)  echo "only LockState and Lockscreen's release (= false) write LockState.locked" ;;
        CALLERS)  echo "the IPC lock and the power menu both lock through LockState.lock()" ;;
        CANCEL)   echo "a lock asked for during the release cancels it (lock() clears unlocking, the timer checks it)" ;;
        NOUNLOCK) echo "the IPC unlock() is still a no-op" ;;
    esac
}

echo "── lock writes ──"
verdicts="$(check_tree .)"
while read -r rule verdict detail; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$(label "$rule")"; else bad "$(label "$rule") — $detail"; fi
done <<<"$verdicts"
[ "$(grep -c . <<<"$verdicts")" -eq 4 ] && ok "all four rules were evaluated" || bad "expected four verdicts, got: $verdicts"

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
mutant "lock() not cancelling" src/state/LockState.qml "root.unlocking = false
        root.locked = true" "root.locked = true" CANCEL
mutant "an unlock over IPC" src/state/IpcManager.qml "            // Deliberately does nothing. See note above." "            LockState.unlocking = true" NOUNLOCK

echo
echo "check-lock-writes: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
