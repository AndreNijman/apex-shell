#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-recovery-a11y.sh — the recovery screen, for a user who cannot see it
#  (roadmap P2-003, the last unaudited accessibility surface in that row).
#
#  ── What it is guarding, measured rather than imagined ──────────────────────
#
#  src/services/config_tab/pages/RecoveryPage.qml had ZERO `Accessible.`
#  anything in 892 lines. Read back over real AT-SPI on 2026-09-19 — nested
#  headless labwc, private session and a11y buses, the shipped shell.qml, Qt's
#  accessibility factory restored in-process by round 30's shim, and an `apex`
#  answering the captured fixtures — the page published its shared Cfg*
#  controls and NOT ONE of its 8 component rows, 6 recovery routes, 7 doctor
#  checks, its headline status line, or a single section title.
#
#  The destructive path was worse than unlabelled. Driving the page the way a
#  reader would, `atspi-walk.py --do-action Open` opened the factory-reset
#  disclosure (the button's name flipped to "Close" on the next dump), and
#  `--do-action "Show what would be lost"` ran the dry run — and the tree came
#  back byte-identical apart from that one word. No loss row, no count, no
#  "NOT backed up" flag, and no `Erase N item(s) now` button, because that
#  button was a bare Rectangle with a MouseArea. A reader could walk three of
#  the four deliberate steps that section is built around and dead-end with no
#  information; a keyboard user could not finish it at all.
#
#  ── Why this file exists next to tests/run-recovery-atspi-shim.sh ───────────
#
#  That suite reads the real bus and is the stronger measurement, and it cannot
#  run on the GitHub Arch runner: quickshell is an AUR package and is not there,
#  so it prints a named SKIP. This one reads the source and runs anywhere, which
#  makes it the half that actually gates a merge. They ask different questions:
#  that one asks "did the markup arrive", this one asks "are the two rules the
#  markup has to follow still followed", and neither rule is visible in a diff.
#
#    1. NO PRIVATE-USE GLYPH MAY CARRY A ROLE OR REACH A NAME. Every icon on
#       this page is a private-use codepoint, and a reader that meets one says
#       "private use character" in front of the words it was meant to read.
#       That is not a guess: this unit measured the identical defect on the
#       installer's Wi-Fi page, where `▁▃▅▇` sat inside an accessible name.
#       The state a glyph encodes is composed IN WORDS instead — stateLabel(),
#       available / not available / cannot be determined, pass / warning —
#       which is also what the eye reads beside it.
#
#    2. NO ROLE WITHOUT AN EXPLICIT NAME. Qt does fall back to an item's `text`
#       property when Accessible.name is unset. The fallback is real and it is
#       silent the day it stops applying, which is the worst combination a
#       dependency can have.
#
#  ── Why the checks are not greps ────────────────────────────────────────────
#
#  A grep for `Accessible.name` over this file is satisfied by the prose block
#  at the foot of it, by this comment, and by markup on a DIFFERENT object in
#  the same Column. So object bodies are extracted by brace depth from a copy
#  with comments and string CONTENTS blanked, a binding counts only when it is
#  a DIRECT child of the object asserted about, and the extractor is self-tested
#  in both directions on canned input at the bottom. An extractor that quietly
#  matched the whole file would make every assertion above it green for nothing,
#  which is the dominant defect family in this repository.
#
#  Two masked copies, not one, and the distinction is load-bearing. Structure is
#  read off the copy with strings blanked, so a brace inside prose or inside a
#  string cannot move an object boundary. VALUES are read off the copy with only
#  comments blanked, so the private-use scan sees the characters that are really
#  in the bindings — and so that a comment under a binding is not swallowed into
#  that binding's value and reported as an unaudited icon.
#
#  PASS = every role on the page is named, no icon carries accessibility markup,
#         no accessible string can contain a private-use codepoint, every list
#         the page renders names its rows, and the one destructive control is
#         reachable by keyboard and by a reader through a single guarded press.
#
#  Run from anywhere: ./tests/check-recovery-a11y.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root" || exit 2

