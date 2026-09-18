#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-lockscreen-a11y.sh — the lock screen, for a user who cannot see it
#  (roadmap P2-003).
#
#  ── Why this exists ─────────────────────────────────────────────────────────
#
#  The LOGIN screen is done three ways: tests/test-apex-greet-atspi.sh reads the
#  greeter back over real AT-SPI, test-apex-greet-session-bus.sh proves there is
#  a bus for it to publish on, and test-apex-greet-a11y.sh covers the config.
#  The LOCK screen — the same act, by a user who is already logged in — had
#  nothing. src/windows/Lockscreen.qml was 440 lines with zero `Accessible.`
#  anything in it, and the whole file is the one surface between a user and
#  their own machine.
#
#  What that cost a screen-reader user, read off the source before this file
#  existed:
#
#    * the password field announced nothing at all — no name, no role, and no
#      `passwordEdit`, so nothing told an assistive technology to stop echoing
#      what was typed into a password box;
#    * a wrong password was reported by a red border, a shake animation and a
#      line of text with no accessible role. All three are things you have to be
#      looking at. A blind user typed a password, heard silence, and had no way
#      to tell a rejected password from a key that did not register. An
#      `Accessible.description` does not fix that on its own: a reader does not
#      generally speak a description change on the object that already holds
#      focus, so the refusal has to be ANNOUNCED. That is what the surface's
#      say() helper and Qt 6.8's Accessible.announce() are for, and this suite
#      both asserts the calls and RUNS a probe proving the method exists on the
#      Qt that will execute them;
#    * Caps Lock being on was reported the same way, which is the single most
#      common reason a correct password is rejected;
#    * the two nerd-font icons in the file (the padlock at the left of the
#      field, and the one in front of the Caps Lock warning) are private-use
#      codepoints. A reader that reaches one says "private use character
#      F033E", or its font's name for it, in front of the words.
#
#  That last one is not a guess about screen readers. It is the identical defect
#  this unit already measured and fixed on the installer's Wi-Fi page, where the
#  signal strength was drawn as `▁▃▅▇` inside the accessible name and a reader
#  spelled out four block characters before every network name.
#
#  ── What it claims, and what it does not ────────────────────────────────────
#
#  It reads the source. It asserts that the markup is there, that it is on the
#  right object, and that it cannot leak the password. The one thing it RUNS is
#  the Qt-version probe described above, because a call to a method this Qt does
#  not have is a runtime error on the lock screen dressed up as a green check.
#  It does NOT run the lock screen itself and read the tree back over AT-SPI,
#  and the suite says so rather than implying otherwise.
#
#  That runtime half is real work and it is named rather than faked: the surface
#  is a `WlSessionLock`, so it needs a compositor implementing ext-session-lock,
#  a private session bus with at-spi-bus-launcher exec'd into it (D-Bus
#  activation of org.a11y.Registry is refused by SELinux on APEX — see
#  tests/lib/atspi.sh in apex-os), and `LockState.locked` flipped against THAT
#  instance and never the developer's. Locking the screen of the machine running
#  the suite is not an acceptable test.
#
#  What IS established, measured on a booted APEX desktop rather than assumed,
#  is that the markup has somewhere to go: org.a11y.Status IsEnabled and
#  ScreenReaderEnabled are both true in a stock session, and `quickshell` is one
#  of the five applications on the a11y bus. The shell already publishes a tree.
#  Until this file, the lock surface contributed nothing to it.
#
#  ── Why the checks are not greps ────────────────────────────────────────────
#
#  Because a grep for `Accessible.name` over this file is satisfied by a comment
#  about accessibility, by markup on the clock, and — the one that actually
#  matters — by markup on the placeholder `Text` NESTED INSIDE the password
#  field, which is a different object and announces a different thing. So the
#  object bodies are extracted by brace depth from a copy of the source with
#  comments and string contents blanked out, and a binding only counts when it
#  is a DIRECT child of the object being asserted about. The six self-tests at
#  the bottom prove the extractor can tell those apart, because an extractor
#  that quietly matched the whole file would make every assertion here green for
#  nothing. Two of those six exist because the first draft of this file HAD the
#  defect they now foreclose, found by RUNNING the suite rather than by reading
#  it: the icon scan read one line at a time and so saw one of this file's two
#  icons, and the keyboard-route check counted focus grabs without asking
#  whether a pointer caused them.
#
#  Run from the repository root.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0; skip=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1${2:+  — $2}"; fail=$((fail + 1)); }
# A SKIP is a could-not-run, never a pass. It is counted separately and printed
# on the totals line, because every suite in this tree exits 0 on a skip and the
# only honest way to read one is the totals, not the tick.
nope() { echo "  SKIP $1${2:+  — $2}"; skip=$((skip + 1)); }
section() { printf '\n── %s ──\n' "$1"; }

