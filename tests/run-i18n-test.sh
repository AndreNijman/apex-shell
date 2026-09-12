#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-i18n-test.sh — do this shell's strings extract, compile, and SUBSTITUTE?
#  (roadmap P2-004, internationalisation baseline)
#
#  ── Why the bar is "substitute", not "supports translation" ─────────────────
#
#  Qt supports translation. Saying so measures nothing: every QML tree on earth
#  supports translation in the same sense, including this one on the day it had
#  zero translatable strings. What decides whether a German user sees German is
#  a chain of four links, and any one of them breaks silently:
#
#     1. the string sits inside qsTr()          — or lupdate never sees it
#     2. lupdate extracts it into a .ts         — or there is nothing to translate
#     3. lrelease compiles the .ts to a .qm     — or there is nothing to load
#     4. a QTranslator is installed and the     — or the words never change
#        engine reads the translated text
#
#  So this suite runs all four on the SHIPPED file, with the real tools, and
#  reads the result back out of a running QML engine.
#
#  ── The assertion that makes the rest mean anything ─────────────────────────
#
#  A test that loads a translation and finds German proves nothing on its own:
#  it could be reading a hardcoded German string, or the fixture could be wrong
#  in a way that happens to match. So the SAME fixture runs twice, once with
#  -translation and once without, and the two runs must DISAGREE. An identical
#  pair means the translation was never loaded and every other check here is
#  decoration.
#
#  ── The ratio is the baseline ───────────────────────────────────────────────
#
#  Five strings are translatable today out of several hundred user-facing
#  literals in this tree. The suite counts both and prints the ratio, and pins
#  the translatable count EXACTLY in both directions: a new qsTr() that nobody
#  translated, or a lost one, both move the number and both should be a decision
#  rather than a surprise.
#
#  ── Headless discipline ─────────────────────────────────────────────────────
#
#  qmltestrunner on the offscreen platform. The ambient display variables get
#  removed from the environment rather than merely ignored, the same way
#  run-a11y-controls-test.sh does it, so no plugin that decides to go looking
#  can find the compositor somebody is working in.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root" || exit 2

CONTENT="src/services/agents/AgentHelpContent.qml"
TS="translations/apex-shell_de.ts"

pass=0; fail=0; skip=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s%s\n' "$1" "${2:+  — $2}"; fail=$((fail + 1)); }
skp() { printf '  skip %s%s\n' "$1" "${2:+  — $2}"; skip=$((skip + 1)); }
section() { printf '\n── %s ──\n' "$1"; }

[ -f "$CONTENT" ] || { echo "FATAL: no $CONTENT" >&2; exit 2; }
[ -f "$TS" ]      || { echo "FATAL: no $TS" >&2; exit 2; }

stage="$(mktemp -d)"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT INT TERM

# Fedora suffixes these binaries; Debian/Ubuntu use a `6` suffix or none.
find_tool() {
    local n
    for n in "$@"; do
        command -v "$n" >/dev/null 2>&1 && { printf '%s' "$n"; return 0; }
    done
    return 1
}
LUPDATE="$(find_tool lupdate-qt6 lupdate6 lupdate /usr/lib64/qt6/bin/lupdate)"
LRELEASE="$(find_tool lrelease-qt6 lrelease6 lrelease /usr/lib64/qt6/bin/lrelease)"
RUNNER="$(find_tool qmltestrunner-qt6 qmltestrunner /usr/lib64/qt6/bin/qmltestrunner)"

# ═════════════════════════════════════════════════════════════════════════════
section "1. the strings are marked for translation at all"
# ═════════════════════════════════════════════════════════════════════════════
# Counted from the file rather than remembered. This is the numerator of the
# baseline, and it is pinned exactly: an unreviewed change in either direction
# is a change in what this repository claims about its own translatability.
EXPECT_TR=5
# Code lines only. The header comment mentions qsTr by name, and a comment is
# not a translatable string.
n_tr="$(grep -vE '^\s*//' "$CONTENT" | grep -oE '\bqsTr\(' | wc -l | tr -d ' ')"
if [ "$n_tr" = "$EXPECT_TR" ]; then
    ok "$CONTENT marks exactly $EXPECT_TR strings with qsTr()"
else
    bad "$CONTENT marks exactly $EXPECT_TR strings with qsTr()" "found $n_tr"
fi

