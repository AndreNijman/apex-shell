#!/usr/bin/env bash
# Static invariants for §15's unified search and command surface (P3).
#
# ── Why this exists next to the other two suites ─────────────────────────────
# tests/search-test.js proves what src/services/search.js DECIDES.
# tests/measure-search-spawns.sh proves how many processes those decisions
# actually start. Neither one can prove that the QML obeys either of them: a
# SearchService that started a process of its own, or an AppLauncher that
# called activate() from a click handler instead of through the commit rule,
# would pass both suites and ship a launcher that reboots on Enter.
#
# So the invariants here are all of the form "the QML cannot go around the
# decision half". They are greps, they run headless, and each is one careless
# edit away from regressing with no visible symptom.
#
# ── FIVE WAYS A GREP-STYLE CHECK LIES, AND WHAT IS DONE ABOUT EACH ───────────
#
# 1. A COMMENT SATISFIES IT. This repo has shipped five checks that were
#    satisfied by the prose in the very file they guarded. Every check below
#    runs against comment-stripped input, and the inverse mutant at the bottom
#    appends prose quoting every string these greps look for — including
#    `Qt.ControlModifier`, `commitDecision` and `running = true` — and requires
#    the suite to stay GREEN. A check a comment can break punishes people for
#    explaining themselves; a check a comment can satisfy is worse.
#
# 2. ANOTHER LINE OF REAL CODE SATISFIES IT. The subtler version, and the one
#    comment-stripping does nothing about. `running = true` appears three times
#    in SearchService for three different reasons, so a file-wide grep would
#    still pass after the one in _spawn moved somewhere it must not be. Checks
#    that care about WHERE a line is are scoped to a function body by `fn_body`
#    / `in_fn`, never run against the whole file.
#
# 3. THE PIPE BINDS TO THE FUNCTION. Written inline as
#        want "…" code "$f" | grep -qE '…'
#    the pipe binds to the whole `want` invocation: `want` runs only `code`,
#    which succeeds because the file exists, and greps the verdict into a pipe
#    nobody reads. Two assertions passed unconditionally that way in §20's
#    suite. Every check here goes through a helper function for that reason.
#
# 4. THE MUTANT NEVER APPLIED. A self-test that mutates a copy and watches it
#    go red proves nothing if the sed silently matched nothing — the copy is
#    then identical and the verdict is about the original. Every mutant below
#    is diffed against its source and the run aborts if it did not change.
#    Each red mutant is also bounded: a targeted mutant breaks one or two
#    checks, and one that breaks fifteen has damaged the copy rather than the
#    invariant, which is a different outcome and must not read as success.
#
# 5. `producer | grep -q` UNDER `set -o pipefail`. A NEW ONE, found by this
#    file's own baseline check, and it is worth writing down because the
#    obvious spelling of every helper here has it:
#
#        has() { code "$1" | grep -qE "$2"; }     # WRONG under pipefail
#
#    `grep -q` exits the instant it matches. If the producer on the left is
#    still writing, it takes SIGPIPE and exits 141, and `pipefail` makes THAT
#    the status of the pipeline — so the check reports FAIL for a pattern that
#    is present. Whether it happens depends on how much of the file is left to
#    write when the match is found, which means:
#
#      * a pattern near the TOP of a long file fails
#      * the same pattern near the BOTTOM passes
#      * `grep -c` is unaffected, because it reads to the end
#
#    Eleven checks here failed that way on a correct tree, and every one of
#    them was a pattern in the first third of a 800-line file. It is the
#    nastiest variant of all of the above, because the check is wrong in the
#    SAFE direction on a small file and flips as the file grows.
#
#    Every helper below therefore reads its producer through a process
#    substitution, so the exit status is grep's and nothing else's.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0
fail=0
quiet=0
ok()  { [ "$quiet" -eq 1 ] || echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { [ "$quiet" -eq 1 ] || echo "  FAIL  $1"; fail=$((fail + 1)); }
# Deliberately not `cmd; check $?`: ShellCheck SC2319 is right that a $? read
# after a `[ ]` is a trap waiting for someone to insert a line between them.
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ── comment-stripped views ───────────────────────────────────────────────────
# Whole-line comments only. A trailing comment on a real line of code is fine:
# the code is still there, which is what these checks ask about.
code()       { grep -vE '^[[:space:]]*//' "$1" 2>/dev/null; }
qmldircode() { grep -vE '^[[:space:]]*#'  "$1" 2>/dev/null; }

# Process substitution, never a pipe — see lie #5 in the header. The status of
# each of these is grep's alone.
has()   {   grep -qE "$2" < <(code "$1"); }
lacks() { ! grep -qE "$2" < <(code "$1"); }
countin() { grep -cE "$2" < <(code "$1"); }
# `test N -eq M` on a count, wrapped so the pipe cannot bind to `want`.
count_is() { [ "$(countin "$1" "$2")" -eq "$3" ]; }

qmldir_has()   {   grep -qE "$2" < <(qmldircode "$1"); }
qmldir_lacks() { ! grep -qE "$2" < <(qmldircode "$1"); }

# fn_body <file> <ERE matching the opening line> — that declaration's body,
# ending at the first closing brace indented the same as the opening line.
# Comment lines are stripped on the way out.
#
# This is what makes "the spawn happens in _spawn" mean that, rather than "the
# string appears somewhere in the file".
fn_body() {
    # The pattern goes through the ENVIRONMENT, not -v. awk processes backslash
    # escapes in a -v assignment, so `function _spawn\(id` would arrive as
    # `function _spawn(id` — a regex with a GROUP round `id`, matching nothing.
    # That cost three silently-passing checks in §20's suite.
    FN_PAT="$2" awk '
        !inside && $0 ~ ENVIRON["FN_PAT"] { inside = 1; indent = match($0, /[^ ]/); print; next }
        inside {
            print
            if ($0 ~ /^[ ]*\}/ && match($0, /[^ ]/) == indent) exit
        }
    ' "$1" 2>/dev/null | grep -vE '^[[:space:]]*//'
}
in_fn()     {   grep -qE "$3" < <(fn_body "$1" "$2"); }
not_in_fn() { ! grep -qE "$3" < <(fn_body "$1" "$2"); }
fn_count_is() { [ "$(grep -cE "$3" < <(fn_body "$1" "$2"))" -eq "$4" ]; }
# First matching line number WITHIN a function body, or "" — for the two
# ordering checks that care where inside a body a line sits.
fn_lineof() { grep -nE "$3" < <(fn_body "$1" "$2") | head -1 | cut -d: -f1; }

