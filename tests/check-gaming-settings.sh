#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-gaming-settings.sh — structural invariants for P1-049's Gaming page.
#
#  ── Why this exists, and why it must not skip ───────────────────────────────
#  The properties that make this page honest are properties of the SOURCE: it
#  runs nothing on a timer, it escalates for nothing, exactly one command it can
#  run changes anything, and it re-measures instead of trusting an exit code.
#  None of those is visible in a running session, and no CI runner has a
#  compositor, so a behavioural QML suite always skips there. A suite that skips
#  proves nothing, and this repository has already shipped assertions that
#  passed because they never ran.
#
#  Everything here is grep-able and runs headless. It never invokes `apex`:
#  `apex mode set` changes the machine it runs on, and a test suite that
#  switched the developer's power policy to run an assertion would be a worse
#  bug than any it could catch.
#
#  ── THE INVARIANT WORTH THE MOST ASSERTIONS ─────────────────────────────────
#  No timer. P1-049 asks for a master "optimise games automatically" control,
#  and `apex mode set --auto` is documented one-shot: "APEX ships nothing that
#  re-evaluates this on a timer." A poller in the shell would be this page
#  inventing the daemon the OS declined to ship, and it would do it invisibly —
#  the page would simply appear to work, while quietly overriding a mode the
#  user had set by hand. So: no Timer in either file, and the one command that
#  changes anything is reachable from exactly one function.
#
#  Run from the repository root.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

svc="$root/src/services/config_tab/GamingService.qml"
page="$root/src/services/config_tab/pages/GamingPage.qml"
logic="$root/src/services/config_tab/gaming.js"
jstest="$root/tests/gaming-settings-test.js"

pass=0
fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ── Comment-stripped copies ─────────────────────────────────────────────────
# All three files explain at length what they deliberately do not do, and every
# invariant below is about what the page DOES. A comment mentioning `sudo` or a
# timer must not read as a violation. This is the difference between a guard and
# a prose detector.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
strip_comments() { grep -vE '^[[:space:]]*(//|#|\*|/\*)' "$1" > "$2"; }
csvc="$tmp/svc.qml";    strip_comments "$svc"    "$csvc"
cpage="$tmp/page.qml";  strip_comments "$page"   "$cpage"
clogic="$tmp/logic.js"; strip_comments "$logic"  "$clogic"
cjstest="$tmp/test.js"; strip_comments "$jstest" "$cjstest"

# ── The files exist and are reachable ───────────────────────────────────────
want "gaming.js exists and is non-empty"         test -s "$logic"
want "GamingService.qml exists and is non-empty" test -s "$svc"
want "GamingPage.qml exists and is non-empty"    test -s "$page"
want "the node suite exists and is non-empty"    test -s "$jstest"

want "GamingService is registered in src/qmldir" \
    grep -q "^singleton GamingService .*services/config_tab/GamingService.qml" "$root/src/qmldir"
want "GamingPage is registered in src/services/qmldir" \
    grep -q "^GamingPage ./config_tab/pages/GamingPage.qml" "$root/src/services/qmldir"
want "the page is reachable from PageRegistry" \
    grep -q "GamingPage {}" "$root/src/nexus/PageRegistry.qml"
want "PageRegistry declares a gaming entry" \
    grep -q '"id": "gaming"' "$root/src/nexus/PageRegistry.qml"
# The registry's list and its Components are two lists in one file; a page in
# one and not the other cannot render.
want "the gaming component is declared, not just referenced" \
    grep -q "property Component gamingComp" "$root/src/nexus/PageRegistry.qml"

# ── NOTHING RUNS ON A TIMER ─────────────────────────────────────────────────
want "the service has no Timer at all" \
    bash -c '! grep -q "Timer" "$1"' _ "$csvc"
want "the page has no Timer at all" \
    bash -c '! grep -q "Timer" "$1"' _ "$cpage"
# needsScreen exists to refcount a poller. This page has none, so claiming one
# would be asking both hosts to bind a property that does nothing.
want "the registry does not claim this page needs refcounting" \
    bash -c 'sed -n "/\"id\": \"gaming\"/,/}/p" "$1" | grep -q "\"needsScreen\": false"' \
        _ "$root/src/nexus/PageRegistry.qml"

# ── NOTHING ESCALATES ───────────────────────────────────────────────────────
# Installing the packages needs root. The page shows the command as text for the
# user to run, the way BlueprintService shows `sudo apex apply`, because `apex`
# reports across a privilege boundary it does not cross and a button here that
# ran sudo would throw that away.
want "the service never runs sudo" \
    bash -c '! grep -qE "\"sudo\"|pkexec|polkit" "$1"' _ "$csvc"
want "the page never runs sudo as a command" \
    bash -c '! grep -qE "\"sudo\"|pkexec|polkit" "$1"' _ "$cpage"
want "the install line has no button beside it" \
    bash -c '! sed -n "/title: \"Not installed yet\"/,/^    }$/p" "$1" | grep -q "CfgButton"' _ "$cpage"
want "the page still tells the user the command to run" \
    grep -q "installLine" "$cpage"

# ── EXACTLY ONE COMMAND CAN CHANGE ANYTHING ─────────────────────────────────
# Two read verbs and one write verb. `apex gaming` and `apex mode status` are
# read-only; `apex mode set` is the only thing here that moves the machine.
want "the service reads apex gaming --json" \
    grep -q '"gaming", "--json"' "$csvc"
want "the service reads apex mode status" \
    grep -q '"mode", "status"' "$csvc"
want "exactly one command in the service can write" \
    test "$(grep -c '"mode", "set"' "$csvc")" -eq 1