LOCK="src/windows/Lockscreen.qml"
[ -f "$LOCK" ] || { echo "FATAL: cannot find $LOCK" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/lockscreen-a11y.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT INT TERM

# ── The extractor ────────────────────────────────────────────────────────────
#
# Prints KEY=VALUE facts about one QML file. Structure is read off a masked copy
# (comments and string CONTENTS blanked, length and line breaks preserved) so a
# brace inside prose or inside a string cannot move an object boundary; values
# are then read out of the original text at the same offsets.
cat >"$W/facts.py" <<'PYEOF'
import json, re, sys

# Both private-use planes. The shell's icons are supplementary PUA-A (the
# padlock is U+F033E); BMP PUA is included because a future icon font may use
# it and the rule is about the class, not about two codepoints.
PUA = re.compile('[-\U000f0000-\U000ffffd\U00100000-\U0010fffd]')

src = open(sys.argv[1], encoding='utf-8').read()


def mask(s):
    """A same-length copy with comment and string CONTENT replaced by spaces."""
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
                    out[i] = ' '
                    i += 1
                    if i < n:
                        out[i] = ' '
                        i += 1
                    continue
                if s[i] != '\n':
                    out[i] = ' '
                i += 1
            i += 1
        else:
            i += 1
    return ''.join(out)


M = mask(src)


def enclosing(pos):
    """(start, end) of the {...} whose direct content contains `pos`."""
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
    depth, j = 0, i
    while j < len(M):
        if M[j] == '{':
            depth += 1
        elif M[j] == '}':
            depth -= 1
            if depth == 0:
                return (i, j)
        j += 1
    return None


def direct(start, end):
    """The body's text at nesting depth 0 — nested objects blanked out."""
    out, depth = [], 0
    for k in range(start + 1, end):
        c = M[k]
        if c == '{':
            depth += 1
            continue
        if c == '}':
            depth -= 1
            continue
        out.append(src[k] if depth == 0 else ('\n' if src[k] == '\n' else ' '))
    return ''.join(out)


def type_of(start):
    """The type name written immediately before the `{` at `start`.

    `MouseArea {` -> 'MouseArea'. Used to tell a focus grab a pointer causes
    from one a keyboard user can reach; an object with no type name before its
    brace (a JS block, a signal handler's body) returns ''."""
    i = start - 1
    while i >= 0 and M[i] in ' \t\n':
        i -= 1
    j = i
    while j >= 0 and (M[j].isalnum() or M[j] in '_.'):
        j -= 1
    return M[j + 1:i + 1]


BIND = re.compile(r'^\s*((?:readonly\s+property\s+\w+\s+)?[A-Za-z_][\w.]*)\s*:\s*(.*)$')


def bindings(text):
    """name -> value, with multi-line values (ternaries) accumulated.

    A value continues onto the next line while that line does not itself open a
    new binding and is not blank. Proved by self-test 3, because a value that
    stopped at the first newline would make the Caps Lock assertion below green
    against a description that only mentions the error."""
    got, lines = {}, text.split('\n')
    i = 0
    while i < len(lines):
        m = BIND.match(lines[i])
        if not m:
            i += 1
            continue
        key = m.group(1).split()[-1] if ' ' in m.group(1) else m.group(1)
        val = [m.group(2)]
        j = i + 1
        while j < len(lines):
            nxt = lines[j]
            if not nxt.strip() or BIND.match(nxt):
                break
            val.append(nxt.strip())
            j += 1
        got.setdefault(key, ' '.join(v.strip() for v in val).strip())
        i = j
    return got


def body_of(ident):
    m = re.search(r'\bid\s*:\s*%s\b' % re.escape(ident), M)
    if not m:
        return None
    return enclosing(m.start())


def emit(k, v):
    print('%s=%s' % (k, v))


# ── the password field ───────────────────────────────────────────────────────
b = body_of('passwordInput')
if b is None:
    emit('PW_FOUND', 0)
    sys.exit(0)
emit('PW_FOUND', 1)
pw_direct = direct(*b)
pw_all = src[b[0]:b[1]]
emit('PW_BODY_CHARS', len(pw_all))
emit('PW_FILE_CHARS', len(src))
# The anchor the whole file rests on. If this ever stops being a password box,
# every assertion below is about the wrong object.
emit('PW_IS_PASSWORD_ECHO', 1 if re.search(r'echoMode\s*:\s*TextInput\.Password', pw_direct) else 0)

pb = bindings(pw_direct)
for prop, key in (('Accessible.role', 'PW_ROLE'),
                  ('Accessible.passwordEdit', 'PW_PASSWORDEDIT'),
                  ('Accessible.name', 'PW_NAME'),
                  ('Accessible.description', 'PW_DESC')):
    emit(key, pb.get(prop, ''))

# One level of local indirection resolved, the way check-reduce-motion.sh
# resolves `duration: root.animDuration`: a description bound to a readonly
# string property in the same body is the readable way to write four states, and
# a checker that could not see through it would force the markup to be ugly.
desc = pb.get('Accessible.description', '')
resolved = desc
m = re.match(r'^(?:\w+\.)?(\w+)$', desc.strip())
if m and m.group(1) in pb:
    resolved = pb[m.group(1)]
emit('PW_DESC_RESOLVED_CHARS', len(resolved))
for token, key in (('hasError', 'PW_DESC_HAS_ERROR'),
                   ('capsOn', 'PW_DESC_HAS_CAPS'),
                   ('checking', 'PW_DESC_HAS_CHECKING')):
    emit(key, 1 if token in resolved else 0)

# ── the password must never cross the bus ────────────────────────────────────
# test-apex-greet-atspi.sh asserts exactly this about the greeter. The same
# property has to hold here, and it is easier to break here: `Accessible.name:
# text` inside a TextInput is a one-word mistake.
leaks = 0
for name, val in bindings(direct(*b)).items():
    if not name.startswith('Accessible.'):
        continue
    if re.search(r'\b(?:passwordInput\.)?(?:displayText)\b', val) or \
       re.search(r'\bsurface\.password\b', val) or \
       re.match(r'^text$', val.strip()) or \
       re.search(r'\bpasswordInput\.text\b', val):
        leaks += 1
emit('PW_SECRET_LEAKS', leaks)

# ── private-use glyphs ───────────────────────────────────────────────────────
# Every Accessible.* binding in the WHOLE file, not just the field's.
acc_all = re.findall(r'Accessible\.\w+\s*:\s*([^\n]*)', src)
emit('PUA_IN_ACCESSIBLE', sum(1 for v in acc_all if PUA.search(v)))
emit('ACCESSIBLE_BINDINGS_TOTAL', len(acc_all))

# Items whose `text:` value contains a private-use glyph, and whether each is
# hidden from the tree. Done over object bodies rather than lines so that
# `Accessible.ignored` on the SAME object is what counts.
#
# The value read is the OBJECT's accumulated `text` binding, not the remainder
# of the line the `text:` token sits on. That distinction is the whole check on
# this file: the padlock is written `text:  "<glyph>"` and a line-at-a-time
# scan finds it, but the Caps Lock icon lives in the SECOND line of a two-line
# ternary, so that scan reported one icon where there are two -- and would have
# called the file's icons audited on the strength of the one that happened to
# be written on a single line. Self-test 4 holds that shut.
glyph_items, glyph_unignored, seen = 0, 0, set()
for m in re.finditer(r'\btext\s*:', M):
    env = enclosing(m.start())
    if env is None or env in seen:
        continue
    seen.add(env)
    d = bindings(direct(*env))
    if not PUA.search(d.get('text', '')):
        continue
    glyph_items += 1
    ig = d.get('Accessible.ignored', '')
    nm = d.get('Accessible.name', '')
    # Ignored outright, or given a spoken name that has no glyph in it.
    if ig.strip() == 'true':
        continue
    if nm and not PUA.search(nm):
        continue
    glyph_unignored += 1
emit('GLYPH_TEXT_ITEMS', glyph_items)
emit('GLYPH_TEXT_UNIGNORED', glyph_unignored)

# ── what else the field itself announces ─────────────────────────────────────
# The placeholder Text is a DIRECT CHILD of the password field and says "Enter
# password". Qt Quick gives a bare Text the StaticText role and its own text as
# its name, so left alone it reaches a reader as a second label contradicting
# the field's own -- and it is the exact string somebody would otherwise reach
# for AS the field's name, which is what self-test 2 exists to catch.
child_texts, child_unignored = 0, 0
for m in re.finditer(r'\btext\s*:', M):
    if not (b[0] < m.start() < b[1]):
        continue
    env = enclosing(m.start())
    if env is None or env == b:
        continue
    child_texts += 1
    if bindings(direct(*env)).get('Accessible.ignored', '').strip() != 'true':
        child_unignored += 1
emit('PW_CHILD_TEXTS', child_texts)
emit('PW_CHILD_TEXTS_UNIGNORED', child_unignored)

# ── the status line ──────────────────────────────────────────────────────────
# The Text whose value mentions both the error and the Caps Lock state. Found by
# what it says rather than by a line number, which goes stale.
status = None
for m in re.finditer(r'\btext\s*:', M):
    env = enclosing(m.start())
    if env is None:
        continue
    d = bindings(direct(*env))
    t = d.get('text', '')
    if 'hasError' in t and 'capsOn' in t:
        status = env
        break
if status is None:
    emit('STATUS_FOUND', 0)
else:
    emit('STATUS_FOUND', 1)
    sd = bindings(direct(*status))
    emit('STATUS_ROLE', sd.get('Accessible.role', ''))
    emit('STATUS_NAME', sd.get('Accessible.name', ''))
    emit('STATUS_NAME_HAS_PUA', 1 if PUA.search(sd.get('Accessible.name', '')) else 0)
    emit('STATUS_LIVE', 1 if ('hasError' in sd.get('Accessible.name', '')
                              or 'capsOn' in sd.get('Accessible.name', '')) else 0)

# ── the keyboard-only route in ───────────────────────────────────────────────
# A lock screen that needs a click to put focus in the field is a lockout for
# anyone who cannot aim a pointer. These two are what make the click optional.
emit('KEYS_FORWARD', 1 if re.search(r'Keys\.forwardTo\s*:\s*\[\s*passwordInput\s*\]', M) else 0)

# Counted by whether a POINTER is needed to take the route, not by how many
# routes there are. Three sites exist and one of them is inside the
# click-anywhere MouseArea, so a bare total tolerates deleting either keyboard
# route and still reads >= 2 -- the assertion would have survived the exact
# regression it is written to catch. Self-test 5 holds that shut too.
ff_total, ff_nonpointer = 0, 0
for m in re.finditer(r'passwordInput\.forceActiveFocus\s*\(', M):
    ff_total += 1
    env = enclosing(m.start())
    t = type_of(env[0]) if env else ''
    if t not in ('MouseArea', 'TapHandler', 'HoverHandler', 'PointHandler'):
        ff_nonpointer += 1
emit('FORCE_FOCUS', ff_total)
emit('FORCE_FOCUS_NONPOINTER', ff_nonpointer)

# ── saying it, not merely publishing it ──────────────────────────────────────
# A description that follows `hasError` puts the state in the accessibility
# tree. It does not make a reader SAY it: a screen reader does not generally
# speak a description-changed event on the object that already holds focus, so
# a blind user who typed a wrong password can still hear nothing at all. Qt 6.8
# added Accessible.announce() for exactly this, and the image ships 6.10.3 --
# measured by the runtime probe at the bottom of this suite, not assumed.
def fn_body(name):
    """The brace-matched body of `function <name>(...)`, or ''."""
    m = re.search(r'function\s+%s\s*\(' % re.escape(name), M)
    if not m:
        return ''
    o = M.find('{', m.end())
    if o < 0:
        return ''
    env = enclosing(o + 1)
    return M[env[0]:env[1]] if env else ''


say_body = fn_body('say')
fail_body = fn_body('fail')
emit('SAY_FN', 1 if say_body else 0)
emit('SAY_USES_ANNOUNCE', 1 if re.search(r'Accessible\.announce\s*\(', say_body) else 0)
emit('FAIL_SAYS', 1 if re.search(r'\bsay\s*\(', fail_body) else 0)
caps = re.search(r'onCapsOnChanged\s*:([^\n]*)', M)
emit('CAPS_SAYS', 1 if (caps and re.search(r'\bsay\s*\(', caps.group(1))) else 0)
PYEOF

facts() {   # facts <qml file> — materialised to a file, never piped into grep
    python3 "$W/facts.py" "$1" >"$W/facts.txt" 2>"$W/facts.err"
    if [ ! -s "$W/facts.txt" ]; then
        echo "FATAL: the extractor produced nothing for $1" >&2
        sed 's/^/    /' "$W/facts.err" >&2
        exit 2
    fi
}

f() {   # f <KEY> — the value, or empty
    sed -n "s/^$1=//p" "$W/facts.txt" | head -1
}

facts "$LOCK"

# ── the anchor ───────────────────────────────────────────────────────────────
section "the object this suite is about"

if [ "$(f PW_FOUND)" = "1" ]; then
    ok "the lock surface still declares a field with id passwordInput"
else
    echo "FATAL: no 'id: passwordInput' in $LOCK — every assertion below would" >&2
    echo "       be about nothing. Re-point this suite before touching it." >&2
    exit 2
fi

if [ "$(f PW_IS_PASSWORD_ECHO)" = "1" ]; then
    ok "that field is the PASSWORD box (echoMode: TextInput.Password)"
else
    bad "that field is the PASSWORD box (echoMode: TextInput.Password)" \
        "the id was found on something else; this suite is asserting about the wrong object"
fi

# ── the markup ───────────────────────────────────────────────────────────────
section "what a screen reader is told about the password field"

role="$(f PW_ROLE)"
case "$role" in
    *Accessible.EditableText*)
        ok "the password field declares a role (Accessible.EditableText)" ;;
    "") bad "the password field declares a role (Accessible.EditableText)" \
            "no Accessible.role bound directly on passwordInput" ;;
    *)  bad "the password field declares a role (Accessible.EditableText)" \
            "role is '$role', which is not the editable-text role a reader expects here" ;;
