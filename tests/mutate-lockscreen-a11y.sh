#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-lockscreen-a11y.sh — prove check-lockscreen-a11y.sh can go red, and
#  prove it does not go red at prose.
#
#  A suite that reads source for markup is the easiest kind to write vacuously.
#  Every assertion in it can be satisfied by a grep that matches the comment
#  explaining the thing, by markup on a neighbouring object, or by a count with
#  a floor low enough that half the file can stop being scanned without anybody
#  noticing. Two of those three were LIVE in the suite's first draft and were
#  found by running it:
#
#    * the icon scan read one line at a time, so it saw one of this file's two
#      private-use glyphs — the other is on the second line of a ternary;
#    * the keyboard-route check counted forceActiveFocus sites. Three exist and
#      one of them is inside the click-anywhere MouseArea, so "at least two"
#      stayed green with either keyboard route deleted.
#
#  L20 and L14 below are those two, kept as mutants so they cannot come back.
#
#  ── Both directions ─────────────────────────────────────────────────────────
#
#  RED (`mutate`): one arm of the markup is broken and a NAMED assertion must go
#  red. A suite that went red on some OTHER line is scored MISSCORED, not
#  caught: those two are indistinguishable if you grep for one sentence, and
#  this unit recorded the wrong one five times before the verdict became
#  three-way.
#
#  GREEN (`hold`): prose is added that quotes the exact defects this suite
#  forbids, and the suite has to stay green. A checker a comment can turn red
#  punishes people for explaining themselves, and this file's subject —
#  accessibility markup — is unusually comment-heavy for exactly the reason that
#  its markup is not self-explanatory.
#
#  ── How the files get put back ──────────────────────────────────────────────
#
#  A pristine copy of each file is taken into a directory this run created with
#  mktemp, and every restore copies it back and then VERIFIES the sha256 against
#  the baseline taken before anything was touched. Not `git checkout --`, which
#  is what the two sister harnesses in this repository use, for a reason
#  measured on the runner rather than guessed: the arch-validate job installs
#  git AFTER actions/checkout, so the checkout falls back to the tarball API and
#  the workspace has no .git at all. `git rev-parse` fails, and a harness that
#  read `git diff`'s empty output as "clean" would apply two dozen mutants on
#  top of each other and print two dozen confident verdicts about a tree nobody
#  restored.
#
#  Not a shared scratch directory either: a `cp` restore in this unit once put
#  back a file holding ANOTHER agent's content, because the scratch path was
#  shared. mktemp per run, removed on exit, and the sha is checked rather than
#  assumed.
#
#  Where a git work tree does exist, it is used as an EXTRA check that the
#  baseline being snapshotted is HEAD and not somebody's half-finished edit.
#
#  Run from anywhere: ./tests/mutate-lockscreen-a11y.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

LOCK="src/windows/Lockscreen.qml"
SUITE_F="tests/check-lockscreen-a11y.sh"
FILES="$LOCK $SUITE_F"
SUITE="./tests/check-lockscreen-a11y.sh"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required" >&2; exit 2; }

# The two private-use codepoints the file draws, written from their numbers
# rather than pasted: a mutant that an editor silently "repaired" would prove
# nothing, and the point of L9 and L20 is that the exact character matters.
G_LOCK="$(python3 -c 'import sys; sys.stdout.write(chr(0xF033E))')"
G_CAPS="$(python3 -c 'import sys; sys.stdout.write(chr(0xF0A9B))')"

applied=0; noapply=0; caught=0; survived=0; misscored=0; held=0; falsered=0

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/mutate-lockscreen.XXXXXX")" || exit 2
trap 'rm -rf "$SNAP"' EXIT INT TERM

snap_of() { printf '%s' "$1" | tr '/' '_'; }

# shellcheck disable=SC2086  # $FILES is a deliberate, space-separated list
take_snapshot() {
    local f
    for f in $FILES; do
        [ -f "$f" ] || { echo "ABORT: $f does not exist" >&2; exit 3; }
        cp -- "$f" "$SNAP/$(snap_of "$f")" || exit 3
    done
    sha256sum -- $FILES >"$SNAP/baseline.sha256" || exit 3
}

