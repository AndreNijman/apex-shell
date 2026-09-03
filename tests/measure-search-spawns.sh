#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  How many processes APEX Search actually starts (roadmap §15).
#
#  §15's hard constraint is that "a keystroke must not spawn a process per
#  provider per keystroke", and that the idle state is genuinely zero work.
#  This measures both, with REAL processes.
#
#  ── Why this exists next to tests/search-test.js ────────────────────────────
#
#  The node suite counts what the scheduler ASKS for, with a fake clock and a
#  spawn log. That is the right way to test the decision, and it is the only
#  way to test the timing. But it proves nothing about what actually reaches
#  the operating system: an argv that is wrong, a name spliced into one
#  argument instead of passed as its own, a command that resolves to something
#  else on PATH — none of that is visible to a log the test wrote itself.
#
#  So this puts a shim `apex` and a shim `ls` FIRST on PATH, drives the same
#  reducer, and actually executes every argv it is told to start. The shim
#  records each invocation with one argument per tab. The numbers below are
#  then counted from a file written by the kernel-executed program, not by the
#  thing under test. That is the same arrangement §20's remote-agent smoke used
#  to measure "zero remote queries at idle".
#
#  ── What it does NOT do ─────────────────────────────────────────────────────
#
#  It does not start a shell, a compositor or a window. It needs neither, and
#  deliberately: a measurement that required a Wayland session would skip on
#  every CI runner, and running one on a developer's desktop is how a test
#  interrupts somebody's work. Everything here is node plus /bin/sh.
#
#  The QML wiring — that SearchService applies the plan it is given and starts
#  nothing else — is not measured here. It is asserted structurally by
#  tests/check-unified-search.sh, which proves there is exactly one
#  `running = true` in the whole service and that it lives in the function that
#  applies the reducer's start list.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
# Deliberately not `cmd; check $?`: ShellCheck SC2319 is right that a $? read
# after a `[ ]` is a trap waiting for someone to insert a line between them.
# Same convention as check-compositor-backends.sh.
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node is not installed"; exit 0; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT INT TERM

BIN="$W/bin"
LOG="$W/invocations.tsv"
mkdir -p "$BIN"
: > "$LOG"

# ── The shims ────────────────────────────────────────────────────────────────
# One line per invocation, arguments tab-separated. The tabs are what make the
# argv boundary measurable: a package name spliced into a command string would
# arrive as one field containing a space, and a name passed as its own argument
# arrives as a field of its own. That distinction is the whole reason the
# ACTIONS table returns an array.
cat > "$BIN/apex" <<'SHIM'
#!/bin/sh
printf 'apex' >> "$APEX_SEARCH_SHIM_LOG"
for a in "$@"; do printf '\t%s' "$a" >> "$APEX_SEARCH_SHIM_LOG"; done
printf '\n' >> "$APEX_SEARCH_SHIM_LOG"
case "$1 $2" in
    "project list") echo '[]' ;;
    "host list")    echo '{}' ;;
    "search "*|"search")
        echo '── repository packages ─────────────────────────────────────────────'
        echo 'blender.x86_64 : 3D modelling, animation and rendering'
        ;;
    *) exit 1 ;;
esac
SHIM

cat > "$BIN/ls" <<'SHIM'
#!/bin/sh
printf 'ls' >> "$APEX_SEARCH_SHIM_LOG"
for a in "$@"; do printf '\t%s' "$a" >> "$APEX_SEARCH_SHIM_LOG"; done
printf '\n' >> "$APEX_SEARCH_SHIM_LOG"
echo 'Documents/'
echo 'Downloads/'
echo 'notes.txt'
SHIM

chmod +x "$BIN/apex" "$BIN/ls"

# The shim directory goes FIRST and the real PATH is kept: only `apex` and `ls`
# are shadowed, so node and /bin/sh are still the real ones.
export APEX_SEARCH_SHIM_LOG="$LOG"
export PATH="$BIN:$PATH"