esac

pe="$(f PW_PASSWORDEDIT)"
if [ "${pe%%[![:space:]]*}${pe#"${pe%%[![:space:]]*}"}" = "true" ] || [ "$pe" = "true" ]; then
    ok "it is marked as a password box, so an AT does not echo what is typed"
else
    bad "it is marked as a password box, so an AT does not echo what is typed" \
        "Accessible.passwordEdit is '${pe:-absent}'"
fi

name="$(f PW_NAME)"
case "$name" in
    "")  bad "it announces a name" "no Accessible.name bound directly on passwordInput" ;;
    '""'|"''"|'qsTr("")'|"qsTr('')")
         bad "it announces a name" "the name is the empty string, which announces nothing" ;;
    *)   ok "it announces a name ($name)" ;;
esac

# The load-bearing one. A name alone tells a reader user where they are; it does
# not tell them WHY the password they just typed was refused, and that is the
# thing this screen has to be able to say.
if [ -n "$(f PW_DESC)" ]; then
    ok "it carries a description, which is where the live state is said out loud"
else
    bad "it carries a description, which is where the live state is said out loud" \
        "no Accessible.description bound directly on passwordInput"
fi

for pair in "PW_DESC_HAS_ERROR:a rejected password" \
            "PW_DESC_HAS_CAPS:Caps Lock being on" \
            "PW_DESC_HAS_CHECKING:authentication being in progress"; do
    key="${pair%%:*}"; what="${pair#*:}"
    if [ "$(f "$key")" = "1" ]; then
        ok "…and it says it: $what reaches the description"
    else
        bad "…and it says it: $what reaches the description" \
            "the description does not depend on that state, so it is reported by colour and motion alone"
    fi