# The denominator. Deliberately a wide net over the whole tree: the point of a
# baseline is the honest total, not a flattering one. Printed, not asserted —
# it moves whenever anyone writes a label, and failing a build for that would
# teach people to stop writing labels.
LITERAL_RE='\b(text|label|title|description|tooltip|placeholderText|tip|blurb|heading)\s*:\s*[^\n]*"[A-Za-z][^"]*"'
n_lit="$(grep -rnE "$LITERAL_RE" src --include='*.qml' 2>/dev/null | grep -vE ':[0-9]+:\s*//' | wc -l | tr -d ' ')"
n_tr_all="$(grep -rn 'qsTr(' src --include='*.qml' 2>/dev/null | grep -vE ':[0-9]+:\s*//' | wc -l | tr -d ' ')"
printf '       baseline: %s call sites use qsTr(); about %s user-facing literals in src/**.qml\n' \
    "$n_tr_all" "$n_lit"

# ═════════════════════════════════════════════════════════════════════════════
section "2. lupdate really extracts them"
# ═════════════════════════════════════════════════════════════════════════════
if [ -z "$LUPDATE" ]; then
    skp "lupdate extracts the marked strings" "no lupdate on this machine (qt6-qttools-devel)"
else
    cp "$CONTENT" "$stage/AgentHelpContent.qml"
    # -no-obsolete so the count is what this file marks TODAY, not the union of
    # everything it has ever marked.
    "$LUPDATE" -silent -no-obsolete "$stage/AgentHelpContent.qml" \
        -ts "$stage/extracted.ts" >/dev/null 2>&1
    if [ -s "$stage/extracted.ts" ]; then
        n_src="$(grep -c '<source>' "$stage/extracted.ts" 2>/dev/null | tr -d ' ')"
        if [ "$n_src" = "$EXPECT_TR" ]; then
            ok "lupdate extracted exactly $EXPECT_TR strings from the shipped file"
        else
            bad "lupdate extracted exactly $EXPECT_TR strings from the shipped file" \
                "extracted $n_src"
        fi
        # The context name decides which <context> block a translation must sit
        # in. Getting it wrong produces a .qm that loads and translates nothing,
        # which is the quietest failure in this whole chain.
        if grep -q '<name>AgentHelpContent</name>' "$stage/extracted.ts"; then
            ok "the extracted context is AgentHelpContent, which is what $TS translates"
        else
            bad "the extracted context is AgentHelpContent" \
                "got: $(grep -m1 '<name>' "$stage/extracted.ts" | tr -d ' ')"
        fi
        # Every source string in the checked-in .ts must be one lupdate really
        # produces. A stale .ts translates strings that no longer exist and
        # leaves the live ones English, with nothing anywhere reporting it.
        missing=0
        while IFS= read -r src_line; do
            grep -qF "$src_line" "$stage/extracted.ts" || missing=$((missing + 1))
        done < <(grep -oE '<source>[^<]*</source>' "$TS")
        if [ "$missing" = 0 ]; then
            ok "every string $TS translates is one lupdate still extracts (no stale entries)"
        else
            bad "every string $TS translates is one lupdate still extracts" \
                "$missing entr(ies) in $TS no longer exist in the source"
        fi
    else
        bad "lupdate extracted exactly $EXPECT_TR strings from the shipped file" \
            "lupdate produced no .ts"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
section "3. lrelease compiles, and a running engine substitutes"
# ═════════════════════════════════════════════════════════════════════════════
if [ -z "$RUNNER" ]; then
    skp "a running QML engine reads the German strings" "no qmltestrunner"
elif [ -z "$LRELEASE" ]; then
    skp "a running QML engine reads the German strings" "no lrelease"
else
    if ! "$LRELEASE" -silent "$TS" -qm "$stage/de.qm" >/dev/null 2>&1 \
       || [ ! -s "$stage/de.qm" ]; then
        bad "lrelease compiles $TS into a .qm"
    else
        ok "lrelease compiles $TS into a loadable .qm"

        # The fixture instantiates the SHIPPED singleton and reports what the
        # engine actually resolved each property to. It asserts nothing itself:
        # the two runs are compared out here, so a single run cannot decide the
        # answer on its own.
        cp "$CONTENT" "$stage/AgentHelpContent.qml"
        cat > "$stage/qmldir" <<'QMLDIR'
singleton AgentHelpContent AgentHelpContent.qml
QMLDIR
        cat > "$stage/i18n-test.qml" <<'FIXTURE'
import QtQuick
import QtTest
import "."

