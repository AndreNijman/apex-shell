#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-singleton-imports.sh — every singleton a QML file uses is exported by
#  one of that file's imports.
#
#  IpcManager's window-switcher target called WindowSwitcherService, which only
#  services/qmldir exports, and IpcManager never imported ../services. QML does
#  not reject that at load: each call threw "ReferenceError:
#  WindowSwitcherService is not defined" at runtime, so ALT+Tab did nothing
#  from the day the switcher landed (afcb4fd1, 2026-09-20) until Andre tried it
#  on 2026-09-29 ("the alt+tab to switch doesnt work"). Both switcher suites
#  stage their own IpcHandler around the service, so neither reached the
#  shell's.
#
#  So, for every .qml under src/ (and shell.qml): a name that some qmldir
#  declares as a singleton and that the file uses as `Name.` must be declared
#  by the qmldir of the file's own directory or of a directory it imports.
#  Comments and strings are stripped first, and an `id:` of the same name
#  shadows the singleton.
#
#  The self-test proves the scan can fail: IpcManager without the import, and
#  a new file that uses a singleton it cannot see.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

scan() {   # scan <root> — one "file name" line per singleton used but not imported
    python3 - "$1" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1]).resolve()
src = root / "src"
exports = {}
for q in src.rglob("qmldir"):
    exports[q.parent.resolve()] = set(re.findall(r'^\s*singleton\s+(\w+)\s', q.read_text(), re.M))
names = set().union(*exports.values()) if exports else set()
files = list(src.rglob("*.qml")) + ([root / "shell.qml"] if (root / "shell.qml").exists() else [])
for f in sorted(files):
    txt = f.read_text()
    code = re.sub(r'/\*.*?\*/', '', txt, flags=re.S)
    code = "\n".join(l.split("//", 1)[0] for l in code.split("\n"))
    bare = re.sub(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'|`(?:[^`\\]|\\.)*`', '""', code)
    used = {n for n in names if re.search(r'(?<![\w.])' + n + r'\s*\.', bare)}
    if not used:
        continue
    visible = set(exports.get(f.parent.resolve(), set()))
    for imp in re.findall(r'^\s*import\s+"([^"]+)"', code, re.M):
        d = (f.parent / imp).resolve()
        visible |= exports.get(d, set())
    ids = set(re.findall(r'\bid\s*:\s*(\w+)', bare))
    for n in sorted(used - visible - ids):
        print(f.relative_to(root), n)
PY
}

echo "── singletons are imported where they are used ──"
missing="$(scan .)"
if [ -z "$missing" ]; then
    ok "every singleton used in src/ is exported by an import of the file using it"
else
    while read -r f n; do bad "$f uses $n, which none of its imports export"; done <<<"$missing"
fi

echo "── self-test: can this check fail? ──"
MW="$(mktemp -d)"; trap 'rm -rf "$MW"' EXIT INT TERM
fresh() { rm -rf "$MW/t"; mkdir -p "$MW/t"; cp -r src "$MW/t/src"; }

fresh
if python3 - "$MW/t/src/state/IpcManager.qml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'import "../services"\n'
if old not in s: sys.exit(3)
open(p, "w").write(s.replace(old, "", 1))
PY
then
    scan "$MW/t" | grep -q '^src/state/IpcManager.qml WindowSwitcherService$' \
        && ok "self-test IpcManager without ../services: caught" \
        || bad "self-test IpcManager without ../services: SURVIVED"
else
    bad "self-test IpcManager without ../services: the mutation did not apply"
fi

fresh
mkdir -p "$MW/t/src/scratch"
printf 'import QtQuick\nimport "../"\nItem { Component.onCompleted: WindowSwitcherService.next() }\n' \
    > "$MW/t/src/scratch/Probe.qml"
scan "$MW/t" | grep -q '^src/scratch/Probe.qml WindowSwitcherService$' \
    && ok "self-test a new file that cannot see its singleton: caught" \
    || bad "self-test a new file that cannot see its singleton: SURVIVED"

printf 'import QtQuick\nimport "../"\nItem { // WindowSwitcherService.next()\n  property string s: "WindowSwitcherService.next()"\n}\n' \
    > "$MW/t/src/scratch/Probe.qml"
scan "$MW/t" | grep -q 'src/scratch/Probe.qml' \
    && bad "self-test a name in a comment or a string: flagged (it must not be)" \
    || ok "self-test a name in a comment or a string: not flagged"

echo
echo "check-singleton-imports: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