done

# ── the password itself ──────────────────────────────────────────────────────
section "and what it must NEVER be told"

if [ "$(f PW_SECRET_LEAKS)" = "0" ]; then
    ok "no accessible property on the field exposes the typed password"
else
    bad "no accessible property on the field exposes the typed password" \
        "$(f PW_SECRET_LEAKS) binding(s) read the field's text — the greeter suite asserts the same property"
fi

section "and what is drawn inside it"

ct="$(f PW_CHILD_TEXTS)"; cu="$(f PW_CHILD_TEXTS_UNIGNORED)"
if [ "${ct:-0}" -ge 1 ]; then
    ok "the scan found the Text drawn inside the field to judge ($ct found)"
else
    bad "the scan found the Text drawn inside the field to judge" \
        "none; the placeholder should be seen — the scanner has stopped finding things"
fi
if [ "${cu:-1}" -eq 0 ]; then
    ok "nothing drawn inside the field announces a second, competing label"
else
    bad "nothing drawn inside the field announces a second, competing label" \
        "$cu of $ct still reach a reader — the placeholder says 'Enter password' right after the field says 'Password'"
fi

# ── icons ────────────────────────────────────────────────────────────────────
section "the icons are drawings, and must not be spelled out"

if [ "$(f PUA_IN_ACCESSIBLE)" = "0" ]; then
    ok "no accessible name or description contains a private-use glyph"
