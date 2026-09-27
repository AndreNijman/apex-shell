#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-shaders.sh — every shader the shell loads is built from the source
#  beside it, and speaks the interface its QML gives it.
#
#  Qt 6 loads shaders as precompiled .qsb packages, so a .frag edited without
#  rebuilding its .qsb changes NOTHING on screen, silently. And a uniform the
#  QML side does not declare is simply zero, silently: a field drawn with no
#  body is a Nexus that opens as a scrim and floating text. So, for every
#  src/**/*.frag:
#
#   1. a .qsb sits beside it, and tests/shaders.lock records both: the
#      source's sha256, the qsb version that built it and the package's sha256.
#      The source and the package must match the lock (edited, not rebuilt:
#      caught; a package from elsewhere: caught).
#   2. it is rebuilt here. With the same qsb version the bytes must be
#      identical (qsb is deterministic, measured); with another version the
#      interface — the uniform block, member by member — must be.
#   3. every uniform (qt_Matrix and qt_Opacity aside) is a property declared
#      in the QML file that loads that .qsb.
#
#  qsb is required: without it nothing here can be checked, and this FAILS
#  rather than skip (a gate that inspects nothing passes everything).
#
#    tests/check-shaders.sh            check
#    tests/check-shaders.sh --update   rebuild every .qsb and rewrite the lock
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

QSB_FLAGS=(--glsl "100 es,120,150" --hlsl 50 --msl 12)
LOCK=tests/shaders.lock

qsb=""
for c in qsb qsb-qt6 /usr/lib64/qt6/bin/qsb /usr/lib/qt6/bin/qsb; do
    command -v "$c" >/dev/null 2>&1 && { qsb="$c"; break; }
done
if [ -z "$qsb" ]; then
    echo "  FAIL qsb is not installed (qt6-shadertools / qt6-qtshadertools): no shader can be checked"
    echo "check-shaders: passed=0 failed=1"
    exit 1
fi
qsb_version="$("$qsb" --version 2>/dev/null | awk '{print $2}')"

if [ "${1:-}" = "--update" ]; then
    : > "$LOCK.new"
    while IFS= read -r frag; do
        "$qsb" "${QSB_FLAGS[@]}" -o "$frag.qsb" "$frag" || { echo "qsb failed on $frag"; rm -f "$LOCK.new"; exit 1; }
        printf '%s %s %s %s\n' "$frag" "$(sha256sum < "$frag" | cut -c1-64)" "$qsb_version" \
            "$(sha256sum < "$frag.qsb" | cut -c1-64)" >> "$LOCK.new"
        echo "built $frag.qsb"
    done < <(find src -name '*.frag' | sort)
    mv "$LOCK.new" "$LOCK"
    echo "wrote $LOCK (qsb $qsb_version)"
    exit 0
fi

check_tree() {   # check_tree <root> — one verdict line per finding: RULE PASS|FAIL detail
    python3 - "$1" "$qsb" "$qsb_version" "${QSB_FLAGS[@]}" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1]); qsb, qver = sys.argv[2], sys.argv[3]; flags = sys.argv[4:]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def verdict(rule, good, detail=""): print(rule, "PASS" if good else "FAIL", detail)
def reflection(p):
    out = subprocess.run([qsb, "-d", str(p)], capture_output=True, text=True).stdout
    at = out.find("Reflection info:")
    if at < 0: return None
    s = out[out.index("{", at):]
    depth = 0
    for i, ch in enumerate(s):
        depth += ch == "{"; depth -= ch == "}"
        if depth == 0: return json.loads(s[:i + 1])
    return None
def members(refl):
    return [(m["name"], m["type"]) for b in (refl or {}).get("uniformBlocks", []) for m in b["members"]]

lock = {}
lp = root / "tests" / "shaders.lock"
if lp.exists():
    for line in lp.read_text().split("\n"):
        f = line.split()
        if len(f) == 4: lock[f[0]] = f[1:]