want "the write command is entered from exactly one place" \
    test "$(grep -c '_setProc.running = true' "$csvc")" -eq 1
want "and that place is setMode()" \
    bash -c 'sed -n "/function setMode/,/^    }$/p" "$1" | grep -q "_setProc.running = true"' _ "$csvc"
want "no other verb is spawned" \
    bash -c '! grep -qE "\"install\"|\"remove\"|\"game\", \"start\"|\"tier\"" "$1"' _ "$csvc"

# ── THE PAGE SPAWNS NOTHING AND DECIDES NOTHING ─────────────────────────────
# Criterion 5 asks for unsupported options to be hidden or disabled with a
# reason, and the reason has to be the CLI's. A page that ran its own `command
# -v` would be a second opinion about what is installed, which is how it starts
# disagreeing with the session launcher that actually fails.
want "the page can spawn no process at all" \
    bash -c '! grep -qE "Process|StdioCollector|Quickshell.Io" "$1"' _ "$cpage"
want "the page does not probe for the tools itself" \
    bash -c '! grep -qE "command -v|which |checkPassed\(" "$1"' _ "$cpage"
# `exec` alone would match RegExp.prototype.exec, which readModeStatus uses to
# parse a report. Named APIs only, or the assertion is a spelling test.
want "the logic module spawns nothing and opens nothing" \
    bash -c '! grep -qE "child_process|execSync|execFileSync|spawnSync|spawn\(|readFileSync|writeFileSync|require\(" "$1"' _ "$clogic"

# ── CHANGING A MODE IS MEASURED, NOT ASSUMED ────────────────────────────────
# Criterion 7: "changing a toggle actually changes effective policy and reads
# back the result". An exit code is not a read-back.
want "the write handler re-reads the status" \
    bash -c 'sed -n "/_setProc: Process/,/^    }$/p" "$1" | grep -q "_statusProc.running = true"' _ "$csvc"
want "it re-reads even when the switch failed" \
    bash -c 'sed -n "/_setProc: Process/,/^    }$/p" "$1" | sed -n "/onExited/,\$p" | grep -q "_statusProc.running = true"' _ "$csvc"
want "the readout comes from the status read, not from what was clicked" \
    grep -q "GamingService.policyLine" "$cpage"
want "every setMode call in the page is under an onClicked" \
    bash -c 'test "$(grep -c "GamingService.setMode(" "$1")" -eq "$(grep -B2 "GamingService.setMode(" "$1" | grep -c "onClicked")"' _ "$cpage"
want "the page does not switch modes on load" \
    bash -c '! grep -qE "Component.onCompleted.*setMode" "$1"' _ "$cpage"

# ── THE NOT-INSTALLED STATE COMES FIRST ─────────────────────────────────────
# Steam, gamescope and mangoapp are on-demand `apex install` packages and a
# fresh image has none of them. A page whose first screen is a row of controls
# would be offering to configure software that is not there.
want "the page has a not-installed section" \
    grep -q 'title: "Not installed yet"' "$cpage"
line_of() { grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1; }
want "what is missing is said before the controls are offered" \
    test "$(line_of "$cpage" 'title: "Not installed yet"')" -lt "$(line_of "$cpage" 'title: "Performance while you play"')"
want "each missing package says what it is for" \
    bash -c 'sed -n "/title: \"Not installed yet\"/,/^    }$/p" "$1" | grep -q "modelData.why"' _ "$cpage"
want "the blockers are the CLI's own sentences" \
    grep -q "GamingService.blockers" "$cpage"

# ── A FAILED PROBE IS NOT A MISSING FEATURE ─────────────────────────────────
# `apex gaming` EXITS NON-ZERO when Gaming Mode would not start. That is the
# answer, not a failure, and a page that latched itself off on it would tell a
# user with working games that its probe broke.
want "only one place decides the CLI is unavailable" \
    test "$(grep -c 'available = false' "$csvc")" -eq 1
want "and it is the gaming probe's exit handler" \
    bash -c 'sed -n "/_gamingProc: Process/,/^    }$/p" "$1" | grep -q "available = false"' _ "$csvc"
want "a non-zero exit alone does not clear availability" \
    bash -c 'sed -n "/_gamingProc: Process/,/^    }$/p" "$1" | sed -n "/onExited/,\$p" | grep -q "root.report === null"' _ "$csvc"
want "the not-available section offers a retry" \
    bash -c 'sed -n "/Not available on this image/,/^    }$/p" "$1" | grep -q "GamingService.refresh()"' _ "$cpage"
want "the explanation is the page's first section when the CLI is missing" \
    bash -c 'grep -B8 "Not available on this image" "$1" | grep -q "first: true"' _ "$cpage"
want "the CLI path is overridable for local testing" \
    grep -q "APEX_GAMING_CLI" "$csvc"

# ── THE NODE SUITE CANNOT SKIP ──────────────────────────────────────────────
# Against the comment-stripped copy: the suite's own header explains at length
# why it cannot skip, and a grep that read that as a skip would fail on a file
# whose only fault is saying what it does.
want "the node suite has no skip mechanism" \
    bash -c '! grep -qiE "skip|process.exit\(0\)" "$1"' _ "$cjstest"
want "the node suite exits non-zero on failure" \
    grep -q "process.exit(1)" "$jstest"
# `apex mode set` changes the machine it runs on. A suite that switched the
# developer's power policy to prove an assertion would be a worse bug than any
# it could catch.
want "no test invokes apex mode set" \
    bash -c '! grep -qE "child_process|execSync|spawnSync|execFileSync" "$1"' _ "$cjstest"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
