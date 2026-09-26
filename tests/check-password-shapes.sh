#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-password-shapes.sh — the lock screen's password shapes show how many
#  characters were typed, and are structurally unable to show which.
#
#  src/components/auth/PasswordShapes.qml draws one geometric shape per
#  character in place of bullet dots, on the lock screen here and on the login
#  screen (apex-greet loads this same file from /usr/share/apex-shell). A
#  decoration next to a password field is the easiest place to leak one, so
#  the properties that make it safe are asserted rather than trusted:
#
#   1. The component's inputs are a fixed list, and the only one about the
#      secret is `length`, an int. No string or var input exists that a caller
#      could hand the text to (`text` is a colour — the palette's text colour —
#      and `speed` is a motion preset name), and the file refers to no field.
#   2. The lock screen hands it `passwordInput.length` and nothing else of the
#      field's.
#   3. The field itself is still a masked password field: echoMode Password,
#      passwordMaskDelay 0 (no character ever drawn, even for a frame),
#      Accessible.passwordEdit true.
#   4. The placeholder waits for the shapes to have left (`shapes.empty`).
#   5. A refused attempt clears the FIELD, and does so before hasError is set —
#      clearing runs onTextChanged, which drops the error.
#
#  Each rule is mutated on a copy to prove it can fail (repo idiom: a mutant
#  that did not apply is reported as such, never as caught).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

check_tree() {   # check_tree <root> — prints one verdict line per rule: RULE PASS|FAIL detail
    python3 - "$1" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
comp = (root / "src/components/auth/PasswordShapes.qml").read_text()
lock = (root / "src/windows/Lockscreen.qml").read_text()

def code(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return "\n".join(l.split("//", 1)[0] for l in s.split("\n"))

c = code(comp)
# 1. the public, writable API
ALLOWED = {("int", "length"), ("color", "accent"), ("color", "text"), ("color", "background"),
           ("color", "danger"), ("bool", "error"), ("bool", "busy"), ("string", "speed"),
           ("real", "motionScale"), ("bool", "reduced"), ("int", "size"), ("int", "gap"),
           ("int", "maxShapes")}
top = c.split("Repeater", 1)[0]
decl = set()
for m in re.finditer(r'^\s{4}property\s+(\w+)\s+(\w+)\s*:', top, re.M):
    if not m.group(2).startswith("_"):
        decl.add((m.group(1), m.group(2)))
extra = decl - ALLOWED
missing = {("int", "length")} - decl
print("API", "PASS" if not extra and not missing else "FAIL",
      "extra=" + ",".join("%s %s" % e for e in sorted(extra)) + " missing=" + ",".join(n for _, n in missing))
refs = re.findall(r'\b(passwordInput|displayText|TextInput|password)\b', c)
print("NOREF", "PASS" if not refs else "FAIL", ",".join(sorted(set(refs))))

# 2. the lock screen's instance
lc = code(lock)
m = re.search(r'PasswordShapes\s*\{(.*?)\n\s{20}\}', lc, re.S)
if not m:
    print("HANDOFF FAIL no PasswordShapes block in Lockscreen.qml")
else:
    body = m.group(1)
    uses = re.findall(r'passwordInput\.(\w+)', body)
    ok = uses and set(uses) <= {"length"} and re.search(r'^\s*length:\s*passwordInput\.length\s*$', body, re.M)
    print("HANDOFF", "PASS" if ok else "FAIL", "passwordInput." + ",passwordInput.".join(uses))

# 3. the field is still a masked password field
fm = re.search(r'TextInput\s*\{\s*id:\s*passwordInput(.*?)\n\s{20}\}', lc, re.S)
f = fm.group(1) if fm else ""
masked = (re.search(r'echoMode:\s*TextInput\.Password\b', f)
          and re.search(r'passwordMaskDelay:\s*0\b', f)
          and re.search(r'Accessible\.passwordEdit:\s*true\b', f))
print("MASKED", "PASS" if masked else "FAIL", "")

# 4. placeholder waits for the shapes
print("PLACEHOLDER", "PASS" if re.search(r'visible:\s*shapes\.empty\b', lc) else "FAIL", "")

# 5. refused attempt: field cleared, before hasError
fn = re.search(r'function fail\(msg\)\s*\{(.*?)\n\s{8}\}', lc, re.S)
body = fn.group(1) if fn else ""
i_clear = body.find('passwordInput.text = ""')
i_err = body.find('surface.hasError  = true')
if i_err < 0: i_err = body.find('surface.hasError = true')
print("CLEAR", "PASS" if 0 <= i_clear < i_err else "FAIL", "clear@%d err@%d" % (i_clear, i_err))
PY
}

verdicts="$(check_tree .)"
label() {
    case "$1" in
        API)         echo "the component's inputs are the fixed list; the only one about the secret is an int length" ;;
        NOREF)       echo "the component refers to no field and no password" ;;
        HANDOFF)     echo "the lock screen hands it passwordInput.length and nothing else of the field's" ;;
        MASKED)      echo "the field is still echoMode Password, mask delay 0, passwordEdit" ;;
        PLACEHOLDER) echo "the placeholder waits for the shapes to have left" ;;
        CLEAR)       echo "a refused attempt clears the field before the error is set" ;;
    esac
}
while read -r rule verdict detail; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$(label "$rule")"
    else bad "$(label "$rule")  [$detail]"; fi
done <<<"$verdicts"
[ "$(grep -c . <<<"$verdicts")" -eq 6 ] && ok "all six rules were evaluated" \
    || bad "expected six verdicts, got: $verdicts"

# ── self-test ────────────────────────────────────────────────────────────────
MW="$(mktemp -d)"; trap 'rm -rf "$MW"' EXIT INT TERM
mutant() {   # mutant <label> <file> <python replace old> <new> <rule that must fail>
    rm -rf "$MW/t"; mkdir -p "$MW/t/src"; cp -r src/components src/windows src/theme "$MW/t/src/"
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
mutant "a string input that could carry the text" src/components/auth/PasswordShapes.qml \
    'property int length: 0' 'property int length: 0
    property string secret: ""' API
mutant "the component reaching for the field" src/components/auth/PasswordShapes.qml \
    'onLengthChanged: root._sync()' 'onLengthChanged: { root._sync(); console.log(passwordInput) }' NOREF
mutant "the screen handing over the text" src/windows/Lockscreen.qml \
    'length:              passwordInput.length' 'length:              passwordInput.text.length' HANDOFF
mutant "an echo delay on the field" src/windows/Lockscreen.qml \
    'passwordMaskDelay:       0' 'passwordMaskDelay:       900' MASKED
mutant "a placeholder that draws over leaving shapes" src/windows/Lockscreen.qml \
    'visible: shapes.empty && !surface.checking' 'visible: passwordInput.text.length === 0 && !surface.checking' PLACEHOLDER
mutant "a refused attempt that keeps the old text" src/windows/Lockscreen.qml \
    'passwordInput.text = ""
            surface.password  = ""' 'surface.password  = ""' CLEAR

printf '\ncheck-password-shapes: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