tree_clean() { sha256sum -c --status "$SNAP/baseline.sha256" 2>/dev/null; }

restore() {
    local f
    for f in $FILES; do
        cp -- "$SNAP/$(snap_of "$f")" "$f" || exit 3
    done
    if ! tree_clean; then
        echo "ABORT: a restored file does not match its baseline sha256;" >&2
        echo "       every verdict after this point would be meaningless" >&2
        sha256sum -c "$SNAP/baseline.sha256" >&2
        exit 3
    fi
}

run_suite() {
    env -i HOME="$HOME" PATH="$PATH" USER="${USER:-$(id -un)}" \
        TMPDIR="${TMPDIR:-/tmp}" "$SUITE" 2>&1
}

# Did the suite reach its own totals line at all? A FATAL exit (2) prints no
# totals, and a harness that reads "no failures reported" off a crash scores
# every crash as a survival — which is the single most expensive way to be
# wrong here, because it reports a working suite as a broken one.
has_totals() { printf '%s\n' "$1" | grep -qE '^check-lockscreen-a11y: passed='; }

suite_failures() {
    printf '%s\n' "$1" \
        | sed -n 's/^check-lockscreen-a11y: passed=[0-9]* failed=\([0-9]*\).*/\1/p' \
        | head -1 | grep -E '^[0-9]+$' || echo 0
}

# classify <suite output> <expected FAIL substring>
#   -> CAUGHT | MISSCORED | CRASHED | SURVIVED
classify() {
    local out="$1" want="$2"
    if ! has_totals "$out"; then
        echo CRASHED
    elif printf '%s' "$out" | grep -q "^  FAIL .*$want"; then
        echo CAUGHT
    elif [ "$(suite_failures "$out")" -gt 0 ]; then
        echo MISSCORED
    else
        echo SURVIVED
    fi
}

# ── self-test: the scoring above, in all four states ─────────────────────────
selftest() {
    local red green crash fails=0
    red="  FAIL it is marked as a password box, so an AT does not echo what is typed  — absent
check-lockscreen-a11y: passed=32 failed=1 skipped=0"
    green="check-lockscreen-a11y: passed=33 failed=0 skipped=0"
    crash="FATAL: no 'id: passwordInput' in src/windows/Lockscreen.qml"

    chk() {  # chk <label> <want> <got>
        if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
        else printf '  FAIL %s — want %s got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
    }
    chk "a red suite naming the expectation is CAUGHT" \
        CAUGHT    "$(classify "$red"   "it is marked as a password box")"
    chk "a red suite NOT naming it is MISSCORED, not a survival" \
        MISSCORED "$(classify "$red"   "a sentence this suite never prints")"
    chk "a green suite is the only thing that is a SURVIVAL" \
        SURVIVED  "$(classify "$green" "a sentence this suite never prints")"
    chk "a suite that never reached its totals line is CRASHED, never a survival" \
        CRASHED   "$(classify "$crash" "a sentence this suite never prints")"
    chk "counting failures off a red totals line"   1 "$(suite_failures "$red")"
    chk "counting failures off a green totals line" 0 "$(suite_failures "$green")"
    chk "a SKIP is not a pass: the totals line carries it separately" \
        1 "$(printf '%s\n' "$green" | grep -c 'skipped=')"
    [ "$fails" -eq 0 ] || { echo "ABORT: the harness cannot score itself" >&2; exit 3; }
}