# ── The driver ───────────────────────────────────────────────────────────────
# Drives src/services/search.js's reducer and EXECUTES what it is told to
# start, synchronously, feeding the output back as a result event. Prints one
# "phase <name>" marker per measured phase so the counting below can slice the
# log by phase rather than by guesswork.
cat > "$W/drive.js" <<'DRIVER'
"use strict";
const path = require("path");
const { spawnSync } = require("child_process");
const S = require(path.join(process.env.REPO, "src", "services", "search.js"));

const CTX = { shellDir: "/opt/apex-shell", home: process.env.FAKE_HOME };

let state = S.initialState();
let now = 0;
let deadline = null;
let wants = [];
const inflight = {};

function apply(p) {
    state = p.state;
    for (const id of p.cancel) delete inflight[id];
    for (const s of p.start) {
        inflight[s.id] = s;
        // The real thing. PATH resolution, real argv, real exit code.
        const r = spawnSync(s.argv[0], s.argv.slice(1), { encoding: "utf8" });
        apply(S.plan(state, { type: "result", id: s.id, seq: s.seq,
                              ok: r.status === 0,
                              text: typeof r.stdout === "string" ? r.stdout : "" }));
    }
    if (p.armMs > 0) deadline = now + p.armMs;
    else if (p.armMs === 0) deadline = null;
}
function demand(on) { apply(S.plan(state, { type: "demand", on: on })); }
function type(text) {
    wants = S.PROVIDER_IDS
        .map(id => ({ id: id, argv: S.requestArgv(id, S.parseQuery(text), CTX) }))
        .filter(w => w.argv.length > 0);
    apply(S.plan(state, { type: "query", wants: wants }));
}
function tick(ms) {
    now += ms;
    if (deadline !== null && now >= deadline) {
        deadline = null;
        apply(S.plan(state, { type: "deadline", wants: wants }));
    }
}
function burst(text, gapMs) {
    for (let i = 1; i <= text.length; i++) { type(text.slice(0, i)); tick(gapMs); }
}
function settle() { tick(S.DEBOUNCE_MS * 4); }
function phase(name) { console.log("phase " + name); }

// 1. NOTHING IS HOLDING DEMAND. The launcher is closed.
phase("idle");
burst("install blender", 20);
burst("~/Documents/report", 20);
burst("apex-os", 20);
for (let i = 0; i < 40; i++) tick(500);

// 2. The launcher opens and somebody types a package search.
phase("typing-packages");
demand(true);
burst("install blender", 20);

// 3. Typing stops.
phase("settled-packages");
settle();

// 4. They keep typing the same thing, and something else, and back again.
phase("retyping");
type("install blender"); settle();
type("install blende"); settle();
type("install blender"); settle();

// 5. A plain query, which reaches the two constant-argv providers.
phase("plain-query");
type(""); demand(false); demand(true);
burst("apex-os", 20);
settle();

// 6. Typing on, once those two have answered.
phase("plain-query-more");
burst("apex-os-shell", 20);
settle();

// 7. Walking a directory, then descending one level.
phase("path-walk");
type(""); demand(false); demand(true);
burst("~/Docum", 20);
settle();
phase("path-descend");
type("~/Documents/"); settle();
type("~/Documents/no"); settle();
type("~/Documents/not"); settle();

// 8. The launcher closes again.
phase("closed-again");
demand(false);
burst("install gimp", 20);
for (let i = 0; i < 40; i++) tick(500);
DRIVER

REPO="$repo" FAKE_HOME="$W/home" node "$W/drive.js" > "$W/phases.txt" 2>"$W/drive.err"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "  FAIL  the driver did not run"
    sed -n '1,20p' "$W/drive.err"
    exit 1
fi