pass=0; fail=0; skip=0
ok()   { echo "  ok   $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL $1${2:+  — $2}"; fail=$((fail + 1)); }
nope() { echo "  SKIP $1${2:+  — $2}"; skip=$((skip + 1)); }
section() { printf '\n── %s ──\n' "$1"; }
totals() {
    printf '\nrecovery-a11y: passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
}

PAGE="src/services/config_tab/pages/RecoveryPage.qml"
[ -f "$PAGE" ] || { echo "FATAL: cannot find $PAGE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/recovery-a11y.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT INT TERM

# ── the extractor ────────────────────────────────────────────────────────────
cat >"$W/facts.py" <<'PYEOF'
import json, re, sys

# All three private-use ranges, written entirely as NUMERIC ESCAPES. The first
# draft of the equivalent class in tests/run-lockscreen-atspi-shim.sh carried
# its BMP bounds as literal characters, they did not survive being written to
# the file, the class silently became "a hyphen plus the two supplementary
# planes", and a mutant carrying a BMP private-use glyph SURVIVED as a result.
# An unprintable character in a source file is not reviewable; an escape is.
PUA = re.compile('[-\U000f0000-\U000ffffd\U00100000-\U0010fffd]')

src = open(sys.argv[1], encoding='utf-8').read()


def mask(s, blank_strings=True):
    """A SAME-LENGTH copy with comments — and optionally string contents — blanked.

    Same length and same line breaks, so every offset found in a masked copy
    indexes the original text unchanged.
    """
    out = list(s)
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            while i < n and s[i] != '\n':
                out[i] = ' '
                i += 1
        elif c == '/' and i + 1 < n and s[i + 1] == '*':
            out[i] = out[i + 1] = ' '
            i += 2
            while i + 1 < n and not (s[i] == '*' and s[i + 1] == '/'):
                if s[i] != '\n':
                    out[i] = ' '
                i += 1
            if i < n:
                out[i] = ' '
            if i + 1 < n:
                out[i + 1] = ' '
            i += 2
        elif c in '"\'':
            q = c
            i += 1
            while i < n and s[i] != q:
                if s[i] == '\\':
                    if blank_strings:
                        out[i] = ' '
                    i += 1
                    if i < n and blank_strings:
                        out[i] = ' '
                    i += 1
                    continue
                if blank_strings and s[i] != '\n':
                    out[i] = ' '
                i += 1
            i += 1
        else:
            i += 1
    return ''.join(out)


M = mask(src)                       # structure
C = mask(src, blank_strings=False)  # values


def line_of(pos):
    return src.count('\n', 0, pos) + 1


def enclosing(pos):
    """(start, end) of the {...} whose DIRECT content contains `pos`."""
    depth, i = 0, pos
    while i >= 0:
        c = M[i]
        if c == '}':
            depth += 1
        elif c == '{':
            if depth == 0:
                break
            depth -= 1
        i -= 1
    if i < 0:
        return None
    d, j = 0, i
    while j < len(M):
        if M[j] == '{':
            d += 1
        elif M[j] == '}':
            d -= 1
            if d == 0:
                return (i, j)
        j += 1
    return None


def direct(body):
    """The body's own content with nested {...} removed, plus an offset map.

    This is what makes "a DIRECT child of this object" checkable. Without it,
    markup on a nested Text would satisfy an assertion about its parent — which
    is the exact shape that made a grep useless here.
    """
    a, b = body
    text, idx, d = [], [], 0
    for k in range(a + 1, b):
        ch = M[k]
        if ch == '{':
            d += 1
            continue
        if ch == '}':
            d -= 1
            continue
        if d == 0:
            text.append(ch)
            idx.append(k)
    return ''.join(text), idx


# A binding STARTS A LINE, or follows a semicolon. Anchoring matters and the
# first draft of this file did not: `([A-Za-z_][\w.]*)\s*:` anywhere matched
# the middle of a ternary, so
#
#     Accessible.name: (lossRow.loss ? lossRow.loss.relative : "")
#                    + (… ? " — NOT backed up" : "")
#
# was truncated at `(lossRow.loss ?` — because `lossRow.loss.relative :` looks
# exactly like the start of the next binding — and the assertion that the
# "NOT backed up" flag is in the NAME went red against markup that had it.
# A checker that cannot read a value it is asserting about is the same family
# as one that inspects nothing; §1 now carries the canned input that proves it.
BIND = re.compile(r'(?m)(?:^[ \t]*|;[ \t]*)([A-Za-z_][\w.]*)[ \t]*:')


def bindings(body):
    """{name: (value_text_from_C, line)} for the body's DIRECT bindings."""
    flat, idx = direct(body)
    hits = list(BIND.finditer(flat))
    out = {}
    for h, nxt in zip(hits, hits[1:] + [None]):
        name = h.group(1)
        vs = h.end()
        ve = nxt.start() if nxt else len(flat)
        if vs >= len(idx):
            continue
        real_start = idx[vs]
        # Read the value out of C (comments blanked, strings intact) at the
        # SAME offsets, so the private-use scan sees the characters that are
        # really in the binding.
        val = ''.join(C[idx[k]] for k in range(vs, min(ve, len(idx))))
        out[name] = (val, line_of(real_start))
    return out


# Every object body that carries at least one Accessible.* binding, or an id.
objects = {}
for m in re.finditer(r'\bAccessible\.[A-Za-z]+\s*:|(?<![\w.])id\s*:\s*([A-Za-z_]\w*)', M):
    body = enclosing(m.start())
    if body is None:
        continue
    objects[body] = None

facts = {"objects": [], "roles": [], "pua": [], "icons_with_a11y": []}

for body in sorted(objects):
    b = bindings(body)
    oid = None
    if 'id' in b:
        mm = re.match(r'\s*([A-Za-z_]\w*)', b['id'][0])
        oid = mm.group(1) if mm else None
    acc = {k: v for k, v in b.items() if k.startswith('Accessible.')}
    textval = b.get('text', ('', 0))[0]
    entry = {
        "id": oid,
        "line": line_of(body[0]),
        "accessible": {k: v[0].strip() for k, v in acc.items()},
        "has_text": 'text' in b,
        "text_has_pua": bool(PUA.search(textval)),
        "keys_onpressed": 'Keys.onPressed' in b,
        "activeFocusOnTab": b.get('activeFocusOnTab', ('', 0))[0].strip(),
    }
    facts["objects"].append(entry)

    if 'Accessible.role' in acc:
        facts["roles"].append({
            "id": oid,
            "line": line_of(body[0]),
            "role": acc['Accessible.role'][0].strip(),
            "named": 'Accessible.name' in acc,
        })
    for k, (v, ln) in acc.items():
        if PUA.search(v):
            facts["pua"].append({"binding": k, "line": ln,
                                 "codepoints": [hex(ord(ch)) for ch in v if PUA.match(ch)]})
    if entry["text_has_pua"] and acc:
        facts["icons_with_a11y"].append({"line": entry["line"],
                                         "bindings": sorted(acc)})

# The whole-file private-use inventory, so "how many icons are on this page"
# is a number that can move rather than a claim.
facts["pua_chars_in_file"] = len(PUA.findall(C))

print(json.dumps(facts))
PYEOF

run_facts() { python3 "$W/facts.py" "$1"; }

FACTS="$W/facts.json"
if ! run_facts "$PAGE" >"$FACTS" 2>"$W/facts.err"; then
    echo "FATAL: the extractor could not read $PAGE" >&2
    sed 's/^/      /' "$W/facts.err" >&2
    exit 2
fi

q() { python3 -c "
import json,sys
f=json.load(open('$FACTS'))
$1
"; }

# ─────────────────────────────────────────────────────────────────────────────
section "§1 the extractor is exercised BEFORE anything is read through it"
# ─────────────────────────────────────────────────────────────────────────────
#
# Six canned inputs, three of which must come back NEGATIVE. A checker whose
# instrument says yes to everything is a gate that inspects nothing, and this
# repository has shipped that five times.

# The canned QML is written by PYTHON, not by the shell, and `@PUA@` is
# substituted for U+F033E on the way. Measured 2026-09-19 and it is not a
# style preference: under a C/POSIX locale — which is what `env -i` gives, and
# what the CI container gives — bash's `printf '\U000f033e'` emits the ten
# ASCII bytes `\U000F033E` instead of the character. A private-use self-test
# built that way is a string of plain letters that the private-use class
# cannot match, so it reports "not caught" on exactly the machines that matter
# and passes on a developer's UTF-8 desk. That is the THIRD way this unit has
# lost one of these characters in transit; see FOUND 23 for the other two.
selftest() {   # <name> <qml, with @PUA@ where a private-use glyph goes> <expr> <want>
    local name="$1" qml="$2" expr="$3" want="$4"
    python3 -c '
import sys
open(sys.argv[1], "w", encoding="utf-8").write(
    sys.argv[2].replace("@PUA@", "\U000f033e"))
' "$W/t.qml" "$qml"
    local got
    if ! got="$(python3 "$W/facts.py" "$W/t.qml" 2>"$W/t.err")"; then
        bad "self-test: $name" "the extractor crashed: $(head -1 "$W/t.err")"
        return
    fi
    printf '%s' "$got" >"$W/t.json"
    local ans
    ans="$(python3 -c "
import json
f=json.load(open('$W/t.json'))
print($expr)
")"
    if [ "$ans" = "$want" ]; then
        ok "self-test: $name"
    else
        bad "self-test: $name" "expected $want, got $ans"
    fi
}

selftest "a role with a name is reported as named" \
'import QtQuick
Item { Text { Accessible.role: Accessible.StaticText; Accessible.name: "hello" } }' \
'len([r for r in f["roles"] if r["named"]])' 1

selftest "a role with NO name is reported as unnamed — the check can answer no" \
'import QtQuick
Item { Text { Accessible.role: Accessible.StaticText } }' \
'len([r for r in f["roles"] if r["named"]])' 0

# The defect a grep has. The name is on a DIFFERENT object inside the same
# parent, and a file-wide search would call the parent named.
selftest "a name on a SIBLING does not name the object that lacks one" \
'import QtQuick
Item {
    Text { id: a; Accessible.role: Accessible.StaticText }
    Text { id: b; Accessible.name: "hello" }
}' \
'len([r for r in f["roles"] if r["named"]])' 0

# Prose must not turn it red OR green. This input quotes the rule it breaks.
selftest "a COMMENT quoting the markup satisfies nothing" \
'import QtQuick
// Accessible.role: Accessible.Button and Accessible.name: "Erase" go here.
Item { Text { text: "x" } }' \
'len(f["roles"])' 0

# The canned input for the defect above. Without it this file would ship a
# value reader that stops at the first ternary and nothing would say so.
selftest "a value containing a ternary is captured WHOLE, not truncated at its colon" \
'import QtQuick
Item {
    Text {
        Accessible.role: Accessible.StaticText
        Accessible.name: (a ? a.relative : "")
            + (a && !a.backedUp ? " — NOT backed up" : "")
    }
}' \
'int("NOT backed up" in [x["accessible"].get("Accessible.name","") for x in f["objects"]][0])' 1

selftest "a private-use codepoint inside an accessible string is caught" \
'import QtQuick
Item { Text { Accessible.role: Accessible.StaticText; Accessible.name: "@PUA@ok" } }' \
'len(f["pua"])' 1

selftest "…and an icon with no markup at all is NOT reported" \
'import QtQuick
Item { Text { text: "@PUA@" } }' \
'len(f["icons_with_a11y"]) + len(f["pua"])' 0

# The substitution itself, because a @PUA@ that silently did not expand would
# make the two rows above pass for the wrong reason — they would be asserting
# about the five ASCII characters "@PUA@".
selftest "and the canned glyph really is one character, not the text of its escape" \
'import QtQuick
Item { Text { text: "@PUA@" } }' \
'int(f["pua_chars_in_file"] == 1)' 1

# ─────────────────────────────────────────────────────────────────────────────
section "§2 rule 1 — no glyph carries accessibility markup, no name hides one"
# ─────────────────────────────────────────────────────────────────────────────

pua_n="$(q 'print(len(f["pua"]))')"
if [ "$pua_n" = "0" ]; then
    ok "no Accessible.* binding on this page contains a private-use codepoint"
else
    bad "no Accessible.* binding on this page contains a private-use codepoint" \
        "$pua_n binding(s) do: $(q 'print("; ".join("%s at line %d %s" % (p["binding"], p["line"], p["codepoints"]) for p in f["pua"]))')"
fi

icon_n="$(q 'print(len(f["icons_with_a11y"]))')"
if [ "$icon_n" = "0" ]; then
    ok "no object whose text IS a glyph carries any Accessible.* binding"
else
    bad "no object whose text IS a glyph carries any Accessible.* binding" \
        "$icon_n does: $(q 'print("; ".join("line %d: %s" % (i["line"], ",".join(i["bindings"])) for i in f["icons_with_a11y"]))')"
fi

# The page really is full of them, so the two rows above are about something.
# Without this, deleting every icon from the page would make them vacuously
# true and nothing would say so.
glyphs="$(q 'print(f["pua_chars_in_file"])')"
if [ "$glyphs" -ge 8 ]; then
    ok "and there are $glyphs private-use codepoints on this page for those rules to be about"
else
    bad "and there are private-use codepoints on this page for those rules to be about" \
        "only $glyphs found; either the icons went away — in which case say so deliberately — or the scan stopped seeing them and the two rows above are vacuous"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§3 rule 2 — every role is explicitly named"
# ─────────────────────────────────────────────────────────────────────────────

roles_n="$(q 'print(len(f["roles"]))')"
unnamed="$(q 'print(len([r for r in f["roles"] if not r["named"]]))')"
if [ "$unnamed" = "0" ]; then
    ok "all $roles_n Accessible.role bindings on this page carry an explicit Accessible.name"
else
    bad "all Accessible.role bindings on this page carry an explicit Accessible.name" \
        "$unnamed do not: $(q 'print("; ".join("line %d (%s)" % (r["line"], r["id"] or "no id") for r in f["roles"] if not r["named"]))'). Qt falls back to the item text, and that fallback is silent the day it stops applying."
fi

# A ratchet, not a floor plucked out of the air: 20 is what the page carried
# when the runtime read-back measured 1 -> 90 nodes on the bus. Deleting markup
# has to be a deliberate act that moves this number.
if [ "$roles_n" -ge 19 ]; then
    ok "the page still declares $roles_n roles (ratchet: 19, the count that produced 90 nodes on the bus)"
else
    bad "the page still declares at least 19 roles" \
        "only $roles_n. Markup was removed; if that was deliberate, re-measure the tree and move the ratchet with it."
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§4 every list the page renders names its rows"
# ─────────────────────────────────────────────────────────────────────────────
#
# One row per Repeater delegate, by the id the delegate declares. Keyed on the
# id rather than on position, because a check that counted "six roles somewhere"
# would stay green after the loss list lost its markup and the doctor grew two.

for pair in \
    "compRow|the 8 component rows" \
    "stepRow|the repair steps" \
    "routeRow|the 6 recovery routes" \
    "checkRow|the doctor's checks" \
    "lossRow|the LOSS LIST — what a factory reset would erase" \
    "preservedRow|the preserved list"
do
    id="${pair%%|*}"; what="${pair#*|}"
    got="$(q "
o=[x for x in f['objects'] if x['id']=='$id']
if not o: print('NOSUCH')
else:
    a=o[0]['accessible']
    print('OK' if ('Accessible.role' in a and 'Accessible.name' in a) else 'BARE')
")"
    case "$got" in
        OK)     ok "$what are named on the bus ($id)" ;;
        BARE)   bad "$what are named on the bus ($id)" "the delegate has no role and name of its own, so a reader gets its Texts as unrelated labels or nothing at all" ;;
        *)      bad "$what are named on the bus ($id)" "there is no object with id $id on this page any more; if the list was renamed, rename it here too — this row is not allowed to quietly stop measuring" ;;
    esac