# ── self-test: the RESTORE mechanism, which everything else rests on ─────────
#
# Every verdict after the first mutant is a claim about a tree this script put
# back. If `git diff` cannot run — a container where the checkout is owned by
# another uid answers "detected dubious ownership" and exits non-zero — then
# tree_clean() sees empty output and reports CLEAN, `git checkout --` fails just
# as silently, and every mutant from the second one on is applied on top of the
# last. The run would print two dozen confident verdicts about a file nobody
# restored. So the mechanism is demonstrated, on the real file, before use.
restore_selftest() {
    command -v sha256sum >/dev/null 2>&1 || {
        echo "ABORT: sha256sum is required to verify restores" >&2; exit 3; }

    # Where a work tree exists, say whether the baseline is HEAD. Reported, NOT
    # enforced: mutating a change you have not committed yet is the normal way
    # to use this, and an ABORT here would make the harness unusable for exactly
    # the person writing the markup. What makes the verdicts sound is the
    # sha256 baseline below, which holds either way.
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && git diff --name-only -- $FILES >/dev/null 2>&1; then
        if [ -n "$(git diff --name-only -- $FILES)" ]; then
            echo "  note the baseline is a WORKING TREE state, not HEAD:"
            git diff --name-only -- $FILES | sed 's/^/         /'
        else
            echo "  ok   the baseline being snapshotted is HEAD"
        fi
    else
        echo "  note not a git work tree (a tarball checkout, which is what the arch"
        echo "       runner delivers); the baseline is the files as they arrived"
    fi

    take_snapshot
    tree_clean || { echo "ABORT: the snapshot does not match the files it was taken from" >&2; exit 3; }

    printf '\n// mutate-lockscreen-a11y.sh restore probe\n' >>"$LOCK"
    if tree_clean; then
        echo "ABORT: a real edit to $LOCK was not seen — the baseline is not being read" >&2
        exit 3
    fi
    echo "  ok   a real edit to the file under test is SEEN"
    restore
    echo "  ok   …and the restore puts it back, sha256 for sha256"
}

echo "── self-test: this harness can tell its four verdicts apart ──"
selftest
restore_selftest

apply_edit() {  # apply_edit <file> <from> <to>; non-zero if nothing changed
    local file="$1" from="$2" to="$3"
    python3 - "$file" "$from" "$to" <<'EDIT'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
if s.count(a) < 1:
    sys.exit(1)
open(p, 'w', encoding="utf-8").write(s.replace(a, b, 1))
EDIT
    tree_clean && return 1
    return 0
}

# mutate <id> <file> <from> <to> <assertion substring that must go red>
mutate() {
    local id="$1" file="$2" from="$3" to="$4" want="$5"
    tree_clean || { echo "ABORT: tree dirty BEFORE $id" >&2; exit 3; }
    if ! apply_edit "$file" "$from" "$to"; then
        printf '%-5s NO-APPLY  anchor absent in %s — this mutant proves nothing\n' "$id" "$file"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))

    local out verdict; out="$(run_suite)"; verdict="$(classify "$out" "$want")"
    case "$verdict" in
    CAUGHT)
        printf '%-5s CAUGHT    %s\n' "$id" "$want"
        caught=$((caught + 1)) ;;
    MISSCORED)
        printf '%-5s MISSCORED the suite went red (%s failed) but not on the named assertion\n' \
               "$id" "$(suite_failures "$out")"
        printf '      expected a FAIL line containing: %s\n' "$want"
        printf '      ── FIX THE EXPECTATION, NOT THE CODE. What actually went red: ──\n'
        printf '%s\n' "$out" | grep -E '^  (FAIL|SKIP)' | sed 's/^/      /'
        misscored=$((misscored + 1)) ;;
    CRASHED)
        printf '%-5s MISSCORED the suite never reached its totals line\n' "$id"
        printf '      ── a FATAL is the harness dying, not an assertion catching ──\n'
        printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
        misscored=$((misscored + 1)) ;;
    *)
        printf '%-5s SURVIVED  %s\n' "$id" "$want"
        printf '      ── the suite stayed GREEN with this mutant applied ──\n'
        printf '%s\n' "$out" | grep -E '^  (FAIL|SKIP)|^check-lockscreen-a11y' | sed 's/^/      /'
        survived=$((survived + 1)) ;;
    esac
    restore
}