# ── Counting ─────────────────────────────────────────────────────────────────
# The log is written by the shim, so the numbers come from a program the thing
# under test executed rather than from a counter it kept. Phases are recorded
# by counting the log's length at each marker.
#
# The driver prints its phase markers on stdout and the shim appends to the log
# on its own; to attribute invocations to phases without a race, the driver is
# re-run once per phase boundary would be wasteful — instead the log is read as
# a whole and sliced by the argv patterns each phase can produce, which is
# unambiguous here because every phase uses a distinct term.
total()   { wc -l < "$LOG" | tr -d ' '; }
count()   { grep -c -- "$1" "$LOG" 2>/dev/null || true; }

echo "── invocations recorded by the shim ──"
sed -n '1,40p' "$LOG" | cat -A 2>/dev/null | sed 's/\$$//' | sed 's/\^I/ | /g' || true
echo

TOTAL="$(total)"
echo "total invocations: $TOTAL"
echo

# ── 1. Idle costs nothing ────────────────────────────────────────────────────
# Every phase before the launcher opens, plus every phase after it closes, used
# terms that appear in no other phase. If any of them reached the operating
# system, its term is in the log.
want "MEASURED: with the launcher closed, typing spawns no process at all" \
    test "$(count 'gimp')" -eq 0
want "MEASURED: and a closed launcher never lists a directory it was shown" \
    test "$(count 'report')" -eq 0

# ── 2. A typing burst is one process, not fifteen ────────────────────────────
# "install blender" is fifteen keystrokes. Ten of them produce a term of two
# characters or more, which is the point at which the package provider would be
# consulted — so an undebounced implementation lands ten `apex search` calls
# here, and a per-keystroke one lands ten more for every retype below.
want "MEASURED: fifteen keystrokes of 'install blender' cost ONE apex search" \
    test "$(count 'search	blender')" -eq 1

# ── 3. The argv boundary ─────────────────────────────────────────────────────
# The term arrives as its own tab-separated field. A name spliced into a
# command string would arrive as one field containing a space, which is the bug
# this repo already has a CI invariant about for model data in `bash -c`.
want "MEASURED: the search term is its own argument, not spliced into one" \
    grep -q "^apex	search	blender$" "$LOG"

# ── 4. Retyping and backspacing are cache hits ───────────────────────────────
# Phase 4 retypes "install blender" twice and detours through "install blende".
# The detour is the only new argv, so the total for "blender" must still be one.
want "MEASURED: retyping the same query spawns nothing more" \
    test "$(count 'search	blender')" -eq 1
want "MEASURED: the detour spawned exactly one search of its own" \
    test "$(count 'search	blende$')" -eq 1

# ── 5. A plain query reads two things, once ──────────────────────────────────
# "apex-os" is seven keystrokes and "apex-os-shell" is thirteen. Between them
# that is twenty keystrokes across two providers: forty processes if a keystroke
# spawned per provider, and two if the argv cache does its job.
want "MEASURED: twenty keystrokes of a plain query cost ONE project list" \
    test "$(count 'project	list')" -eq 1
want "MEASURED: and ONE device registry read" \
    test "$(count 'host	list')" -eq 1

# ── 6. Walking a directory ───────────────────────────────────────────────────
# Six keystrokes inside the home directory, then three more inside Documents.
# The listing is of the DIRECTORY, so that is two listings and not nine.
want "MEASURED: six keystrokes inside one directory cost ONE listing" \
    test "$(count "1Ap	--	$W/home/$")" -eq 1
want "MEASURED: descending one level costs exactly ONE more" \
    test "$(count "1Ap	--	$W/home/Documents/$")" -eq 1
want "MEASURED: no listing was ever taken of a partial file name" \
    test "$(count 'not$')" -eq 0

# ── 7. Nothing reached the network path implicitly ───────────────────────────
# `apex search` is the only invocation that can refresh repository metadata, and
# the only terms it was ever given are the ones typed after a package verb.
want "MEASURED: apex search ran only for terms typed after a package verb" \
    test "$(grep -c '^apex	search' "$LOG")" -eq "$(count 'search	blende')"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