else
    bad "no accessible name or description contains a private-use glyph" \
        "$(f PUA_IN_ACCESSIBLE) of $(f ACCESSIBLE_BINDINGS_TOTAL) — a reader spells the icon out before the words"
fi

gi="$(f GLYPH_TEXT_ITEMS)"; gu="$(f GLYPH_TEXT_UNIGNORED)"
# The floor matters as much as the count: "none unignored" is trivially true of
# a file with no icons in it, and this file has two.
if [ "${gi:-0}" -ge 2 ]; then
    ok "the scan found the icon Text items to judge ($gi found)"
else
    bad "the scan found the icon Text items to judge" \
        "only ${gi:-0}; the padlock and the Caps Lock icon should both be seen — the scanner has stopped finding things"
fi
if [ "${gu:-1}" -eq 0 ]; then
    ok "every icon Text is hidden from the tree or given a spoken name instead"
else
    bad "every icon Text is hidden from the tree or given a spoken name instead" \
        "$gu of $gi still reach a reader as a private-use codepoint"
fi

# ── the status line ──────────────────────────────────────────────────────────
section "the line that says why the password was refused"

if [ "$(f STATUS_FOUND)" = "1" ]; then
    ok "the error / Caps Lock status line was located by what it says"
    case "$(f STATUS_ROLE)" in
        *Accessible.StaticText*) ok "the status line declares a readable role" ;;
        "") bad "the status line declares a readable role" \
                "no Accessible.role on it, so it is a bare Text and may not reach the tree at all" ;;
        *)  bad "the status line declares a readable role" "role is '$(f STATUS_ROLE)'" ;;
    esac
    if [ -n "$(f STATUS_NAME)" ]; then
        ok "the status line announces its text"
    else
        bad "the status line announces its text" "no Accessible.name"
    fi
    if [ "$(f STATUS_NAME_HAS_PUA)" = "0" ]; then
        ok "the status line's spoken text has the Caps Lock icon stripped out of it"
    else
        bad "the status line's spoken text has the Caps Lock icon stripped out of it" \
            "the private-use glyph is read before the warning"
    fi
    if [ "$(f STATUS_LIVE)" = "1" ]; then
        ok "the status line's spoken text follows the live state, not a fixed string"
    else
        bad "the status line's spoken text follows the live state, not a fixed string" \
            "the name does not depend on hasError or capsOn"
    fi
