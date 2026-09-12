#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-lid-page-test.sh — Config → Closing the Lid, built and drawn on a
#  compositor of its own (roadmap P1-063, criterion 6).
#
#  ── Why this runner exists ──────────────────────────────────────────────────
#
#  The privacy page landed with three kinds of verification and none of them
#  was a running page: qmllint proved the syntax, a node suite proved what the
#  parser decides, and a static checker proved the wiring. The first run that
#  actually instantiated it found, in the first second, a defect all three had
#  missed:
#
#      WARN scene: PrivacyPage.qml[176:-1]:
#          TypeError: Cannot read property 'brokered' of null
#
#  A binding inside an invisible section is still evaluated. This page has
#  strictly more nested objects than that one — logind, decision, work,
#  thermal, charge, vpn, period, and two arrays inside period — so the
#  `unreadable` phase below is not error-handling politeness. It is the phase
#  that would find that bug, and a TypeError anywhere in a phase log is a hard
#  failure here.
#
#  ── On a compositor of its own, and that is not a detail ────────────────────
#
#  quickshell opens a window. This runner takes a headless wlroots compositor
#  from tests/lib/headless.sh with a private HOME and a private
#  XDG_RUNTIME_DIR, and the library aborts the run if the socket it ends up
#  talking to is not inside that directory. Nothing lands on anybody's desk.
#
#  ── The `apex` here is a STUB, and it has to be ─────────────────────────────
#
#  `apex lid pin` WRITES the invoking user's ~/.config/apex/lid.toml, and the
#  ROOT driver reads that file to decide whether the machine suspends when its
#  lid shuts. A suite that ran the real command would repin the laptop it is
#  running on, several times per run, and leave it repinned. The stub answers
#  `status --json` and `report --json` from tests/fixtures/lid/ and records
#  every argv. Never `headless_unstub apex` here — that hands the page the real
#  binary and the real policy file.
#
#  ── Five phases ─────────────────────────────────────────────────────────────
#
#    docked       the real L16 capture: an external display, so logind ignores
#                 the lid and APEX is not why
#    working      undocked and pinned on, with a real closed period to report
#    guard        a thermal guard, which must outrank the docked frame
#    unreadable   `apex` fails. The page must say so and must not throw
#    pixels       the built page is rasterised and the PNG inspected
#
#  `pixels` is the only one that proves the scene graph ran. Everything else
#  reads an object tree, and a page whose every binding is correct and which
#  paints nothing would pass all of it.
#
#  ── Two of the five fixtures are DERIVED, and the derivation is here ────────
#
#  Under `APEX_LID_ROOT` the driver logs rather than runs every external
#  program, so busctl never answers and `logind.docked` comes back null: the
#  binary cannot produce an undocked machine. The `working` and `guard`
#  documents are therefore built by editing `logind` on documents the binary
#  DID produce, with python3 and no other dependency, so every other field in
#  them is still serde's own output.
#
#  Skips cleanly (status 0) without quickshell or without a compositor.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=tests/lib/headless.sh
. "$here/lib/headless.sh"

headless_require quickshell

staged="$root/.lid-page-test.qml"
cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin

W="$HEADLESS_W"
CALLS="$W/apex-calls.log"
: > "$CALLS"
FIX="$here/fixtures/lid"

# ── the derived documents ───────────────────────────────────────────────────
# Edits `logind` and nothing else. A missing python3 is a FAILED suite and not
# a skipped one: two of five phases would silently stop asserting anything.
if ! command -v python3 >/dev/null 2>&1; then
    echo "FATAL: python3 is required to derive the undocked fixtures" >&2
    exit 2
fi
python3 - "$FIX" "$W" <<'PY'
import json, os, sys
fix, work = sys.argv[1], sys.argv[2]

def derive(src, dst, logind, **over):
    d = json.load(open(os.path.join(fix, src)))
    d["logind"] = logind
    d.update(over)
    json.dump(d, open(os.path.join(work, dst), "w"), indent=2)

ACTING = {"docked": False, "external_displays": 0, "acts_on_lid": True,
          "block_inhibited": "idle:handle-lid-switch"}
# Undocked, pinned on, and the lock genuinely held.
derive("status-keep-working.json", "status-working.json", ACTING)
# A thermal guard on a machine that IS docked: the ordering assertion.
derive("status-guard-thermal.json", "status-guard.json",
       json.load(open(os.path.join(fix, "status-l16-docked.json")))["logind"])
PY

# ── the stub ────────────────────────────────────────────────────────────────
# Overwrites the one headless_begin installed. Every invocation is recorded
# before anything else happens, so an assertion about what the page ASKED FOR
# holds even when the answer is a failure.
cat > "$W/bin/apex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APEX_LP_CALLS"

if [[ "${1:-}" != "lid" ]]; then
    exit 0
fi

case "${2:-}" in
status)
    if [[ "${APEX_LP_FAIL:-0}" == "1" ]]; then
        # What a real refusal looks like: a sentence on stderr and nothing at
        # all on stdout. The page must not read that as a calm machine.
        echo "apex: the lid policy could not be read" >&2
        exit 1
    fi
    cat "$APEX_LP_STATUS"
    exit 0
    ;;
