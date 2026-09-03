#!/usr/bin/env bash
# Static invariants for §10's GUI blueprint editor.
#
# ── Why this exists, and why it must not skip ────────────────────────────────
# The properties that make this editor safe are structural: it never authors
# TOML, it never applies from a timer, it never escalates, and it writes only
# the user-owned file. Every one of those is a property of the SOURCE, not of a
# running session — and no CI runner has a compositor, so a behavioural QML
# suite always skips there. A suite that skips proves nothing, and this repo has
# already shipped assertions that passed because they never ran.
#
# So everything here is grep-able and runs headless. There is nothing in this
# file that can be skipped: it either runs and passes, or runs and fails.
#
# It deliberately never invokes `apex`. No P1 verb is merged and no image is
# built, so the installed binary has none of them; shelling out would mean an
# unconditional skip, which is the outcome being avoided.
set -uo pipefail
# Not `set -e`: this suite COUNTS assertions, like check-compositor-backends.sh,
# so a single failure must not abort the rest and hide the real total.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

svc="$root/src/services/config_tab/BlueprintService.qml"
page="$root/src/services/config_tab/pages/BlueprintPage.qml"
logic="$root/src/services/config_tab/blueprint.js"
jstest="$root/tests/blueprint-editor-test.js"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

# want <description> <command...> — runs the command and records the verdict.
# Deliberately not `cmd; check $?`: ShellCheck SC2319 is right that a $? read
# after a `[ ]` is a trap waiting for someone to insert a line between them.
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ── Comment-stripped copies ─────────────────────────────────────────────────
# Every invariant below is about what the editor DOES, and all three files
# explain at length what they deliberately do not do. A comment mentioning
# `sudo` or `apply` must not read as a violation, so the greps run against
# copies with the comment lines removed. This is the difference between a guard
# and a prose detector — and stripping once into files, rather than piping a
# function into `bash -c`, is what keeps the assertions themselves readable.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

strip_comments() {
    # Whole-line comments only: `//`, `#`, and the middle of a /* */ block. A
    # trailing comment on a code line stays, which is the conservative
    # direction — it can only cause a false FAIL, never a false PASS.
    grep -vE '^[[:space:]]*(//|#|\*|/\*)' "$1" > "$2"
}
csvc="$tmp/svc.qml";  strip_comments "$svc"    "$csvc"
cpage="$tmp/page.qml"; strip_comments "$page"  "$cpage"
clogic="$tmp/logic.js"; strip_comments "$logic" "$clogic"
cjstest="$tmp/test.js"; strip_comments "$jstest" "$cjstest"

# ── The files exist and are reachable ───────────────────────────────────────
want "blueprint.js exists and is non-empty"          test -s "$logic"
want "BlueprintService.qml exists and is non-empty"  test -s "$svc"
want "BlueprintPage.qml exists and is non-empty"     test -s "$page"

want "BlueprintService is registered in src/qmldir" \
    grep -q "^singleton BlueprintService .*services/config_tab/BlueprintService.qml" \
        "$root/src/qmldir"
want "BlueprintPage is registered in src/services/qmldir" \
    grep -q "^BlueprintPage ./config_tab/pages/BlueprintPage.qml" \
        "$root/src/services/qmldir"
want "the page is reachable from PageRegistry" \
    grep -q "BlueprintPage {}" "$root/src/nexus/PageRegistry.qml"
want "PageRegistry declares a blueprint entry" \
    grep -q '"id": "blueprint"' "$root/src/nexus/PageRegistry.qml"
# The registry's list and its Components are two lists in one file; a page
# declared in one and not the other is a page that cannot render.
want "the blueprint component is declared, not just referenced" \
    grep -q "property Component blueprintComp" "$root/src/nexus/PageRegistry.qml"

# ── THE EDITOR NEVER AUTHORS TOML ───────────────────────────────────────────
# The whole design rests on a lossless round-trip through one parser. A second
# TOML writer in QML drifts from the first the moment a field is added, and it
# would be the shell's own bug that corrupted a user's hand-written file.
want "the service builds no TOML table header" \
    bash -c '! grep -qE "\"\[(desktop|apps|development|agent|gaming)\]" "$1"' _ "$csvc"
want "the logic module builds no TOML table header" \
    bash -c '! grep -qE "\"\[(desktop|apps|development|agent|gaming)\]\\\\n" "$1"' _ "$clogic"
