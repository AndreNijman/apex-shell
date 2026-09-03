#!/usr/bin/env bash
# Generate the niri keybind file and put it through `niri validate`.
#
# Quickshell refuses to import QML modules from outside the directory holding
# the entry point, so the test is staged into the repo root for the run and
# removed afterwards — the arrangement run-service-tier-test.sh uses.
#
# Needs a Wayland session (quickshell) and the niri binary (to validate). Skips
# cleanly with status 0 without them so a runner lacking either does not fail
# the build — but note what that means: on CI this suite proves nothing, which
# is why the static half below runs unconditionally.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

# ── the static half: runs everywhere, including CI ───────────────────────────
# Every niri action name the generator can emit must be one niri actually has.
# A wrong verb is not a partial failure: niri rejects the whole include, so the
# user loses every binding in the file. This checks the names against niri's own
# help when the binary is present, and against the generator's own map when it
# is not — the second is weaker but it still catches a name deleted from the map
# while a consumer still references it.
KS="${root}/src/services/config_tab/KeybindService.qml"
pass=0; fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# Delegated to python, for two reasons that both bit the first draft of this
# script:
#
#   * A grep for a construct is satisfied — or tripped — by the file's own
#     COMMENTS about that construct. The check for "the blanket
#     `if (e.type) continue` is gone" failed against a file where it IS gone,
#     because the comment explaining its removal quotes it. Comment lines are
#     stripped before matching now. (The plugin platform hit the same thing from
#     the other direction: a `grep` for its crash-isolation handler stayed green
#     when the handler was deleted, because the header paragraph describing it
#     matched.)
#   * A `sed` range `/_niriActions: ({/,/})/` ends at the FIRST `})`, which is a
#     nested map inside it — so it extracted 7 of the 9 action names and the
#     other two were never checked against niri at all.
pyout="$(python3 - "$KS" <<'PYEOF'
import re, subprocess, sys, shutil

src = open(sys.argv[1], encoding="utf-8").read()
pas = fai = 0
def ok(m):
    global pas; pas += 1; print(f"PASS  {m}")
def bad(m):
    global fai; fai += 1; print(f"FAIL  {m}")

# Code with comment lines removed, so a check for a construct cannot be
# satisfied by prose discussing it.
code = "\n".join(l for l in src.splitlines()
                 if not l.lstrip().startswith("//"))

ok("the generator has a niri action map") if "_niriActions" in code \
    else bad("the generator has a niri action map")

bad("the blanket 'if (e.type) continue' is gone from _genKdl") \
    if "if (e.type) continue" in code \
    else ok("the blanket 'if (e.type) continue' is gone from _genKdl")

ok("config variables are resolved for niri") if "_niriApps" in code \
    else bad("config variables are resolved for niri")

# Brace-matched extraction of the action map, not a line range.
i = src.index("_niriActions")
i = src.index("({", i)
depth, j = 0, i
while j < len(src):
    if src[j] == "(": depth += 1
    elif src[j] == ")":
        depth -= 1
        if depth == 0: break
    j += 1
block = src[i:j]
names = sorted(set(re.findall(r'"([a-z]+(?:-[a-z]+)+)"', block)))
# Keys are Hyprland dispatchers, values are niri verbs. Dispatchers are single
# words, so anything hyphenated in here is a niri action.
print(f"      {len(names)} action names in the map: {' '.join(names)}")

if shutil.which("niri"):
    helptext = subprocess.run(["niri", "msg", "action", "--help"],
                              capture_output=True, text=True).stdout
    have = set(re.findall(r'^\s{2}([a-z][a-z-]+)\s*$', helptext, re.M))
    missing = [n for n in names if n not in have]
    if not missing and names:
        ok(f"all {len(names)} mapped action names exist in the installed niri")
    elif not names:
        bad("no action names were extracted — the parser is broken, not the map")
    else:
        bad(f"action names the installed niri does not have: {' '.join(missing)}")
else:
    print("SKIP  niri not installed; action names not checked against it")

print(f"__PY__ {pas} {fai}")
PYEOF
)"
printf '%s\n' "$pyout" | grep -v '^__PY__'
set +e
pcounts="$(printf '%s\n' "$pyout" | grep '^__PY__' | tail -1)"
set -e
pass=$((pass + $(echo "$pcounts" | awk '{print $2}')))
fail=$((fail + $(echo "$pcounts" | awk '{print $3}')))

# ── the behavioural half: needs a compositor ────────────────────────────────
if ! command -v quickshell >/dev/null 2>&1; then
    printf 'SKIP  quickshell not installed\n'
elif [ -z "${WAYLAND_DISPLAY:-}" ]; then
    printf 'SKIP  no WAYLAND_DISPLAY; quickshell needs a compositor\n'
elif ! command -v niri >/dev/null 2>&1; then
    printf 'SKIP  niri not installed; cannot validate the generated file\n'
else
    staged="$root/.niri-keybinds-test.qml"
    cleanup() { rm -f "$staged" "${XDG_RUNTIME_DIR:-/tmp}/apex-niri-keybinds-test.kdl"; }
    trap cleanup EXIT
    cp "$here/niri-keybinds-test.qml" "$staged"

    out="$(QT_LOGGING_RULES="qml=true" timeout 120 quickshell -p "$staged" 2>&1 || true)"
    echo "$out" | grep -E "PASS|FAIL|niri said|passed=" || true

    if echo "$out" | grep -q "Failed to load configuration"; then
        echo "$out" | tail -20
        bad "the behavioural harness loaded"
    elif ! echo "$out" | grep -q "passed="; then
        echo "$out" | tail -20
        bad "the behavioural harness reached its summary"
    else
        set +e
        n="$(echo "$out" | grep -o 'failed=[0-9]*' | tail -1 | grep -o '[0-9]*')"
        set -e
        [ "$n" = "0" ] && ok "the behavioural harness passed" \
                       || bad "the behavioural harness reported $n failure(s)"
    fi
fi

echo
printf 'niri-keybinds: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