else
    bad "the error / Caps Lock status line was located by what it says" \
        "no Text binds both hasError and capsOn — the suite cannot judge a line it cannot find"
fi

# ── the keyboard-only route ──────────────────────────────────────────────────
section "a lock screen a pointer is not needed for"

if [ "$(f KEYS_FORWARD)" = "1" ]; then
    ok "stray keystrokes are forwarded to the field (Keys.forwardTo)"
else
    bad "stray keystrokes are forwarded to the field (Keys.forwardTo)" \
        "typing before clicking would go nowhere"
fi
# Counted by route, not by total. Three sites exist and one of them is the
# click-anywhere MouseArea, so "at least two sites" was satisfied by deleting
# either keyboard route — the assertion would have survived the regression it
# was written to catch. Self-test 5 proves the distinction is real.
if [ "$(f FORCE_FOCUS_NONPOINTER)" -ge 2 ] 2>/dev/null; then
    ok "the field takes focus without a pointer, on both routes ($(f FORCE_FOCUS_NONPOINTER) of $(f FORCE_FOCUS) sites need no click)"
else
    bad "the field takes focus without a pointer, on both routes" \
        "only $(f FORCE_FOCUS_NONPOINTER) of $(f FORCE_FOCUS) forceActiveFocus site(s) are outside a pointer handler; the click-to-refocus MouseArea must never be the only way in"
fi

# ── saying it ────────────────────────────────────────────────────────────────
section "and whether a reader will actually SAY the refusal"