frags = sorted(str(p.relative_to(root)) for p in (root / "src").rglob("*.frag"))
verdict("FOUND", len(frags) > 0, "no shaders found under src/ — this check would inspect nothing")
verdict("LOCKED", set(frags) == set(lock), "src has %s, the lock has %s" % (sorted(frags), sorted(lock)))
qml = {str(p.relative_to(root)): p.read_text(errors="replace") for p in (root / "src").rglob("*.qml")}
for frag in frags:
    fp = root / frag; qp = root / (frag + ".qsb")
    if not qp.exists():
        verdict("BUILT:" + frag, False, "no " + frag + ".qsb"); continue
    fsha, lver, qsha = lock.get(frag, ["", "", ""])
    verdict("SOURCE:" + frag, sha(fp) == fsha,
            "the source changed since its .qsb was built: tests/check-shaders.sh --update")
    verdict("PACKAGE:" + frag, sha(qp) == qsha, "the .qsb is not the one the lock records")
    with tempfile.TemporaryDirectory() as td:
        out = pathlib.Path(td) / "rebuilt.qsb"
        r = subprocess.run([qsb] + flags + ["-o", str(out), str(fp)], capture_output=True, text=True)
        if r.returncode != 0:
            verdict("REBUILD:" + frag, False, "qsb failed: " + r.stderr.strip()[:200]); continue
        if qver == lver:
            verdict("REBUILD:" + frag, out.read_bytes() == qp.read_bytes(),
                    "rebuilt with qsb %s, the same version, and the bytes differ" % qver)
        else:
            verdict("REBUILD:" + frag, members(reflection(out)) == members(reflection(qp)),
                    "rebuilt with qsb %s (the lock's is %s) and the uniform block differs" % (qver, lver))
    used = [n for n, _ in members(reflection(qp)) if n not in ("qt_Matrix", "qt_Opacity")]
    base = pathlib.Path(frag).name + ".qsb"
    loaders = [q for q, src in qml.items() if base in src]
    verdict("LOADED:" + frag, len(loaders) > 0, "no QML file loads " + base)
    for q in loaders:
        missing = [n for n in used if not re.search(r'\bproperty\s+[\w.]+\s+' + re.escape(n) + r'\b', qml[q])]
        verdict("UNIFORMS:" + frag, not missing and len(used) > 0,
                "%s does not declare %s" % (q, ", ".join(missing) or "(no uniforms reflected)"))
PY
}

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

echo "── shaders (qsb $qsb_version) ──"
verdicts="$(check_tree .)"
while read -r rule verdict detail; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$rule"; else bad "$rule — $detail"; fi
done <<<"$verdicts"

echo "── self-test: can these checks fail? ──"
MW="$(mktemp -d)"; trap 'rm -rf "$MW"' EXIT INT TERM
mutant() {   # mutant <label> <file> <old> <new> <rule prefix that must FAIL>
    rm -rf "$MW/t"; mkdir -p "$MW/t/tests"; cp -r src "$MW/t/src"; cp "$LOCK" "$MW/t/tests/"
    if ! python3 - "$MW/t/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s: sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
PY
    then bad "self-test $1: the mutation did not apply"; return; fi
    if check_tree "$MW/t" | grep -q "^$5[^ ]* FAIL"; then ok "self-test $1: caught"
    else bad "self-test $1: SURVIVED"; fi
}
mutant "a source edited and not rebuilt" src/shapes/fluid/fluiddrop.frag \
       "h * h * k * 0.25" "h * h * k * 0.5" SOURCE
mutant "a uniform the QML no longer declares" src/shapes/fluid/FluidDrop.qml \
       "property vector4d blends:" "property vector4d blendz:" UNIFORMS
# A package from another source, with the lock rewritten to match it: the
# source and package hashes both agree with the lock, and only the rebuild
# can tell. The lock's qsb version is set to THIS qsb's, so the byte
# comparison runs wherever the check does (CI's qsb need not be the lock's).
rm -rf "$MW/t"; mkdir -p "$MW/t/tests"; cp -r src "$MW/t/src"
sed 's/h \* h \* k \* 0.25/h * h * k * 0.5/' src/shapes/fluid/fluiddrop.frag > "$MW/other.frag"
"$qsb" "${QSB_FLAGS[@]}" -o "$MW/t/src/shapes/fluid/fluiddrop.frag.qsb" "$MW/other.frag" >/dev/null 2>&1
osha="$(sha256sum < "$MW/t/src/shapes/fluid/fluiddrop.frag.qsb" | cut -c1-64)"
awk -v v="$qsb_version" -v o="$osha" '$1=="src/shapes/fluid/fluiddrop.frag"{$3=v; $4=o}1' "$LOCK" > "$MW/t/tests/shaders.lock"
if check_tree "$MW/t" | grep -q "^REBUILD[^ ]* FAIL"; then ok "self-test a package built from other source, lock and all: caught"
else bad "self-test a package built from other source, lock and all: SURVIVED"; fi
mutant "a package the lock does not record" tests/shaders.lock \
       "$(awk '$1=="src/shapes/fluid/fluiddrop.frag"{print $4}' "$LOCK")" \
       "0000000000000000000000000000000000000000000000000000000000000000" PACKAGE
# With the lock claiming another qsb version only the interface can be
# compared — so that path must PASS on the real tree, not fail everything.
rm -rf "$MW/t"; mkdir -p "$MW/t/tests"; cp -r src "$MW/t/src"
awk '{$3="0.0.0"}1' "$LOCK" > "$MW/t/tests/shaders.lock"
if check_tree "$MW/t" | grep -q "^REBUILD[^ ]* PASS"; then
    ok "self-test: under another qsb version the interface is compared, and the real one matches"
else
    bad "self-test: the interface comparison failed on the real tree"
fi
echo
echo "check-shaders: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