# hold <id> <file> <from> <to> <why this must NOT fire>
hold() {
    local id="$1" file="$2" from="$3" to="$4" why="$5"
    tree_clean || { echo "ABORT: tree dirty BEFORE $id" >&2; exit 3; }
    if ! apply_edit "$file" "$from" "$to"; then
        printf '%-5s NO-APPLY  anchor absent in %s\n' "$id" "$file"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))
    local out; out="$(run_suite)"
    if has_totals "$out" && [ "$(suite_failures "$out")" -eq 0 ]; then
        printf '%-5s HELD      %s\n' "$id" "$why"
        held=$((held + 1))
    else
        printf '%-5s FALSE-RED %s\n' "$id" "$why"
        printf '      ── the suite fired on something that changes nothing ──\n'
        printf '%s\n' "$out" | grep -E '^  (FAIL|SKIP)|^check-lockscreen-a11y|^FATAL' | sed 's/^/      /'
        falsered=$((falsered + 1))
    fi
    restore
}

echo
echo "── baseline: green, or nothing below means anything ──"
base="$(run_suite)"
printf '%s\n' "$base" | grep -E '^check-lockscreen-a11y'
if ! printf '%s' "$base" | grep -qE '^check-lockscreen-a11y: passed=[0-9]+ failed=0'; then
    echo "ABORT: the suite is not green to begin with" >&2
    printf '%s\n' "$base" | grep -E '^  (FAIL|SKIP)' >&2
    exit 3
fi
if ! printf '%s' "$base" | grep -qE 'skipped=0$'; then
    echo "NOTE: the baseline SKIPPED something — a could-not-run is not a pass," >&2
    echo "      and any mutant aimed at a skipped check is scored against nothing." >&2
    printf '%s\n' "$base" | grep -E '^  SKIP' >&2
fi

echo
echo "── red: the markup breaks and a named assertion says so ──"

# L1 — the load-bearing one. echoMode hides the text from the SCREEN; nothing
#      about it reaches the accessibility tree, so without passwordEdit an
#      assistive technology has no reason not to echo, log or braille what is
#      typed into this box.
mutate L1 "$LOCK" \
    '                        Accessible.passwordEdit: true' \
    '                        // Accessible.passwordEdit: true' \
    "it is marked as a password box"

# L2 — the role goes to something a reader will not offer to edit.
mutate L2 "$LOCK" \
    '                        Accessible.role:         Accessible.EditableText' \
    '                        Accessible.role:         Accessible.StaticText' \
    "the password field declares a role"

# L3 — a name that is present and says nothing. The empty-string arm exists
#      because `Accessible.name: ""` satisfies every "is there a name" grep.
mutate L3 "$LOCK" \
    '                        Accessible.name:         "Password"' \
    '                        Accessible.name:         ""' \
    "it announces a name"

# L4 — Caps Lock drops out of the description. The most common reason a correct
#      password is refused goes back to being reported by a red glyph.
mutate L4 "$LOCK" \
    '                                               : surface.capsOn   ? "Caps Lock is on."' \
    '                                               : false            ? "Caps Lock is on."' \
    "Caps Lock being on reaches the description"

# L5 — the in-flight state drops out. The field is disabled while PAM runs, and
#      a user who cannot see the spinner has nothing to tell them why.
mutate L5 "$LOCK" \
    '                        Accessible.description:  surface.checking ? "Checking your password."' \
    '                        Accessible.description:  false ? "Checking your password."' \
    "authentication being in progress reaches the description"

# L6 — the refusal drops out.
mutate L6 "$LOCK" \
    '                                               : surface.hasError ? surface.errorText' \
    '                                               : false           ? surface.errorText' \
    "a rejected password reaches the description"

# L7 — the one-word mistake. `Accessible.name: <the field>` is how a password
#      crosses the accessibility bus, and the greeter suite in apex-os asserts
#      the same property about the same class of field.
mutate L7 "$LOCK" \
    '                        Accessible.name:         "Password"' \
    '                        Accessible.name:         passwordInput.displayText' \
    "no accessible property on the field exposes the typed password"