if [ "$(f SAY_FN)" = "1" ]; then
    ok "the surface has a say() helper"
else
    bad "the surface has a say() helper" \
        "nothing on this screen announces; the description alone reaches a tree nobody re-reads"
fi
if [ "$(f SAY_USES_ANNOUNCE)" = "1" ]; then
    ok "…and it goes through Accessible.announce(), not a description it hopes gets re-read"
else
    bad "…and it goes through Accessible.announce(), not a description it hopes gets re-read" \
        "say() does not call Accessible.announce"
fi
if [ "$(f FAIL_SAYS)" = "1" ]; then
    ok "a refused password is announced (fail() says it)"
else
    bad "a refused password is announced (fail() says it)" \
        "fail() sets the error text and shakes the card — a blind user hears nothing"
fi
if [ "$(f CAPS_SAYS)" = "1" ]; then
    ok "Caps Lock coming on is announced, once, on the transition"
else
    bad "Caps Lock coming on is announced, once, on the transition" \
        "no onCapsOnChanged handler announces; the most common cause of a refused password is reported by a glyph"
fi

# The method those four assertions are about is Qt 6.8+. Asserting the QML calls
# it proves nothing if the Qt under it has no such method — that is a green
# check against a runtime error on the lock screen. So it is RUN, on a fixture
# that is deliberately not this file, and the negative control is in
# tests/mutate-lockscreen-a11y.sh.
qmlbin=""
for c in qml-qt6 qml; do command -v "$c" >/dev/null 2>&1 && { qmlbin="$c"; break; }; done
if [ -z "$qmlbin" ]; then
    nope "Accessible.announce() exists on the Qt that will run this" \
         "no qml runner on PATH (qt6-declarative); COULD NOT RUN — this is not a pass"
else
    cat >"$W/announce.qml" <<'QML'
import QtQuick
Item {
    TextInput {
        id: probe
        Accessible.role: Accessible.EditableText
        Accessible.name: "probe"
    }
    Component.onCompleted: {
        if (typeof probe.Accessible.announce !== "function") { Qt.exit(3); return }
        try { probe.Accessible.announce("probe") } catch (e) { Qt.exit(4); return }
        Qt.exit(0)
    }
}
QML
    QT_QPA_PLATFORM=offscreen timeout 60 "$qmlbin" -platform offscreen "$W/announce.qml" \
        >"$W/announce.log" 2>&1
    case "$?" in
        0) ok "Accessible.announce() exists and is callable on this Qt ($qmlbin)" ;;
        3) bad "Accessible.announce() exists and is callable on this Qt" \
               "the attached object has no announce method — Qt is older than 6.8 and say() would be a no-op" ;;
        4) bad "Accessible.announce() exists and is callable on this Qt" \
               "calling it threw" ;;
        *) nope "Accessible.announce() exists and is callable on this Qt" \
                "the probe did not complete (see $W/announce.log); COULD NOT RUN — this is not a pass" ;;
    esac
fi

# ── self-tests ───────────────────────────────────────────────────────────────
#
# The three things that would make every assertion above green for nothing.
section "the extractor, proved against the three ways it could be lying"

st_pass() { ok "self-test: $1"; }
st_fail() { bad "self-test: $1" "$2"; }

# 1. It extracted an OBJECT, not the file. An `enclosing()` that fell through to
#    the outermost braces would make a binding anywhere in the file count.
body="$(f PW_BODY_CHARS)"; whole="$(f PW_FILE_CHARS)"
if [ "${body:-0}" -gt 200 ] && [ "${body:-0}" -lt "$(( ${whole:-1} / 2 ))" ]; then
    st_pass "the passwordInput body is a slice of the file, not the file ($body of $whole chars)"
else
    st_fail "the passwordInput body is a slice of the file, not the file" \
            "$body of $whole chars — the brace walk is not finding the object"
fi

# 2. A binding on the NESTED placeholder Text must not count as the field's.
#    This is the one a grep gets wrong, and it is not hypothetical: the
#    placeholder is a direct child of passwordInput and says "Enter password",
#    which is exactly what somebody would reach for as an accessible name.
sed 's|text:  "Enter password"|text:  "Enter password"\n                            Accessible.name: "NESTED-DECOY"|' \
    "$LOCK" >"$W/nested.qml"