# Line number of the first comment-stripped match, or "" — for the ordering
# checks, where WHICH LINE matters and mere presence does not.
lineof() { grep -nE "$2" < <(code "$1") | head -1 | cut -d: -f1; }
before() {
    local a b
    a="$(lineof "$1" "$2")"
    b="$(lineof "$1" "$3")"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

check_tree() {
    local r="$1"
    local js="$r/src/services/search.js"
    local svc="$r/src/services/SearchService.qml"
    local al="$r/src/services/AppLauncher.qml"
    local run="$r/src/scripts/SearchRun.sh"
    local dash="$r/src/popups/Dashboard.qml"
    local qmldir="$r/src/qmldir"
    local sdir="$r/src/services/search"

    # ── the parts exist ──────────────────────────────────────────────────────
    # First and unconditionally. Every check below is a grep, and a grep
    # against a file that is not there finds nothing — which every `lacks`
    # check would happily read as a pass.
    local f
    for f in "$js" "$svc" "$al" "$run" "$dash" "$qmldir"; do
        want "$(basename "$f") exists and is non-empty" test -s "$f"
    done
    want "the provider directory exists" test -d "$sdir"

    # Eleven providers, one per §15 category. A count rather than a list of
    # names, so adding a twelfth is a deliberate edit here too.
    want "there are eleven built-in providers" \
        test "$(find "$sdir" -name '*Provider.qml' 2>/dev/null | wc -l)" -eq 11

    # ── ONE SOURCE OF TRUTH FOR EVERY DECISION ───────────────────────────────
    # The whole point of search.js is that the shell and the tests run the same
    # file. A second copy of any of this in QML would drift, and the drift
    # would be silent and safety-relevant.
    want "SearchService imports the shared decision logic" \
        has "$svc" 'import "search\.js" as Search'
    want "AppLauncher imports the shared decision logic" \
        has "$al" 'import "search\.js" as Search'
    local fn
    for fn in providerWants requestArgv plan rowsFrom merge initialState cached; do
        want "SearchService routes $fn through search.js" \
            has "$svc" "Search\.$fn\("
    done
    for fn in commitDecision rowId; do
        want "AppLauncher routes $fn through search.js" \
            has "$al" "Search\.$fn\("
    done

    # ── THE PROVIDERS OWN NO SUBPROCESS ──────────────────────────────────────
    # This is what makes "a provider cannot spawn" structural rather than
    # reviewed. Quickshell.Io carries Process, FileView and Socket — raw
    # system, files and network in one import — and a provider that had one
    # would be a second, ungated way to reach the operating system, outside
    # both the ACTIONS table and requestArgv().
    local p
    for p in "$sdir"/*.qml; do
        [ -e "$p" ] || continue
        want "$(basename "$p") imports no Quickshell.Io" \
            lacks "$p" '^[[:space:]]*import[[:space:]]+Quickshell\.Io'
        want "$(basename "$p") declares no Process, FileView or Socket" \
            lacks "$p" '\b(Process|FileView|Socket)[[:space:]]*\{'
        # The contract a third-party launcher-provider plugin uses, verbatim.
        # A built-in that drifted from it would make "the built-ins go through
        # the same contract" a claim rather than a fact.
        want "$(basename "$p") declares the plugin contract's api property" \
            has "$p" '^[[:space:]]*property var[[:space:]]+api:[[:space:]]*null'
        want "$(basename "$p") declares the plugin contract's query property" \
            has "$p" '^[[:space:]]*property string[[:space:]]+query:'
        want "$(basename "$p") declares the plugin contract's results property" \
            has "$p" '^[[:space:]]*readonly property var[[:space:]]+results:'
    done

    # ── EXACTLY ONE PLACE STARTS A PROVIDER SUBPROCESS ───────────────────────
    # `running = true` appears three times in SearchService for three different
    # reasons, so a file-wide grep proves nothing about any of them. Each is
    # pinned to the function it belongs in.
    want "the service starts exactly three kinds of process, and no more" \
        count_is "$svc" 'running = true' 3
    want "the provider process is started in _spawn" \
        in_fn "$svc" '^[[:space:]]*function _spawn\(' 'pr\.running = true'
    want "_spawn starts exactly one process" \
        fn_count_is "$svc" '^[[:space:]]*function _spawn\(' 'running = true' 1
    want "_spawn is the only function that starts a provider process" \
        not_in_fn "$svc" '^[[:space:]]*function _applyPlan\(' 'running = true'
    # The reducer decides; _applyPlan carries it out. A _spawn called from
    # anywhere else would be a process the plan never asked for.
    want "_spawn is called from _applyPlan and nowhere else" \
        count_is "$svc" 'root\._spawn\(' 1
    want "and that one call is inside _applyPlan" \
        in_fn "$svc" '^[[:space:]]*function _applyPlan\(' 'root\._spawn\('
    # Four call sites: demand changing, the query changing, the debounce
    # firing, and a subprocess finishing. Every one of them hands the result to
    # _applyPlan. A fifth would be a state transition nothing carried out.
    want "every plan is read, and there are exactly four of them" \
        count_is "$svc" 'Search\.plan\(root\._state' 4

    # ── THE SLOT IS CLEARED BEFORE THE KILL ──────────────────────────────────
    # In that order, so the exited() the kill produces is ignored rather than
    # recorded against whatever is asked for next. §20's remote agent sweep had
    # this the other way round and one device's answer landed on another
    # device's row. Ordering, not presence: both lines survive a reversal, so
    # only an order-aware check sees it.
    want "_cancel clears the slot before it kills" \
        in_fn "$svc" '^[[:space:]]*function _cancel\(' 'pr\.slot = -1'
    want "the slot clear precedes the kill inside _cancel" \
        test "$(fn_lineof "$svc" '^[[:space:]]*function _cancel\(' 'pr\.slot = -1')" -lt \
             "$(fn_lineof "$svc" '^[[:space:]]*function _cancel\(' 'pr\.running = false')"
    # And the answer to a cleared slot is dropped rather than believed.
    want "a result for a cleared slot is dropped" \
        in_fn "$svc" '^[[:space:]]*function _finish\(' 'if \(seq < 0\)'

    # ── A STALE ANSWER IS DROPPED IN THE REDUCER TOO ─────────────────────────
    # Two answers can come back in either order; only the one whose token still
    # matches is believed. Without the comparison a cancelled request's output
    # is cached and later merged, which is a result for a query the user has
    # already moved on from.
    want "the reducer compares the request token before believing a result" \
        in_fn "$js" '^function plan\(state, event\)' 'p\.seq !== e\.seq'

    # ── NOTHING RUNS WITH NOBODY LOOKING ─────────────────────────────────────
    want "the service exposes refCount, so ServiceRef can hold it" \
        has "$svc" '^[[:space:]]*property int refCount:'
    want "the launcher holds a ServiceRef on the search service" \
        has "$al" 'ServiceRef \{ service: SearchService'
    want "the launcher holds a ServiceRef on the compositor's window list" \
        has "$al" 'ServiceRef \{ service: CompositorService\.windowsRef'
    # Bound to genuine on-screen state, never to Item visibility: an Item inside
    # a hidden window still reports visible, which is how the stats page kept
    # six pollers running after the dashboard was closed.
    want "the refs are bound to on-screen state, not to Item visibility" \
        has "$al" 'active: root\.onScreen'
    want "the dashboard tells the launcher whether it is on screen" \
        has "$dash" 'onScreen: root\.pageLive && root\.page === "launcher"'
    want "no timer in the service runs unconditionally" \
        lacks "$svc" '^[[:space:]]*running:[[:space:]]*true[[:space:]]*$'
    # A repeating timer anywhere on the keystroke path is what turns a search
    # into a poll. Same invariant check-plugin-platform.sh makes of the plugin
    # hosts, for the same reason.
    want "the debounce timer is explicitly one-shot" \
        in_fn "$svc" 'readonly property Timer _debounce' 'repeat: false'
    want "closing the launcher clears the query" \
        in_fn "$svc" '^[[:space:]]*onActiveChanged:' 'root\.query = ""'

    # ── THE COMMIT RULE IS THE ONLY WAY TO RUN ANYTHING ──────────────────────
    # This is the §15 requirement with teeth, and it is one careless click
    # handler away from being untrue. activate() is what runs a row; press() is
    # what consults the rule. If anything else could call activate(), the
    # preview would be optional.
    want "the launcher consults the commit rule exactly once" \
        count_is "$al" 'Search\.commitDecision\(' 1
    want "and it is inside press()" \
        in_fn "$al" '^[[:space:]]*function press\(' 'Search\.commitDecision\('
    want "activate() is called from exactly one place" \
        count_is "$al" 'root\.activate\(' 1
    want "and that place is press()" \
        in_fn "$al" '^[[:space:]]*function press\(' 'root\.activate\('
    want "press() only runs a row when the rule said RUN" \
        in_fn "$al" '^[[:space:]]*function press\(' 'verdict === Search\.COMMIT\.RUN'
    want "press() only previews when the rule said PREVIEW" \
        in_fn "$al" '^[[:space:]]*function press\(' 'verdict === Search\.COMMIT\.PREVIEW'
    # The rule is fed the two identities it needs. Without both it degrades to
    # "Ctrl+Enter commits", which Ctrl+Enter pressed straight from the list
    # satisfies with no preview ever shown.
    want "the rule is told which row the preview belongs to" \
        in_fn "$al" '^[[:space:]]*function press\(' '"previewedId": +root\.previewId'
    want "the rule is told which row is selected right now" \
        in_fn "$al" '^[[:space:]]*function press\(' '"selectedId": +root\.selectedId'
    # Plain Return and Ctrl+Return are different logical keys, so a held Return
    # cannot repeat through a preview into a commit.
    want "the modifier is read from the key event, not assumed" \
        has "$al" 'event\.modifiers & Qt\.ControlModifier'
    want "Ctrl+Return is a different key from Return" \
        has "$al" 'root\.press\(ctrl \? "commit" : "enter", ctrl\)'
    # The mouse path goes through the same function with a key of its own,
    # rather than a second route that skips the rule.
    want "the mouse commit path goes through press() too" \
        has "$al" 'root\.press\("button", false\)'
    want "a click on a row previews rather than running" \
        has "$al" 'root\.press\("enter", false\)'
    # An action becomes a process in exactly one place, downstream of the rule.
    want "an action is run in exactly one place" \
        count_is "$al" 'SearchService\.runAction\(' 1
    want "and that place is _perform, which activate() reaches" \
        in_fn "$al" '^[[:space:]]*function _perform\(' 'SearchService\.runAction\('

    # ── THE PREVIEW SHOWS WHAT WILL RUN ──────────────────────────────────────
    want "the preview names the privilege the action needs" \
        has "$al" 'Runs as: " \+ root\.previewInfo\.permission'
    want "the preview shows the command line search.js built from the argv" \
        has "$al" 'root\.previewInfo\.commandLine'
    want "the preview says when something cannot be undone" \
        has "$al" 'This cannot be undone\.'
    # `apex resolve` is read-only and needs no root, which is what makes it
    # usable as a preview. It must be started by ACTIVATION and never by
    # selection: arrowing down twenty package rows must not run twenty of them.
    want "resolve is started when a preview opens" \
        in_fn "$al" '^[[:space:]]*function openPreview\(' 'SearchService\.resolve\('
    want "resolve is started nowhere else" \
        count_is "$al" 'SearchService\.resolve\(' 1
    want "moving the selection does not open a preview" \
        not_in_fn "$al" '^[[:space:]]*Keys\.onDownPressed:' 'openPreview'

    # ── PLUGIN ROWS KEEP THEIR OWN GUARANTEES ────────────────────────────────
    # check-plugin-platform.sh owns these; they are repeated here because §15
    # rewrote the file they live in, and a rewrite is exactly when an ordering
    # invariant gets lost.
    want "the plugin host is still instantiated by the launcher" \
        has "$al" 'PluginLauncher \{'
    want "plugin rows are still appended, never merged into the ranking" \
        has "$al" 'concat\(providers\.rows\)'
    want "the plugin branch still precedes the DesktopEntry path" \
        before "$al" 'entry\.kind === "plugin"' 'if \(entry\.entry\)'
    want "the plugin branch still precedes the Exec path" \
        before "$al" 'entry\.kind === "plugin"' 'launch\(entry\.exec\)'
    # A built-in row that names an action is dispatched BEFORE the DesktopEntry
    # and Exec branches too, for the same reason: an action row falling through
    # to `bash -c` would be running a command chosen by string matching.
    want "an action row is dispatched before the Exec path" \
        before "$al" 'entry\.action \?\? ""' 'launch\(entry\.exec\)'

    # ── "?" IS STILL WOLFRAM'S ALONE ─────────────────────────────────────────
    # A plain search must never instantiate WolframService, read its credential
    # file or reset it. The gate is one careless rewrite from regressing.
    want "the Wolfram singleton is still gated behind a used-it flag" \
        has "$al" '^[[:space:]]*property bool _usedWolfram: false'
    want "forgetting the answer is still short-circuited by the flag" \
        in_fn "$al" '^[[:space:]]*function _forgetAnswer\(' 'if \(!_usedWolfram\) return'
    want "no provider is consulted for an answer query" \
        has "$svc" 'root\.parsed\.scope === Search\.SCOPE\.ANSWER'

    # ── THE RESULT LIST IS AN INTEGER MODEL ──────────────────────────────────
    # `model: <JS array>` recreates every delegate whenever the array's contents
    # change — measured on Qt 6.10.3: a 3-element model reports created=6,
    # destroyed=3 after one content change, which silently stopped the workspace
    # strip's Behaviours. A search result list is exactly that shape: the array
    # is rebuilt on every keystroke.
    want "the result list uses an integer count model" \
        has "$al" '^[[:space:]]*model: root\.filtered\.length$'
    want "the delegate looks its row up rather than receiving it" \
        has "$al" 'readonly property var modelData: root\.filtered\[rowItem\.index\]'

    # ── NO COMMAND IS EVER A STRING ──────────────────────────────────────────
    # This repo has a CI invariant about splicing model data into a `bash -c`
    # string. Here the data is a package name typed into a search box.
    want "no action in the table hands anything to bash -c" \
        lacks "$js" '"bash", "-c"'
    want "the service never builds a command out of a row" \
        lacks "$svc" '"bash", "-c"'

    # ── THE SCRIPT IS THE SECOND LOCK ────────────────────────────────────────
    want "the runner refuses any verb it does not know" \
        has "$run" '^[[:space:]]*\*\)$'
    # Named units, not a charset. "Restart any unit whose name looks sensible"
    # is not a smaller capability than "run anything as root": units run
    # arbitrary ExecStart lines, and a user-writable unit file would make this
    # an escalation.
    want "the unit allowlist names units rather than matching a pattern" \
        in_fn "$run" '^unit_allowed\(\)' '^[[:space:]]*bluetooth\|NetworkManager\) return 0'
    want "a package name is validated against a charset before it is used" \
        has "$run" 'valid_name "\$1" \|\| die'
    want "an ssh destination is validated too" \
        has "$run" 'valid_dest "\$1" \|\| die'
    want "neither charset admits a leading dash" \
        count_is "$run" '\^\[A-Za-z0-9\]\[A-Za-z0-9' 2

    # ── REGISTRATION ─────────────────────────────────────────────────────────
    # Registering a singleton in the wrong module gives "Member not found on
    # type" for every binding, which reads as a dozen separate mistakes rather
    # than one. That has cost this repo two debugging sessions.
    want "SearchService is a singleton in src/qmldir" \
        qmldir_has "$qmldir" '^singleton SearchService 1\.0 services/SearchService\.qml$'
    want "SearchService is not registered twice" \
        qmldir_lacks "$r/src/services/qmldir" '^singleton SearchService '
    # The providers are deliberately NOT in a qmldir: nothing outside the host
    # has any business instantiating one, and a provider that could be dropped
    # into another file would be a second, ungated way to put a row in front of
    # the user.
    want "the providers are reached by relative directory import" \
        has "$svc" '^import "search"$'
    want "no provider is registered as a globally reachable type" \
        qmldir_lacks "$r/src/services/qmldir" 'Provider\.qml'

    # ── COLOUR AND SCALE TOKENS ──────────────────────────────────────────────
    # A hardcoded hex in the launcher is a colour that cannot follow the
    # palette; Theme.fs() on a geometry property is the FONT scaler, whose
    # max(7, …) floor silently clamps small radii and margins up to 7px.
    want "the launcher uses no hardcoded colour" \
        lacks "$al" '"#[0-9a-fA-F]{3,8}"'
    want "the launcher scales geometry with px, never with the font scaler" \
        lacks "$al" '^[[:space:]]*(width|height|radius|spacing|implicitWidth|implicitHeight|[a-z]*[Mm]argin|border\.width):.*Theme\.fs\('
    for p in "$sdir"/*.qml "$svc"; do
        [ -e "$p" ] || continue
        want "$(basename "$p") uses no hardcoded colour" \
            lacks "$p" '"#[0-9a-fA-F]{3,8}"'
    done

    # ── THE NETWORK BOUNDARY, STATICALLY ─────────────────────────────────────
    # tests/search-test.js asserts this over every scope. This is the half that
    # survives somebody editing the table without running the suite: the only
    # provider marked `net: true` must not list the plain scope.
    want "the network provider does not answer a plain query" \
        not_in_fn "$js" '^[[:space:]]*packages: \{' 'SCOPE\.ALL'
    want "and it is still the only one marked as reaching the network" \
        count_is "$js" '^[[:space:]]*order: [0-9]+, min: [0-9]+, spawns: true, constantArgv: false, net: true,$' 1
}

# ─────────────────────────────────────────────────────────────────────────────
#  The real tree
# ─────────────────────────────────────────────────────────────────────────────
echo "── invariants ──"
check_tree "$repo"
real_fail=$fail
real_pass=$pass
echo
echo "passed=$real_pass failed=$real_fail"

# ─────────────────────────────────────────────────────────────────────────────
#  Self-test: do these checks have teeth, and can prose turn them red?
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "── self-test: mutants ──"

MUT="$(mktemp -d)"
trap 'rm -rf "$MUT"' EXIT INT TERM

FILES=(
    src/services/search.js
    src/services/SearchService.qml
    src/services/AppLauncher.qml
    src/scripts/SearchRun.sh
    src/popups/Dashboard.qml
    src/qmldir
    src/services/qmldir
)

fresh_copy() {
    local dst="$1"
    rm -rf "$dst"
    mkdir -p "$dst/src/services/search" "$dst/src/scripts" "$dst/src/popups"
    local f
    for f in "${FILES[@]}"; do cp "$repo/$f" "$dst/$f"; done
    for f in "$repo"/src/services/search/*.qml; do
        cp "$f" "$dst/src/services/search/"
    done
}

# THE GUARD THE WHOLE SELF-TEST RESTS ON. A sed that matched nothing leaves the
# copy byte-identical, and then the verdict — red or green — is about the
# ORIGINAL file and means nothing.
mutated=0
unmutated=0
assert_changed() {
    local dst="$1" rel="$2"
    if cmp -s "$repo/$rel" "$dst/$rel"; then
        echo "  FAIL  the mutant did not apply — $rel is unchanged"
        unmutated=$((unmutated + 1))
        return 1
    fi
    mutated=$((mutated + 1))
    return 0
}

# verdict <dir> — "green 0" or "red <n>", from a quiet run of the same checks.
# The count is what distinguishes "this mutant broke the invariant" from "this
# mutant broke the copy".
verdict() {
    local saved_pass=$pass saved_fail=$fail saved_quiet=$quiet
    pass=0; fail=0; quiet=1
    check_tree "$1"
    local n=$fail
    pass=$saved_pass; fail=$saved_fail; quiet=$saved_quiet
    if [ "$n" -eq 0 ]; then echo "green 0"; else echo "red $n"; fi
}

selfpass=0
selffail=0

# expect <desc> <dir> <green|red> [max-broken]
expect() {
    local desc="$1" dir="$2" wanted="$3" maxbroken="${4:-3}"
    local got n
    read -r got n <<<"$(verdict "$dir")"
    if [ "$got" != "$wanted" ]; then
        echo "  FAIL  $desc (wanted $wanted, got $got with $n broken)"
        selffail=$((selffail + 1))
        return
    fi
    if [ "$wanted" = "red" ] && [ "$n" -gt "$maxbroken" ]; then
        echo "  FAIL  $desc (red, but broke $n checks — the copy is damaged, not the invariant)"
        selffail=$((selffail + 1))
        return
    fi
    if [ "$got" = "red" ]; then
        echo "  PASS  $desc (=> red, $n check(s) broken)"
    else
        echo "  PASS  $desc (=> green)"
    fi
    selfpass=$((selfpass + 1))
}

# ── 0. the baseline ──────────────────────────────────────────────────────────
# Without this, a mutant that came out red because the copy was EMPTY would
# look like a working check, and the comment mutant's green would mean nothing.
fresh_copy "$MUT/base"
expect "an unmutated copy is green" "$MUT/base" green

# ── forward mutants: each a regression somebody could plausibly write ────────

# The one that matters most: a click handler that runs the row directly. It
# passes every node assertion — search.js is untouched — and ships a launcher
# where clicking a fuzzy-matched "Restart" reboots.
fresh_copy "$MUT/m1"
python3 - "$MUT/m1/src/services/AppLauncher.qml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '                            root.press("enter", false)'
new = '                            root.activate(rowItem.modelData)'
assert old in s, "click handler anchor not found"
open(p, "w").write(s.replace(old, new))
PY
assert_changed "$MUT/m1" src/services/AppLauncher.qml \
    && expect "a click handler that runs the row directly is caught" "$MUT/m1" red

# The commit rule stops being told which row the preview belongs to. Ctrl+Enter
# then commits whatever is selected, with no preview ever shown.
fresh_copy "$MUT/m2"
sed -i 's|"previewedId": root.previewId|"previewedId": root.selectedId|' \
    "$MUT/m2/src/services/AppLauncher.qml"
assert_changed "$MUT/m2" src/services/AppLauncher.qml \
    && expect "feeding the rule the selection as its own preview is caught" "$MUT/m2" red

# A second process start, in a function the reducer never reaches.
fresh_copy "$MUT/m3"
python3 - "$MUT/m3/src/services/SearchService.qml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """    function _procFor(id) {
        switch (id) {"""
new = """    function _procFor(id) {
        root._projectsProc.running = true
        switch (id) {"""
assert old in s, "procFor anchor not found"
open(p, "w").write(s.replace(old, new))
PY
assert_changed "$MUT/m3" src/services/SearchService.qml \
    && expect "a process started outside _spawn is caught" "$MUT/m3" red

# Ordering, not presence: the kill moved above the slot clear. Both lines are
# still there, so only an order-aware check sees it — and the identical pair
# exists in _spawn, so a file-wide grep would still find both.
fresh_copy "$MUT/m4"
python3 - "$MUT/m4/src/services/SearchService.qml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """        pr.slot = -1
        pr.running = false
    }"""
new = """        pr.running = false
        pr.slot = -1
    }"""
assert old in s, "cancel anchor not found"
open(p, "w").write(s.replace(old, new, 1))
PY
assert_changed "$MUT/m4" src/services/SearchService.qml \
    && expect "killing before clearing the slot is caught" "$MUT/m4" red

# The reducer stops checking the request token, so a cancelled request's answer
# is cached and later merged.
fresh_copy "$MUT/m5"
sed -i 's|if (p === undefined \|\| p.seq !== e.seq)|if (p === undefined)|' \
    "$MUT/m5/src/services/search.js"
assert_changed "$MUT/m5" src/services/search.js \
    && expect "believing a superseded answer is caught" "$MUT/m5" red

# A provider grows a Process of its own — the second, ungated route to the
# operating system.
fresh_copy "$MUT/m6"
python3 - "$MUT/m6/src/services/search/HostsProvider.qml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "import QtQuick\n"
new = "import QtQuick\nimport Quickshell.Io\n"
assert old in s
s = s.replace(old, new, 1)
s = s.replace("    property string data:  \"\"\n",
              "    property string data:  \"\"\n    property var proc: Process { command: [] }\n", 1)
open(p, "w").write(s)
PY
assert_changed "$MUT/m6" src/services/search/HostsProvider.qml \
    && expect "a provider that owns a subprocess is caught" "$MUT/m6" red 4

# The network provider joins the plain scope. Every keystroke of an ordinary
# search then reaches the package index, and dnf5 may refresh it over the wire.
fresh_copy "$MUT/m7"
sed -i 's|^        scopes: \[SCOPE.PACKAGES\]$|        scopes: [SCOPE.ALL, SCOPE.PACKAGES]|' \
    "$MUT/m7/src/services/search.js"
assert_changed "$MUT/m7" src/services/search.js \
    && expect "the network provider joining a plain query is caught" "$MUT/m7" red

# The results list goes back to an array model, which recreates every delegate
# on every keystroke and silently stops the Behaviours.
fresh_copy "$MUT/m8"
sed -i 's|^                model: root.filtered.length$|                model: root.filtered|' \
    "$MUT/m8/src/services/AppLauncher.qml"
assert_changed "$MUT/m8" src/services/AppLauncher.qml \
    && expect "an array model on the result list is caught" "$MUT/m8" red

# The Wolfram gate is dropped, so a plain app search instantiates the singleton
# and reads its credential file.
fresh_copy "$MUT/m9"
sed -i 's|        if (!_usedWolfram) return$||' "$MUT/m9/src/services/AppLauncher.qml"
assert_changed "$MUT/m9" src/services/AppLauncher.qml \
    && expect "losing the Wolfram gate is caught" "$MUT/m9" red

# The unit allowlist becomes a charset — "any unit whose name looks sensible".
fresh_copy "$MUT/m10"
python3 - "$MUT/m10/src/scripts/SearchRun.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """        bluetooth|NetworkManager) return 0 ;;
        *) return 1 ;;"""
new = """        [A-Za-z0-9]*) return 0 ;;
        *) return 1 ;;"""
assert old in s, "unit allowlist anchor not found"
open(p, "w").write(s.replace(old, new))
PY
assert_changed "$MUT/m10" src/scripts/SearchRun.sh \
    && expect "a unit charset instead of a unit allowlist is caught" "$MUT/m10" red

# The launcher is no longer told whether it is on screen, so its refs are bound
# to a property nobody writes — permanently false, and the list stays empty.
fresh_copy "$MUT/m11"
sed -i 's|onScreen: root.pageLive \&\& root.page === "launcher"||' \
    "$MUT/m11/src/popups/Dashboard.qml"
assert_changed "$MUT/m11" src/popups/Dashboard.qml \
    && expect "a launcher that is never told it is on screen is caught" "$MUT/m11" red

# A hardcoded colour in the launcher.
fresh_copy "$MUT/m12"
sed -i 's|color: Theme.fixedLight|color: "#ffffff"|' \
    "$MUT/m12/src/services/AppLauncher.qml"
assert_changed "$MUT/m12" src/services/AppLauncher.qml \
    && expect "a hardcoded colour in the launcher is caught" "$MUT/m12" red

# ── the inverse mutant ───────────────────────────────────────────────────────
# Prose that would trip a naive version of every check above, including prose
# that quotes the exact strings the greps look for. It must NOT turn anything
# red: a check a comment can break punishes people for explaining themselves,
# and this repo has shipped the opposite mistake — a check a comment could
# SATISFY — five times.
fresh_copy "$MUT/c1"
{
    echo '// An early draft started a second process here:'
    echo '//     root._projectsProc.running = true'
    echo '// outside _spawn, so the reducer never knew about it. It also killed'
    echo '// before clearing the slot:'
    echo '//     pr.running = false'
    echo '//     pr.slot = -1'
    echo '// and had a timer with'
    echo '//     running: true'
    echo '// on it, plus a Process { } of its own and an import Quickshell.Io.'
    echo '//     command: ["bash", "-c", "apex search " + term]'
    echo '// None of that is here now.'
} >> "$MUT/c1/src/services/SearchService.qml"
{
    echo '// The first version ran the row straight from the click handler:'
    echo '//     root.activate(rowItem.modelData)'
    echo '// and fed the commit rule its own selection:'
    echo '//     "previewedId": root.selectedId'
    echo '// so Search.commitDecision() approved a Ctrl+Enter pressed straight'
    echo '// from the list, with event.modifiers & Qt.ControlModifier never read.'
    echo '// It also used an array model:'
    echo '//     model: root.filtered'
    echo '// and a literal colour: "#ffffff"'
    echo '//     height: Theme.fs(46)'
    echo '// and it dropped the Wolfram gate, so _forgetAnswer had no'
    echo '//     if (!_usedWolfram) return'
    echo '// See the header for why none of that survived.'
} >> "$MUT/c1/src/services/AppLauncher.qml"
{
    echo '// A draft had the package provider answering a plain query:'
    echo '//     scopes: [SCOPE.ALL, SCOPE.PACKAGES]'
    echo '// and believed a superseded answer, because the result branch said'
    echo '//     if (p === undefined)'
    echo '// with no p.seq !== e.seq comparison at all.'
} >> "$MUT/c1/src/services/search.js"
{
    echo '# unit_allowed() once matched a charset:'
    echo '#     [A-Za-z0-9]*) return 0 ;;'
    echo '# which is not a smaller capability than running anything as root.'
} >> "$MUT/c1/src/scripts/SearchRun.sh"
{
    echo '// onScreen: root.pageLive && root.page === "launcher"   <- was missing'
} >> "$MUT/c1/src/popups/Dashboard.qml"
{
    echo '# singleton SearchService 1.0 services/SearchService.qml  <- was here once'
    echo '# AppsProvider search/AppsProvider.qml'
} >> "$MUT/c1/src/services/qmldir"
assert_changed "$MUT/c1" src/services/AppLauncher.qml \
    && expect "prose quoting every one of these bugs stays green" "$MUT/c1" green

echo
echo "self-test: mutants applied=$mutated, failed-to-apply=$unmutated"
echo "self-test passed=$selfpass failed=$selffail"

[ "$real_fail" -eq 0 ] && [ "$selffail" -eq 0 ] && [ "$unmutated" -eq 0 ]
