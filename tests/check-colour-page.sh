#!/usr/bin/env bash
# Static invariants for the Display page's colour section (P1-041).
#
# ── Why this exists next to the behavioural suite ────────────────────────────
#
# tests/run-colour-page-test.sh needs quickshell and a wlroots compositor and
# skips without them, which is every CI runner. A suite that skips is a suite
# that proves nothing, and this repository has already shipped assertions that
# passed because they never ran.
#
# So the properties a refactor would quietly undo are checked here, by grep,
# headless. Two of them are about honesty rather than about function:
#
#   * The page must state the ENGINE's reason for the calibration curve not
#     being loaded, verbatim, and must not carry its own copy of that
#     reasoning. A paraphrase in QML is a claim that keeps being made after the
#     engine stops meaning it — install xcalib and the engine changes its
#     answer while a hardcoded sentence does not.
#   * The reason must not be rendered anywhere it can be truncated. CfgRow's
#     description is maximumLineCount 2 with ElideRight and the sentence is
#     ~300 characters, so a reason in a row is shown as two lines and an
#     ellipsis — and the half that gets cut is the half that says the
#     assignment never reaches the screen. A truncated caveat is worse than
#     none.
#
# And one that is about not breaking older machines: the shell ships before the
# image that answers it, and the engine's argparse keeps its verbs in a
# `choices` list, so an unprobed `color` exits 2 on every image predating this
# branch.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

svc="$root/src/services/config_tab/DisplayService.qml"
page="$root/src/services/config_tab/pages/DisplayPage.qml"
suite="$root/tests/colour-page-test.qml"
runner="$root/tests/run-colour-page-test.sh"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# Code lines only. Most of this repository's prose is about what it used to do,
# and a check a comment can satisfy is a check that stops being one. Both
# honesty checks below depend on this: the page's own comment block explains
# the missing loader by name, and it should.
code() { grep -vE '^\s*(//|#)' "$1" 2>/dev/null; }

# `code` is a shell FUNCTION, so it does not exist inside `bash -c` — the
# subshell is a fresh bash and inherits no functions. Four checks here were
# written that way at first: their greps got empty input, and the three
# negative ones passed because a grep of nothing matches nothing. Every check
# that needs stripped code is therefore a named function run in THIS shell.
page_code_has()     { code "$page" | grep -q "$1"; }
page_code_has_not() { ! code "$page" | grep -qE "$1"; }

want "the behavioural suite exists and is non-empty"  test -s "$suite"
want "its runner exists and is non-empty"             test -s "$runner"
want "its runner is executable"                       test -x "$runner"

# ── The engine is asked before it is told ────────────────────────────────────
#
# Same shape as --no-persist, same reason, one probe. An engine that predates
# the colour verbs has them in argparse's `choices`, so `color` answers exit 2
# "invalid choice" — and an unprobed page would put that error on the screen of
# every machine running an older image.
want "the probe looks for the colour verb by name in --help" \
    grep -q 'indexOf("color-assign")' "$svc"
# And starts from no. A capability that defaults to yes is not probed for, it
# is assumed, and the assumption breaks on every image predating this branch —
# which the behavioural suite catches only because it runs an older engine.
want "the colour capability starts false, so an unprobed engine is not assumed" \
    grep -q "property bool engineCanColour: false" "$svc"
want "the probe and the --no-persist probe are the same process" \
    bash -c 'sed -n "/property var _capabilityProc/,/^    }/p" "$1" \
             | grep -q "engineCanColour"' _ "$svc"
want "the colour read is gated on the probe's answer" \
    bash -c 'sed -n "/function refreshColour/,/^    }/p" "$1" \
             | grep -q "engineCanColour"' _ "$svc"
want "an assignment is gated on the probe's answer too" \
    bash -c 'sed -n "/function assignProfile/,/^    }/p" "$1" \
             | grep -q "engineCanColour"' _ "$svc"
# Exactly two places may start a colour process, and both are behind the gate.
want "nothing outside refreshColour starts the colour read" \
    bash -c '[ "$(grep -c "_colourProc.running = true" "$1")" -eq 1 ]' _ "$svc"
want "nothing outside assignProfile starts an assignment" \
    bash -c '[ "$(grep -c "_assignProc.running = true" "$1")" -eq 1 ]' _ "$svc"

# ── The probe race ───────────────────────────────────────────────────────────
#
# refresh() starts the probe and refreshColour() needs its answer, and the page
# calls both — so "the probe is already in flight" is the normal case, not the
# exception. A version that recorded the wait only when it STARTED the probe
# fell through to the engineCanColour return and left the section permanently
# empty; it happened to work only because Component.onCompleted runs children
# before parents. The wait must be recorded on the answer, not on the start.
wait_is_on_the_answer() {
    local b
    b="$(sed -n '/function refreshColour/,/^    }/p' "$svc")"
    echo "$b" | grep -qE 'if \(!root\.engineProbed\) \{' \
        && ! echo "$b" | grep -qE 'if \(!root\.engineProbed && !root\._capabilityProc'
}
want "a colour read asked before the probe answers is remembered" wait_is_on_the_answer
want "the probe serves the read it made someone wait for" \
    bash -c 'sed -n "/property var _capabilityProc/,/^    }/p" "$1" \
             | grep -q "refreshColour()"' _ "$svc"