report)
    if [[ "${APEX_LP_FAIL:-0}" == "1" ]]; then
        echo "apex: the record could not be read" >&2
        exit 1
    fi
    cat "$APEX_LP_REPORT"
    exit 0
    ;;
pin)
    # Records its argv above and writes nothing. The real one rewrites the
    # owner's ~/.config/apex/lid.toml, which the root driver then obeys.
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$W/bin/apex"

# Quickshell refuses to import QML modules from outside the directory holding
# the entry point, so the suite is staged into the repository root.
cp "$here/lid-page-test.qml" "$staged"

headless_start || exit 0

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

phase() {
    local name="$1" status="$2" report="$3" failread="$4"
    local log="$W/$name.log"
    : > "$CALLS"

    echo
    echo "── $name ────────────────────────────────────────────────"

    ( cd "$root" && env \
        APEX_LP_PHASE="$name" \
        APEX_LP_CALLS="$CALLS" \
        APEX_LP_STATUS="$status" \
        APEX_LP_REPORT="$report" \
        APEX_LP_FAIL="$failread" \
        APEX_LP_GRAB="$W/lid-page.png" \
        QT_LOGGING_RULES="qml=true" \
        timeout 180 quickshell -p "$staged" ) > "$log" 2>&1

    sed -i -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //' "$log"
    grep -E "^(  PASS|  FAIL)" "$log" || true

    # A page that does not build prints a QML error and no assertions at all,
    # which without this reads as "0 of 0 passed".
    if grep -qE "is not a type|Cannot assign|Unable to assign|Failed to load configuration" "$log"; then
        bad "the $name page built without QML errors"
        grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration" "$log" \
            | head -5 | sed 's/^/          /'
    else
        ok "the $name page built without QML errors"
    fi

    # THE assertion this runner was written for. A TypeError in a binding does
    # not stop the page loading, does not fail any static check, and does not
    # show up in the object tree afterwards — the binding simply produced
    # nothing. It is only ever visible in a log from a page that ran.
    if grep -qE "TypeError|ReferenceError" "$log"; then
        bad "no binding on the $name page threw"
        grep -E "TypeError|ReferenceError" "$log" | sort -u | head -5 | sed 's/^/          /'
    else
        ok "no binding on the $name page threw"
    fi

    local summary got_pass got_fail
    summary="$(grep -o 'passed=[0-9]* failed=[0-9]*' "$log" | tail -1)"
    if [[ -z "$summary" ]]; then
        bad "the $name phase ran to completion"
        tail -20 "$log" | sed 's/^/          /'
        return
    fi
    ok "the $name phase ran to completion"
    got_pass="${summary%% *}"; got_pass="${got_pass#passed=}"
    got_fail="${summary##*failed=}"
    pass=$((pass + got_pass))
    fail=$((fail + got_fail))
    echo "  ($name: passed=$got_pass failed=$got_fail)"
}

phase docked     "$FIX/status-l16-docked.json" "$FIX/report-empty.json"  0
phase working    "$W/status-working.json"      "$FIX/report-period.json" 0
phase guard      "$W/status-guard.json"        "$FIX/report-empty.json"  0
phase unreadable "$FIX/status-l16-docked.json" "$FIX/report-empty.json"  1
phase pixels     "$W/status-working.json"      "$FIX/report-period.json" 0

# ── the pixels, read back ───────────────────────────────────────────────────
# The QML half asserted the grab came back. This half asserts the result is not
# a blank rectangle, because a page that laid every row out correctly and
# painted nothing would satisfy every other assertion in this file. Pure
# stdlib: a PNG is zlib over filtered scanlines, and nothing here needs an
# image library the CI runner would have to install.
echo
echo "── the raster ────────────────────────────────────────────"
png="$W/lid-page.png"
if [ ! -f "$png" ]; then
    bad "the page was written out as a PNG"
elif ! command -v python3 >/dev/null 2>&1; then
    echo "  note: python3 is missing, so the PNG's contents were not inspected"
    ok "the page was written out as a PNG ($(wc -c < "$png") bytes)"
else
    ok "the page was written out as a PNG ($(wc -c < "$png") bytes)"
    # A floor well under what this machine measures, so a font substitution or
    # a theme change does not trip it, and far above a flat fill (1) or a fill
    # with a couple of panels on it (a few dozen). The width is exact; the
    # height only has a floor, because a compositor trims it for its own
    # decorations.
    if python3 "$here/lib/png-ink.py" "$png" 5000 980 400; then
        ok "the raster is the right size and carries ink: the page painted something"
    else
        bad "the raster is the wrong size, blank, or near-blank"
    fi
fi

# The sandbox is deleted on the way out, so the one artefact worth keeping has
# to be asked for. `LID_PAGE_PNG=/tmp/l.png ./tests/run-lid-page-test.sh` leaves
# the drawn page somewhere it can be looked at.
if [ -n "${LID_PAGE_PNG:-}" ] && [ -f "$png" ]; then
    cp "$png" "$LID_PAGE_PNG" && echo "  kept: $LID_PAGE_PNG"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