done

# The one row property a reader must not be able to skim past. The cache is the
# single target a factory reset does NOT copy aside first, and "NOT backed up"
# sitting only in the description is a sentence a reader can move off before
# reaching.
lossname="$(q "
o=[x for x in f['objects'] if x['id']=='lossRow']
print(o[0]['accessible'].get('Accessible.name','') if o else '')
")"
case "$lossname" in
    *"NOT backed up"*) ok "a loss row that is not backed up says so in its NAME, not only its description" ;;
    *)  bad "a loss row that is not backed up says so in its NAME, not only its description" \
            "got: ${lossname:-<no name binding>}" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
section "§5 the one destructive control, and the gate it must not become a way around"
# ─────────────────────────────────────────────────────────────────────────────

commit_get() { q "
o=[x for x in f['objects'] if x['id']=='commitBtn']
print(('NOSUCH' if not o else str(o[0]$1)))
"; }

if [ "$(commit_get "['id']")" = "NOSUCH" ]; then
    bad "the commit button exists as an object this suite can audit (id: commitBtn)" \
        "no object with that id; every assertion in this section would otherwise be vacuous"
else
    ok "the commit button exists as an object this suite can audit (id: commitBtn)"

    role="$(commit_get "['accessible'].get('Accessible.role','')")"
    case "$role" in
        *Accessible.Button*) ok "it declares itself a button, so a reader announces a button and not an unnamed panel" ;;
        *)  bad "it declares itself a button" "got '${role:-<none>}'; before round 31 it was a bare Rectangle with a MouseArea and did not reach the bus at all" ;;
    esac

    nm="$(commit_get "['accessible'].get('Accessible.name','')")"
    [ -n "$nm" ] && ok "…and it is named" \
        || bad "…and it is named" "no Accessible.name; an unnamed button is one a reader cannot tell from any other"

    de="$(commit_get "['accessible'].get('Accessible.description','')")"
    case "$de" in
        *"cannot be undone"*) ok "…and its description says the thing a reader most needs before pressing it" ;;
        *)  bad "…and its description says the thing a reader most needs before pressing it" \
                "expected the words 'cannot be undone'; got '${de:-<none>}'" ;;
    esac

    pa="$(commit_get "['accessible'].get('Accessible.onPressAction','')")"
    case "$pa" in
        *"press()"*) ok "a reader presses it through the SAME press() a pointer does" ;;
        *)  bad "a reader presses it through the SAME press() a pointer does" \
                "onPressAction is '${pa:-<none>}'. Two paths to a destructive verb is two places for the guard to be missing from." ;;
    esac

    if [ "$(commit_get "['keys_onpressed']")" = "True" ]; then
        ok "and a keyboard can press it — Keys.onPressed is declared on the button itself"
    else
        bad "and a keyboard can press it" \
            "no Keys.onPressed. Every safe control on this page is a CfgButton with Space and Return; this one is the only thing standing between a keyboard user and finishing the reset they started."
    fi

    aft="$(commit_get "['activeFocusOnTab']")"
    case "$aft" in
        *commitReady*) ok "its tab stop exists only while the button does (activeFocusOnTab is bound to commitReady)" ;;
        *true*) bad "its tab stop exists only while the button does" \
                    "activeFocusOnTab is a literal true. FOUND 16: an invisible Qt Quick item still publishes to the bus, so this puts a permanent tab stop and a permanent Press action on the most destructive control in the product, at a place the user cannot see." ;;
        *)  bad "its tab stop exists only while the button does" \
                "activeFocusOnTab is '${aft:-<unset>}'; a button with no tab stop cannot be reached by keyboard at all" ;;
    esac