for f in "$csvc" "$cpage" "$clogic"; do
    want "$(basename "$f") has no TOML serialiser" \
        bash -c '! grep -qiE "function [a-zA-Z]*to_?toml|toTomlString|stringifyToml" "$1"' _ "$f"
done
# A `key = value` TOML line being assembled from a value.
want "no TOML assignment line is assembled" \
    bash -c '! grep -qE "\" = \" *\+|\+ \" = \"" "$1" "$2" "$3"' _ "$csvc" "$cpage" "$clogic"

# The one write path must be the JSON one, on stdin.
want "the service writes through blueprint set --json -" \
    grep -q "blueprint set --json -" "$csvc"
want "the service reads through blueprint show --json" \
    grep -q '"blueprint", "show", "--json"' "$csvc"
# `blueprint set` accepts stdin only; a path argument would invite passing the
# live blueprint's own path and truncating it mid-read.
want "no --file argument is passed to blueprint set" \
    bash -c '! grep -qE "blueprint set.*--file|\"set\".*\"--file\"" "$1"' _ "$csvc"

# ── Generated state stays separate from user-owned state ────────────────────
# If the editor could write the applied-state record, `diff` would start
# agreeing with `apply` by construction instead of by measurement.
want "the service never names the applied-state file as a write target" \
    bash -c '! grep -qE "blueprint-state\.toml" "$1"' _ "$csvc"
want "the service has no generic file-write helper" \
    bash -c '! grep -qE "writeFile|> *\\\$?applied|printf.*> *\"" "$1"' _ "$csvc"
# The page may NAME the generated path, to tell the user it is off limits.
want "the page tells the user where generated state lives" \
    grep -q "applied_state" "$cpage"

# ── NOTHING APPLIES ON EDIT ─────────────────────────────────────────────────
# The regression guarded against is the one DisplayService already carries a CI
# grep for: copying InputService's debounce-then-apply timer, which would
# converge the machine while the user is still choosing a value. Run against
# the RAW files, because a commented-out timer would be a lie either way.
want "the service never applies from a timer" \
    bash -c '! grep -qE "onTriggered:[[:space:]]*root\.apply\(\)" "$1"' _ "$svc"
want "the page never applies from a timer" \
    bash -c '! grep -qE "onTriggered:[[:space:]]*.*\.apply\(\)" "$1"' _ "$page"
# Broader than the apply grep: `set` is a full-file replace, so a debounced
# SAVE would rewrite the user's blueprint on every keystroke.
want "the service never saves from a timer" \
    bash -c '! grep -qE "onTriggered:[[:space:]]*root\.(save|_write)\(\)" "$1"' _ "$svc"
want "the service has no Timer at all" \
    bash -c '! grep -qE "Timer[[:space:]]*\{" "$1"' _ "$csvc"
want "the page has no Timer at all" \
    bash -c '! grep -qE "Timer[[:space:]]*\{" "$1"' _ "$cpage"

# apply() must be reachable only from an explicit click. A binding or an
# onCompleted that called it would converge the machine on page open.
want "every apply() call in the page is an onClicked" \
    bash -c 'test "$(grep -cE "BlueprintService\.apply\(\)" "$1")" = "$(grep -cE "onClicked: BlueprintService\.apply\(\)" "$1")"' _ "$cpage"
want "the page does not apply on load" \
    bash -c '! grep -qE "Component\.onCompleted:.*apply\(\)" "$1"' _ "$cpage"
# Save is likewise explicit: every call sits in an onClicked, directly or
# through that handler's ternary.
want "every save() call in the page is under an onClicked" \
    bash -c 'test "$(grep -cE "BlueprintService\.(save|confirmErase)\(\)" "$1")" = "$(grep -cE "^[[:space:]]*(onClicked:|\?|:)[[:space:]]*BlueprintService\.(save|confirmErase)\(\)" "$1")"' _ "$cpage"

# Save and apply must remain distinct verbs: save writes the file and changes
# the machine not at all.
want "the service has a save() distinct from apply()" \
    bash -c 'grep -q "function save()" "$1" && grep -q "function apply()" "$1"' _ "$csvc"
want "save does not call apply" \
    bash -c '! sed -n "/function save()/,/^    }/p" "$1" | grep -q "apply("' _ "$csvc"