# L8 — the padlock stops being a drawing. A reader reaching it says "private use
#      character F033E", or whatever its font calls it, before the field.
mutate L8 "$LOCK" \
    '                        // so silence here has to be asked for.
                        Accessible.ignored: true' \
    '                        // so silence here has to be asked for.
                        Accessible.ignored: false' \
    "every icon Text is hidden from the tree or given a spoken name instead"

# L9 — the icon comes back in the SPOKEN text. This is the installer Wi-Fi
#      defect exactly: there the signal bars were inside the accessible name and
#      a reader spelled out four block characters before every network.
mutate L9 "$LOCK" \
    '? "Caps Lock is on" : ""' \
    "? \"${G_CAPS}  Caps Lock is on\" : \"\"" \
    "the status line's spoken text has the Caps Lock icon stripped out of it"

# L10 — the status line becomes a bare Text again.
mutate L10 "$LOCK" \
    '                    Accessible.role: Accessible.StaticText' \
    '                    // Accessible.role: Accessible.StaticText' \
    "the status line declares a readable role"

# L11 — the status line announces a constant. It has a name, it has a role, and
#       it says the same thing whether or not the password was refused.
mutate L11 "$LOCK" \
    '                    Accessible.name: surface.hasError ? surface.errorText
                                   : (surface.capsOn ? "Caps Lock is on" : "")' \
    '                    Accessible.name: "Status"' \
    "the status line's spoken text follows the live state, not a fixed string"

# L12 — the placeholder becomes a second label, so the field announces
#       "Password" and then "Enter password", and the second one disappears the
#       moment a key is pressed.
mutate L12 "$LOCK" \
    '                            // which disappears the moment a key is pressed.
                            Accessible.ignored: true' \
    '                            // which disappears the moment a key is pressed.
                            Accessible.ignored: false' \
    "nothing drawn inside the field announces a second, competing label"

# L13 — typing before clicking goes nowhere.
mutate L13 "$LOCK" \
    '            Keys.forwardTo: [passwordInput]' \
    '            Keys.forwardTo: []' \
    "stray keystrokes are forwarded to the field"

# L14 — ONE of the two keyboard routes to focus is deleted, leaving the
#       click-anywhere MouseArea and one handler. The suite's first draft
#       counted sites and required two, so this mutant SURVIVED it: three sites
#       minus one is still two. It is caught now because the count asks whether
#       a pointer causes each grab.
mutate L14 "$LOCK" \
    '        Component.onCompleted: passwordInput.forceActiveFocus()' \
    '        // Component.onCompleted: passwordInput.forceActiveFocus()' \
    "the field takes focus without a pointer, on both routes"

# L15 — the refusal stops being announced. Note the mutant is a COMMENT: the
#       check reads the masked copy, so commenting the call out is the same as
#       deleting it. A check that could not tell those apart would report this
#       screen as announcing because the file contains the word.
mutate L15 "$LOCK" \
    '            surface.say(msg)' \
    '            // surface.say(msg)' \
    "a refused password is announced"

# L16 — Caps Lock coming on stops being announced.
mutate L16 "$LOCK" \
    '        onCapsOnChanged: if (surface.capsOn) surface.say("Caps Lock is on")' \
    '        onCapsOnChanged: if (surface.capsOn) shakeAnim.restart()' \
    "Caps Lock coming on is announced"

# L17 — say() keeps its name and stops announcing. The description is still
#       there and still correct; nobody hears it, which is the whole distinction
#       this section exists to draw.
mutate L17 "$LOCK" \
    '                passwordInput.Accessible.announce(msg)' \
    '                console.log(msg)' \
    "it goes through Accessible.announce"

# L18 — the helper is gone entirely.
mutate L18 "$LOCK" \
    '        function say(msg) {' \
    '        function unusedSay(msg) {' \
    "the surface has a say() helper"