fi

# The gate itself. Exposing the button is only defensible because the refusal
# lives in the SERVICE and not in the button's visibility, so that is asserted
# here rather than trusted — in the service's own file, which this page cannot
# change from its side.
SVC="src/services/RecoveryService.qml"
if [ ! -f "$SVC" ]; then
    nope "the service refuses a commit that the rendered list does not cover" \
         "cannot find $SVC"
else
    svc_body="$(python3 - "$SVC" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'function\s+commitReset\s*\(\s*\)\s*\{', s)
if not m:
    print("NOFN"); raise SystemExit
i = m.end() - 1
d = 0
for j in range(i, len(s)):
    if s[j] == '{': d += 1
    elif s[j] == '}':
        d -= 1
        if d == 0:
            print(s[i:j + 1]); raise SystemExit
print("NOFN")
PY
)"
    if [ "$svc_body" = "NOFN" ]; then
        bad "the service refuses a commit that the rendered list does not cover" \
            "there is no commitReset() in $SVC to read"
    else
        miss=""
        case "$svc_body" in *'resetPhase !== "planned"'*) : ;; *) miss="$miss phase-guard" ;; esac
        case "$svc_body" in *'_ackToken'*)   : ;; *) miss="$miss ack-token" ;; esac
        case "$svc_body" in *'_ackCount'*)   : ;; *) miss="$miss ack-count" ;; esac
        case "$svc_body" in *'Refusing'*)    : ;; *) miss="$miss refusal-message" ;; esac
        if [ -z "$miss" ]; then
            ok "the service refuses a commit the rendered list does not cover — the guard is NOT the button's visibility"
        else
            bad "the service refuses a commit the rendered list does not cover" \
                "commitReset() is missing:$miss. Until round 31 that guard was only ever reached by a mouse; it is now reachable over the accessibility bus, so it has to be real."
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§6 the structure the page's rows hang off, which is not in this file"
# ─────────────────────────────────────────────────────────────────────────────
#
# Added because a mutant SURVIVED. Deleting CfgSection's Grouping role left
# every assertion above green — they are all about RecoveryPage.qml — while the
# measured consequence is that the page's rows stop being children of anything
# and a reader gets them as a flat run of labels mixed in with whatever other
# Config pages the Nexus window has instantiated. The page is audited; the thing
# that gives its rows a parent was not.
#
# QAccessibleQuickItem::childItems() skips items that are not accessible, so
# marking the section IS the structure. There is nothing in RecoveryPage.qml
# that can go red when it goes away.