# ── The assignment is read back, not assumed ─────────────────────────────────
# The only thing that knows what colord accepted is the engine. An optimistic
# update is how a page ends up showing a profile that was never stored.
want "an assignment is followed by a read of what the engine actually has" \
    bash -c 'sed -n "/property var _assignProc/,/^    }/p" "$1" \
             | grep -q "refreshColour()"' _ "$svc"

# ── Colour is not part of the layout transaction ─────────────────────────────
# A bad layout can leave the machine with no usable output, which is why every
# layout change is staged behind a countdown. A colour profile cannot, it is
# not in display.json, and colord's database outlives the shell — so there is
# nothing for Save to write and nothing for Revert to put back. Mixing it into
# the draft would give Revert a job it cannot do.
want "the layout apply does not carry a colour assignment" \
    bash -c '! sed -n "/function _begin()/,/^    }/p" "$1" | grep -qi "colour\|color"' _ "$svc"
want "Keep does not carry a colour assignment" \
    bash -c '! sed -n "/function confirm()/,/^    }/p" "$1" | grep -qi "colour\|color"' _ "$svc"
want "the page runs no process of its own" \
    page_code_has_not 'Process \{' 

# ── What the page says ───────────────────────────────────────────────────────
want "the section is hidden on an engine that has no colour support" \
    grep -q "visible: DisplayService.engineCanColour" "$page"
want "the page binds the engine's reason rather than a sentence of its own" \
    page_code_has "DisplayService.curveReason"
# The finding this section exists for: colord runs, ships profiles, and had no
# devices at all. Zero is the number that explains an empty page.
want "the page says how many devices colord has registered" \
    page_code_has "DisplayService.colordRegistered"
want "the service reads that count from the engine's JSON" \
    bash -c 'sed -n "/property int colordRegistered/,/: 0/p" "$1" | grep -q "registered"' _ "$svc"

# THE PARAPHRASE CHECK. The engine composes the reason from what is actually
# installed and which compositor is running; the page must not have a second
# opinion. Comments are stripped first — the page's header explains the missing
# loader by name, and that is the right place for it.
paraphrase_free() {
    ! code "$page" | grep -qiE 'xcalib|dispwin|wl-gammactl|gammastep|argyll|pushed into the hardware|gamma LUT'
}
want "the page does not restate the engine's reasoning in its own words" paraphrase_free

# THE TRUNCATION CHECK, in two halves. CfgRow's description is
# maximumLineCount 2 + ElideRight, so the reason must not be one; and the
# element that does show it must place no line limit of its own.
want "the reason is not put in a row description, where it would be elided" \
    page_code_has_not "description:.*curveReason"
reason_element_does_not_clip() {
    local b
    b="$(sed -n '/id: reason/,/^            }/p' "$page")"
    [ -n "$b" ] \
        && echo "$b" | grep -q "wrapMode: Text.WordWrap" \
        && ! echo "$b" | grep -qE 'elide|maximumLineCount'
}
want "the element that shows the reason wraps it and never clips it" \
    reason_element_does_not_clip

# The profile pills are a Flow and can only wrap against a width they are
# given. In CfgRow's right-hand slot they get childrenRect, lay six profile
# names out in one line and push the readout off the left of the row.
want "the profile control is given a width to wrap against" \
    bash -c 'sed -n "/CfgSegmented {/,/^                }/p" "$1" \
             | grep -q "width:   parent.width - Theme.px(20)"' _ "$page"

# ── The suite may never touch the real colour daemon ─────────────────────────
#
# `color-assign` creates a colord device at `normal` scope, because a `temp`
# device dies with the D-Bus client that made it and colormgr is one-shot. And
# `colormgr delete-device` does NOT remove the device-to-profile rows it leaves
# in /var/lib/colord/mapping.db — measured. colord is a system D-Bus service,
# so no HOME and no PATH isolates it: a suite that ran the real verb would
# quietly accumulate assignments in the developer's own colour database.
want "the suite's engine is a fake under its own scratch directory" \
    grep -qE 'APEX_DISPLAY_ENGINE="\$W/engine/\$name"' "$runner"
want "the suite never names the installed engine" \
    bash -c '! grep -q "/usr/libexec/apex-display-apply" "$1"' _ "$runner"
want "the suite stubs colormgr so no path can reach the real daemon" \
    bash -c 'grep -qE "^for n in colormgr" "$1"' _ "$runner"
want "the suite asserts afterwards that colormgr was never reached" \
    grep -q 'reached colormgr' "$runner"
# Both engines, or the negative half of the probe is untested.
want "the suite runs against an engine that predates the colour verbs" \
    bash -c 'grep -q "^phase legacy" "$1" && grep -q "invalid choice" "$1"' _ "$runner"
want "the suite proves the older engine is never asked for colour" \
    grep -q "no colour verb is run against an engine that would reject it" "$suite"
# Effective visibility propagates from the parent, so a page built under an
# invisible loader answers `visible === false` everywhere and both visibility
# assertions become vacuous. It happened on the first run.
want "the suite builds the page visible, so a section's visibility means something" \
    bash -c 'sed -n "/id: pageLoader/,/sourceComponent/p" "$1" | grep -q "visible: true"' _ "$suite"
want "the suite asks Text itself whether the reason was truncated" \
    grep -q "shown.truncated === false" "$suite"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