# L19 — the anchor the whole suite rests on. If this stops being a password box
#       every assertion above is about the wrong object, and the suite has to
#       say so rather than reporting the markup as fine.
mutate L19 "$LOCK" \
    '                        echoMode:                TextInput.Password' \
    '                        echoMode:                TextInput.Normal' \
    "that field is the PASSWORD box"

# L20 — the floor under the icon scan. One of the two glyphs stops being a
#       glyph; "none unignored" is trivially true of a file with no icons, so
#       the count of icons FOUND has to be a floor as well. This is the mutant
#       that would have caught the suite's own first-draft line-at-a-time scan.
mutate L20 "$LOCK" \
    "                        text:  \"${G_LOCK}\"" \
    '                        text:  "Lock"' \
    "the scan found the icon Text items to judge"

echo
echo "── green: prose quoting every one of those bugs must NOT fire it ──"

# G1 — comments inside the field body that read exactly like the defects L1, L3
#      and L7 introduce. This is the shape that has gone wrong in this
#      repository four times in one day: a check satisfied by the comment
#      explaining what it forbids, or fired by it.
hold G1 "$LOCK" \
    '                        Accessible.role:         Accessible.EditableText' \
    '                        // WRONG, kept as a warning: Accessible.passwordEdit: false
                        // WRONG, kept as a warning: Accessible.name: ""
                        // WRONG, kept as a warning: Accessible.name: passwordInput.displayText
                        Accessible.role:         Accessible.EditableText' \
    "comments quoting the exact bugs this suite forbids do not fire it"

# G2 — the same text inside a STRING, which is code rather than prose and still
#      binds nothing. The leak scan looks at Accessible.* BINDINGS, not at
#      lines that contain the words.
hold G2 "$LOCK" \
    '                        Accessible.passwordEdit: true' \
    '                        Accessible.passwordEdit: true
                        readonly property string a11yNote: "Accessible.name: passwordInput.displayText"' \
    "a string literal spelling out a leaking binding is not a leaking binding"

# G3 — a comment carrying the Caps Lock glyph, written directly under a `text:`
#      binding that has no glyph in it. Values are accumulated across the lines
#      that follow them, so without the comments-blanked copy this prose would
#      be swallowed INTO the username's text and reported as a third, unaudited
#      icon. A suite that prose can turn red is as broken as one prose turns
#      green, and this file is necessarily comment-heavy.
hold G3 "$LOCK" \
    '                    text:           surface.username !== "" ? surface.username : "Locked"' \
    "                    text:           surface.username !== \"\" ? surface.username : \"Locked\"
                    // the ${G_CAPS} glyph is drawn by the status line below, not here" \
    "a comment carrying an icon glyph is not an unaudited icon"

# G4 — the whole story in the file header, where somebody documenting this work
#      would naturally put it: every forbidden binding, both glyphs, and the
#      word announce, none of it inside any object.
hold G4 "$LOCK" \
    'import QtQuick
import QtQuick.Effects' \
    "import QtQuick
import QtQuick.Effects
// Accessibility notes (prose only — see tests/check-lockscreen-a11y.sh):
//   Accessible.passwordEdit: false would let a reader echo the password.
//   Accessible.name: passwordInput.text would put it on the bus outright.
//   The ${G_LOCK} and ${G_CAPS} glyphs are drawings; they must never be spoken.
//   say() must call Accessible.announce, not console.log." \
    "a prose header naming every forbidden binding and both glyphs does not fire it"

echo
printf 'mutants applied=%d, failed-to-apply=%d | red: caught=%d SURVIVED=%d MISSCORED=%d | green: held=%d FALSE-RED=%d\n' \
    "$applied" "$noapply" "$caught" "$survived" "$misscored" "$held" "$falsered"
[ "$misscored" -eq 0 ] || echo "MISSCORED means this harness is wrong, not the shell." >&2
tree_clean || { echo "ABORT: tree dirty at end of run" >&2; exit 3; }
echo "every file matches the sha256 it started with"
[ "$survived" -eq 0 ] && [ "$misscored" -eq 0 ] && [ "$falsered" -eq 0 ] && [ "$noapply" -eq 0 ]