SECT="src/components/config/CfgSection.qml"
if [ ! -f "$SECT" ]; then
    bad "the sections this page is built from reach the bus as named groups" \
        "cannot find $SECT"
else
    if ! run_facts "$SECT" >"$W/section.json" 2>"$W/section.err"; then
        bad "the sections this page is built from reach the bus as named groups" \
            "the extractor could not read $SECT: $(head -1 "$W/section.err")"
    else
        sect_role="$(python3 -c "
import json
f=json.load(open('$W/section.json'))
o=[x for x in f['objects'] if 'Accessible.role' in x['accessible']]
print(o[0]['accessible']['Accessible.role'].strip() if o else '')
")"
        sect_name="$(python3 -c "
import json
f=json.load(open('$W/section.json'))
o=[x for x in f['objects'] if 'Accessible.name' in x['accessible']]
print(o[0]['accessible']['Accessible.name'].strip() if o else '')
")"
        case "$sect_role" in
            *Accessible.Grouping*)
                ok "a settings section is a GROUP, so this page's rows have a parent on the bus" ;;
            *)  bad "a settings section is a GROUP, so this page's rows have a parent on the bus" \
                    "CfgSection declares role '${sect_role:-<none>}'. Measured: without it the Nexus window publishes one flat run of controls with several pages mixed together and nothing saying which page is open." ;;
        esac
        case "$sect_name" in
            *root.title*)
                ok "…and the group is named by its title, so the words are not said twice" ;;
            *)  bad "…and the group is named by its title" \
                    "got '${sect_name:-<none>}'; an unnamed group is a level of nesting a reader has to walk past for nothing" ;;
        esac
    fi
fi

# And that this page really is built out of them, so the two rows above are
# about something. Eight sections: header, components, repair, rollback,
# routes, diagnostics, factory reset, elsewhere.
sect_n="$(grep -c '^    CfgSection {' "$PAGE")"
if [ "$sect_n" -ge 8 ]; then
    ok "the page is built from $sect_n CfgSections, so the grouping above applies to it"
else
    bad "the page is built from at least 8 CfgSections" \
        "found $sect_n; either the page was restructured — in which case the rows above stopped being about it — or the count moved and nobody said so"
fi

echo
echo "  This suite reads the source. What arrived on the real bus is"
echo "  tests/run-recovery-atspi-shim.sh, which needs quickshell and a"
echo "  compositor and therefore skips on the Arch runner."

totals
[ "$fail" -eq 0 ] || exit 1
exit 0