want "the write path does not call apply" \
    bash -c '! sed -n "/function _write()/,/^    }/p" "$1" | grep -q "apply("' _ "$csvc"

# ── APPLY NEVER ESCALATES ───────────────────────────────────────────────────
# `apex apply` converges the privilege domain it is already running in and
# reports the other. That is the reason it cannot raise an authentication
# prompt at all, and a button that ran sudo would throw it away.
want "the service never runs sudo" \
    bash -c '! grep -qE "\"sudo\"|sudo |pkexec|polkit" "$1"' _ "$csvc"
want "the page never runs sudo as a command" \
    bash -c '! grep -qE "\"sudo\"|pkexec|polkit" "$1"' _ "$cpage"
# The root-domain changes must be reported as information. The notice text is
# built in the logic module, and there must be no clickable control beside it.
want "the root notice names the command for the user to run" \
    grep -q 'run `sudo apex apply`' "$clogic"
want "the root notice section has no button" \
    bash -c '! sed -n "/title: \"Needs root\"/,/^    }$/p" "$1" | grep -q "CfgButton"' _ "$cpage"
want "the page explains that it does not escalate" \
    grep -q "does not escalate" "$page"

# ── The stale-write and erase guards ────────────────────────────────────────
# `set` has no compare-and-swap, and the blueprint is hand-editable while the
# page is open.
want "the service uses the isStale guard"     grep -q "isStale" "$csvc"
want "the service shows the stale notice"     grep -q "staleNotice" "$csvc"
want "the digest is re-read before writing"   grep -q "_recheckProc" "$csvc"
want "the recheck runs blueprint show, not blueprint set" \
    bash -c 'sed -n "/_recheckProc: Process/,/^    }$/p" "$1" | grep -q "\"show\", \"--json\""' _ "$csvc"
# `{}` clears the CLI's empty-stdin guard and atomically writes an empty file.
want "the service guards against writing an empty blueprint" \
    bash -c 'grep -q "eraseWarning" "$1" && grep -q "_eraseConfirmed" "$1"' _ "$csvc"
want "the page surfaces the erase warning"    grep -q "eraseWarning" "$cpage"

# ── No shell injection ──────────────────────────────────────────────────────
# Package names come off disk and out of `apex sync import` bundles. CI already
# checks that neither the Display nor the Input service splices its model into
# a shell string; this service passes the JSON as a bash argv element too.
want "the JSON payload is a bash argument, not interpolated" \
    grep -qF 'printf %s "$1"' "$csvc"
want "no template literal builds the set command" \
    bash -c '! grep -qE "blueprint set.*\\\$\{" "$1"' _ "$csvc"
want "the draft is serialised through toStdin" \
    grep -qF "BP.toStdin(root.draft)" "$csvc"

# ── The absent-CLI path ─────────────────────────────────────────────────────
# Nothing is merged and no image is built, so /usr/bin/apex has none of these
# verbs. A process that never STARTS emits neither stdout nor stderr, so
# without an onExited handler the page renders blank with nothing to explain it.
want "the service handles a CLI that never starts" \
    bash -c 'sed -n "/_showProc: Process/,/^    }$/p" "$1" | grep -q "onExited"' _ "$csvc"
want "the show handler sets loaded in onExited" \
    bash -c 'sed -n "/_showProc: Process/,/^    }$/p" "$1" | sed -n "/onExited/,\$p" | grep -q "root.loaded = true"' _ "$csvc"
want "the service reports availability"        grep -q "available" "$csvc"
want "the service carries an unavailable reason" grep -q "unavailableReason" "$csvc"
want "the page shows a not-available explanation" \
    grep -q "Not available on this image" "$cpage"
want "the explanation is the page's first section when the CLI is missing" \
    bash -c 'grep -B8 "Not available on this image" "$1" | grep -q "first: true"' _ "$cpage"
want "the CLI path is overridable for local testing" \
    grep -q "APEX_BLUEPRINT_CLI" "$csvc"

# ONLY THE SHOW PATH MAY DECIDE THE CLI IS ABSENT.
#
# `available` gates every real section of the page, including the Reload button,
# so a second writer latches the whole editor off. That is not hypothetical: the
# plan path used to set it on any `diff` exit above 1, which turned one
# transient probe failure into a permanently collapsed page claiming the verbs
# were not on the image, with no way to retry.
want "exactly one place decides the CLI is unavailable" \
    bash -c 'test "$(grep -c "available = false" "$1")" = 1' _ "$csvc"