TestCase {
    name: "I18n"
    // Printed, never asserted here. What the strings SHOULD be depends on
    // whether a translator was installed, and only the runner outside knows
    // that. Keeping the judgement out of the fixture is what lets the same
    // fixture serve as both halves of the comparison.
    function test_000_report() {
        console.log("I18N entryLabel=" + AgentHelpContent.entryLabel)
        console.log("I18N cardTitle=" + AgentHelpContent.cardTitle)
        console.log("I18N cardRead=" + AgentHelpContent.cardRead)
        console.log("I18N cardDismiss=" + AgentHelpContent.cardDismiss)
        verify(true)
    }
}
FIXTURE

        # console.log from QML lands on the `qml` logging category, and Qt ships
        # with debug output off by default — the first version of this suite read
        # nothing at all and reported an empty string for both runs. The category
        # is turned back on explicitly rather than relying on the machine's
        # /etc/xdg/QtProject/qtlogging.ini, which differs between distributions.
        run_fixture() {   # run_fixture [qm]
            local qm="${1:-}"
            env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
                QT_QPA_PLATFORM=offscreen \
                QT_LOGGING_RULES="qml.debug=true;js.debug=true;qt.qml.binding.removal.info=false" \
                timeout 120 "$RUNNER" -platform offscreen \
                ${qm:+-translation "$qm"} \
                -input "$stage/i18n-test.qml" 2>&1
        }

        plain="$(run_fixture)"
        german="$(run_fixture "$stage/de.qm")"

        field() {   # field <output> <name>
            printf '%s' "$1" | sed -n "s/.*I18N $2=\\(.*\\)/\\1/p" | head -1 | sed 's/[[:space:]]*$//'
        }

        p_entry="$(field "$plain" entryLabel)"
        g_entry="$(field "$german" entryLabel)"
        p_read="$(field "$plain" cardRead)"
        g_read="$(field "$german" cardRead)"
        p_dis="$(field "$plain" cardDismiss)"
        g_dis="$(field "$german" cardDismiss)"

        if [ -z "$p_entry" ] || [ -z "$g_entry" ]; then
            bad "the fixture instantiated the shipped singleton and reported its strings" \
                "plain[$p_entry] german[$g_entry] — see: $(printf '%s' "$german" | tail -3 | tr '\n' ' ')"
        else
            ok "the fixture instantiated the shipped singleton and reported its strings"

            # THE SENSITIVITY CHECK. Without this the rest is decoration: a
            # fixture that never loaded the translator would return English
            # twice and every equality below could still be written to pass.
            if [ "$p_entry" != "$g_entry" ]; then
                ok "the same fixture gives DIFFERENT text with and without -translation"
            else
                bad "the same fixture gives different text with and without -translation" \
                    "both runs said [$p_entry] — the translation was never loaded"
            fi

            # Untranslated: the source strings, unchanged.
            [ "$p_entry" = "How Agents & Workspaces work" ] \
                && ok "untranslated, the engine reads the English source string" \
                || bad "untranslated, the engine reads the English source string" "got [$p_entry]"

            # Translated: the German the .ts supplies, read off the live object.
            [ "$g_entry" = "Wie Agenten und Arbeitsbereiche funktionieren" ] \
                && ok "translated, entryLabel reads the German from $TS" \
                || bad "translated, entryLabel reads the German from $TS" "got [$g_entry]"

            [ "$g_read" = "Anleitung lesen" ] \
                && ok "translated, cardRead reads the German from $TS" \
                || bad "translated, cardRead reads the German from $TS" "got [$g_read]"

            [ "$g_dis" = "Verstanden" ] \
                && ok "translated, cardDismiss reads the German from $TS" \
                || bad "translated, cardDismiss reads the German from $TS" "got [$g_dis]"

            # Three independent strings, so one lucky match cannot carry the
            # verdict — and they must differ from their English forms.
            changed=0
            [ "$p_entry" != "$g_entry" ] && changed=$((changed + 1))
            [ "$p_read"  != "$g_read"  ] && changed=$((changed + 1))
            [ "$p_dis"   != "$g_dis"   ] && changed=$((changed + 1))
            if [ "$changed" = 3 ]; then
                ok "all three sampled strings changed under translation, not just one"
            else
                bad "all three sampled strings changed under translation" \
                    "only $changed of 3 moved"
            fi
        fi
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
section "4. what this does NOT prove"
# ═════════════════════════════════════════════════════════════════════════════
# Stated as an assertion so it cannot quietly stop being true. Nothing in the
# SHIPPED shell installs a QTranslator: quickshell hosts this QML and no code
# here calls installTranslator or reads a .qm. So the pipeline works and no user
# sees a translated word yet. The day somebody wires it up, this flips and the
# row in the ledger can change with it.
if grep -rqn 'installTranslator\|QTranslator' src 2>/dev/null; then
    ok "the shell installs a QTranslator, so translations reach real users"
else
    printf '  note %s\n' "no QTranslator anywhere in src/ — the pipeline is proven, but the"
    printf '       %s\n' "running shell loads no .qm, so no user sees German yet. This is"
    printf '       %s\n' "the named gap for P2-004's 'translated shell' row."
fi

printf '\nrun-i18n-test: passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