if ! cmp -s "$LOCK" "$W/nested.qml"; then
    facts "$W/nested.qml"
    if [ "$(f PW_NAME)" != '"NESTED-DECOY"' ]; then
        st_pass "a name on the nested placeholder is not read as the field's own"
    else
        st_fail "a name on the nested placeholder is not read as the field's own" \
                "the extractor took a child's binding for the parent's"
    fi
else
    st_fail "a name on the nested placeholder is not read as the field's own" \
            "could not build the fixture — the placeholder text has changed"
fi

# 3. Multi-line values. The description is a ternary over four states and the
#    first line of it mentions only one. A capture that stopped at the newline
#    would report the Caps Lock assertion green off a description that never
#    mentions Caps Lock.
cat >"$W/multi.qml" <<'QML'
import QtQuick
TextInput {
    id: passwordInput
    echoMode: TextInput.Password
    Accessible.role: Accessible.EditableText
    Accessible.passwordEdit: true
    Accessible.name: "Password"
    Accessible.description: surface.checking ? "Checking."
                          : surface.hasError ? surface.errorText
                          : surface.capsOn   ? "Caps Lock is on."
                          : "Type your password."
    // Accessible.name: "COMMENT-DECOY"
    property string prose: "Accessible.name: STRING-DECOY"
}
QML
facts "$W/multi.qml"
if [ "$(f PW_DESC_HAS_CAPS)" = "1" ] && [ "$(f PW_DESC_HAS_CHECKING)" = "1" ]; then
    st_pass "a ternary spanning four lines is captured whole, not truncated at the first"
else
    st_fail "a ternary spanning four lines is captured whole, not truncated at the first" \
            "caps=$(f PW_DESC_HAS_CAPS) checking=$(f PW_DESC_HAS_CHECKING)"
fi
# …and the same fixture carries both decoys, so this is the M7 check too.
if [ "$(f PW_NAME)" = '"Password"' ]; then
    st_pass "a name in a COMMENT and a name inside a STRING are both invisible"
else
    st_fail "a name in a COMMENT and a name inside a STRING are both invisible" \
            "the extractor read '$(f PW_NAME)' — prose is being parsed as markup"
fi

# 4 + 5. One fixture, two lies it forecloses — and both of them were LIVE in
#    this file's first draft, caught by running it rather than by reading it:
#
#      * the icon scan read the remainder of the line the `text:` token sits on.
#        The padlock is written on one line and the Caps Lock icon is on the
#        SECOND line of a ternary, so the scan found one icon of two and the
#        floor check ("at least 2 found") was the only thing that noticed.
#      * the focus check counted forceActiveFocus SITES. Three exist and one is
#        inside the click-anywhere MouseArea, so "at least 2" stayed green with
#        either keyboard route deleted — the exact regression it guards.
#
#    The fixture carries a glyph on a continuation line and a single focus grab
#    that a pointer causes. A scanner with either defect scores it 0 and 1.
python3 - "$W/contline.qml" <<'PY'
import sys
# Written from the codepoint rather than pasted, so the fixture cannot be
# silently repaired by an editor that does not like private-use characters.
open(sys.argv[1], 'w', encoding='utf-8').write('''import QtQuick
Item {
    TextInput {
        id: passwordInput
        echoMode: TextInput.Password
    }
    Text {
        text: root.hasError ? root.errorText
            : (root.capsOn ? "%s  Caps Lock is on" : "")
    }
    MouseArea {
        onClicked: passwordInput.forceActiveFocus()
    }
}
''' % chr(0xF0A9B))
PY
facts "$W/contline.qml"
if [ "$(f GLYPH_TEXT_ITEMS)" = "1" ]; then
    st_pass "an icon on the SECOND line of a ternary is still found"
else
    st_fail "an icon on the SECOND line of a ternary is still found" \
            "scored $(f GLYPH_TEXT_ITEMS); the scan is reading lines, not bindings, and this file's Caps Lock icon is invisible to it"
fi
if [ "$(f FORCE_FOCUS)" = "1" ] && [ "$(f FORCE_FOCUS_NONPOINTER)" = "0" ]; then
    st_pass "a focus grab that only a CLICK causes is not counted as a keyboard route"
else
    st_fail "a focus grab that only a CLICK causes is not counted as a keyboard route" \
            "total=$(f FORCE_FOCUS) nonpointer=$(f FORCE_FOCUS_NONPOINTER); a mouse-only lock screen would read as reachable"
fi

printf '\ncheck-lockscreen-a11y: passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