want "the plan path does not latch availability off" \
    bash -c '! sed -n "/_planProc: Process/,\$p" "$1" | grep -q "available = false"' _ "$csvc"
want "the show path is what clears availability again" \
    bash -c 'sed -n "/_showProc: Process/,/^    }$/p" "$1" | grep -q "available = true"' _ "$csvc"
# And the not-available state must be escapable.
want "the not-available section offers a retry" \
    bash -c 'grep -A12 "Not available on this image" "$1" | grep -q "BlueprintService.refresh()"' _ "$cpage"
# A failed read must not become an empty draft: saving that over a real
# blueprint would erase it.
want "a failed read yields a null draft, not an empty one" \
    grep -q "root.draft = null" "$csvc"

# ── NO TEST MAY REACH THE NON-DRY-RUN APPLY PATH ────────────────────────────
# The requirement in full: nothing under tests/ may converge the machine. The
# suites here run on a developer's live desktop as well as on CI, and this repo
# has already reconfigured a developer's real display from a test run.
#
# Two invocation shapes are hunted, because those are the two ways a test could
# actually run the thing:
#
#   argv    Process { command: ["apex", "apply"] }  — and the QML/JS spelling
#   shell   a line whose COMMAND is apex/$APEX_BIN followed by apply
#
# Anchoring the shell form at the start of a command is what distinguishes an
# invocation from a mention: a test may legitimately assert on the STRING
# "run `sudo apex apply`", which is exactly what blueprint-editor-test.js does.
apply_leak=""
set_leak=""
for t in "$root"/tests/*; do
    [ -f "$t" ] || continue
    [ "$t" = "$here/check-blueprint-editor.sh" ] && continue
    body="$(grep -vE '^[[:space:]]*(//|#)' "$t" 2>/dev/null)"

    # argv form: "apex" and "apply" adjacent as separate array elements.
    argv_hit="$(printf '%s\n' "$body" \
        | grep -oE "[\"'](apex|/usr/bin/apex)[\"'][[:space:]]*,[[:space:]]*[\"']apply[\"']" || true)"
    # shell form: apex/$VAR as the command word, then apply.
    sh_hit="$(printf '%s\n' "$body" \
        | grep -oE "(^|[;&|]|\\\$\()[[:space:]]*(sudo[[:space:]]+)?(apex|\\\$[A-Z_]+)[[:space:]]+apply\b" || true)"

    for hit in "$argv_hit" "$sh_hit"; do
        [ -z "$hit" ] && continue
        # A hit is a leak unless every occurrence carries --dry-run.
        if printf '%s\n' "$body" | grep -E "apply" | grep -qv -- "--dry-run"; then
            case " $apply_leak " in *" $(basename "$t") "*) ;; *)
                apply_leak="$apply_leak $(basename "$t")" ;; esac
        fi
    done

    printf '%s\n' "$body" | grep -qE "blueprint[\"',[:space:]]+set" \
        && set_leak="$set_leak $(basename "$t")"
done
want "no test reaches a non-dry-run apex apply" test -z "$apply_leak"
[ -n "$apply_leak" ] && echo "        live apply in:$apply_leak"
want "no test invokes blueprint set" test -z "$set_leak"
[ -n "$set_leak" ] && echo "        blueprint set in:$set_leak"

# The headless suite must stay headless: the moment it spawns a process it can
# fail for reasons that have nothing to do with the logic, and on a runner with
# no `apex` it would be tempted into skipping.
want "the logic module spawns no process" \
    bash -c '! grep -qE "require\(.child_process.\)|execSync|spawn\(|Process[[:space:]]*\{" "$1"' _ "$logic"
want "the logic module touches no filesystem" \
    bash -c '! grep -qE "require\(.fs.\)|readFileSync|writeFileSync" "$1"' _ "$logic"
want "the headless test spawns no process" \
    bash -c '! grep -qE "require\(.child_process.\)|execSync|spawnSync" "$1"' _ "$jstest"
# A suite that cannot run must FAIL, not skip. Checked on the stripped copy:
# the file's own comments explain why it must not skip, and that prose is not a
# skip mechanism.
want "the headless test has no skip mechanism" \
    bash -c '! grep -qiE "\bskip\b|process\.exit\(0\)" "$1"' _ "$cjstest"
want "the headless test exits non-zero on failure" \
    grep -q "process.exit(1)" "$jstest"

# And the preview path must carry --dry-run literally, not through a variable a
# binding could lose.
want "the preview path literally carries --dry-run" \
    grep -qF '"apply", "--dry-run", "--json"' "$csvc"
want "there is exactly one live apply command in the service" \
    bash -c 'test "$(grep -cE "^[[:space:]]*command: \[root\.cli, \"apply\"\]$" "$1")" = 1' _ "$csvc"

# ── Vocabulary parity with apexd-core ───────────────────────────────────────
# The dropdown lists mirror closed sets in the Rust source. They are not a
# reimplementation of validate() — the CLI decides validity and its stderr is
# shown verbatim — but a mirror that has drifted offers the user a value the CLI
# will refuse. When apex-os is checked out beside the shell, compare them.
#
# There is no vocabulary-discovery verb, so this is the honest ceiling; a
# `blueprint schema --json` would close it. Absence of the sibling checkout is
# not a skip of this suite: every other assertion above still runs.
rust=""
for cand in "$root/../apex-os/apexd/apexd-core/src/blueprint.rs" \
            "$root/../../apex-os/apexd/apexd-core/src/blueprint.rs"; do
    [ -f "$cand" ] && { rust="$cand"; break; }
done

sorted() { printf '%s\n' "$1" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' '; }

if [ -n "$rust" ]; then
    echo "        comparing vocabularies against $rust"
    # One const declaration, whether it spans lines or not.
    #
    # NOT `sed -n "/pub const $1:/,/];/p"`: a sed range only tests its end
    # address on lines AFTER the start line, so a single-line declaration like
    # `pub const AGENTS: [&str; 6] = ["claude", …];` runs on to the NEXT `];`
    # and swallows the following const. That silently merged AGENTS with
    # SANDBOX_POLICIES, and the merged list still contained everything the JS
    # side had — so the assertion would have looked fine had the two not
    # differed in length. awk stops on the start line when it ends there.
    rust_decl() {
        awk -v name="$1" '
            index($0, "pub const " name ":") { on = 1 }
            on { print; if (/\];/) exit }
        ' "$rust"
    }
    rust_list() {
        rust_decl "$1" | grep -oE '"[a-z-]+"' | tr -d '"' | tr '\n' ' '
    }
    js_list() {
        sed -n "s/^var $1 *= *\[\(.*\)\].*/\1/p" "$logic" | tr -d '" ' | tr ',' ' '
    }
    # COMPOSITORS is a list of PAIRS in Rust: ("hyprland", "hyprland"). The
    # blueprint names the first of each; the second is the session id.
    rust_compositors() {
        rust_decl COMPOSITORS | grep -oE '\("[a-z-]+"' | tr -d '("' | tr '\n' ' '
    }
    for pair in "THEMES:THEMES" "AGENTS:AGENTS" "SANDBOX_POLICIES:SANDBOXES" "LANGUAGES:LANGUAGES"; do
        rname="${pair%%:*}"; jname="${pair##*:}"
        r="$(rust_list "$rname")"; j="$(js_list "$jname")"
        if [ -z "$r" ]; then
            bad "$rname could not be read from the Rust source"
        elif [ "$(sorted "$r")" = "$(sorted "$j")" ]; then
            ok "$jname matches Rust's $rname"
        else
            bad "$jname has drifted from Rust's $rname"
            echo "        rust: $r"
            echo "        js:   $j"
        fi
    done
    r="$(rust_compositors)"; j="$(js_list COMPOSITORS)"
    if [ -z "$r" ]; then
        bad "COMPOSITORS could not be read from the Rust source"
    elif [ "$(sorted "$r")" = "$(sorted "$j")" ]; then
        ok "COMPOSITORS matches Rust's COMPOSITORS"
    else
        bad "COMPOSITORS has drifted from Rust's COMPOSITORS"
        echo "        rust: $r"
        echo "        js:   $j"
    fi
else
    echo "        apex-os is not checked out beside this repo;"
    echo "        vocabularies are asserted by tests/blueprint-editor-test.js instead"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
