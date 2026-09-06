#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/agent-settings-test.qml — the Always Unrestricted toggle, driven
#  against a real file and a fake pkcheck (P0-016, ROADMAP.md §42.1).
#
#  ── It brings its own compositor, always ────────────────────────────────────
#
#  Not "if there is no WAYLAND_DISPLAY". Always. quickshell needs a compositor,
#  and nesting inside whatever session is running puts the test one mistake
#  away from drawing on the developer's actual desktop. So this starts a
#  headless wlroots compositor in a private XDG_RUNTIME_DIR with WAYLAND_DISPLAY
#  and DISPLAY unset, which also makes it runnable on a build box with no
#  display at all. The QML opens no window of its own either.
#
#  ── AND ITS OWN pkcheck, WHICH IS THE POINT ─────────────────────────────────
#
#  A fake pkcheck goes first on PATH. It records its argv and exits 1, so no
#  polkit dialog is ever raised — on a CI runner there is nobody to answer one,
#  and on a desktop an unasked-for password prompt is the thing this project's
#  developer has twice said never to produce.
#
#  Refusing rather than granting is deliberate: it tests the half of criterion 4
#  that can be tested without a person, which is that the password is ASKED FOR
#  on the way in and never on the way out. The log must hold exactly one call
#  after switching off and then on. Zero means the gate is not wired; two means
#  disabling asks for one.
#
#  A fake `apex` goes first on PATH too. AgentService polls `apex agent list`
#  and `apex request pending` from the moment it is instantiated, and a test
#  that reads the developer's live sessions is a test whose result depends on
#  what he happens to be running.
#
#  ── AND ITS OWN CONFIG ROOT ─────────────────────────────────────────────────
#
#  XDG_CONFIG_HOME points at a scratch directory, so the file this writes is
#  never the developer's ~/.config/apex/agent.json. That the service honours
#  XDG_CONFIG_HOME at all is one of the things being tested: apex-agent-core's
#  paths.rs resolves it the same way, and a shell that hardcoded ~/.config
#  would edit a file no session reads.
#
#  Skips cleanly (status 0) without quickshell or a headless compositor.
#
#  Run from anywhere: ./tests/run-agent-settings-test.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }

# Say what is wrong rather than letting QML report it as a missing type.
for f in src/services/agentpolicy.js \
         src/services/AgentPolicyService.qml \
         src/services/config_tab/pages/AgentsPage.qml \
         src/services/agents/UnrestrictedBanner.qml; do
    [[ -f "$root/$f" ]] || { echo "FAIL: this tree has no $f — there is no toggle to drive"; exit 1; }
done
grep -q "^singleton AgentPolicyService " "$root/src/services/qmldir" || {
    echo "FAIL: AgentPolicyService is not registered in src/services/qmldir, so"
    echo "      nothing that goes through that module can see it and the whole"
    echo "      shell fails to load."
    exit 1; }

comp=""
for c in labwc sway; do
    command -v "$c" >/dev/null 2>&1 && { comp="$c"; break; }
done
[[ -n "$comp" ]] || { echo "SKIP: no wlroots compositor (labwc or sway) to host the test"; exit 0; }

W="$(mktemp -d)"
staged="$root/.agent-settings-test.qml"
comp_pid=""
cleanup() {
    [[ -n "$comp_pid" ]] && kill "$comp_pid" 2>/dev/null
    sleep 0.2
    [[ -n "$comp_pid" ]] && kill -9 "$comp_pid" 2>/dev/null
    rm -f "$staged"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

cp "$here/agent-settings-test.qml" "$staged"

# ── the fakes ────────────────────────────────────────────────────────────────
mkdir -p "$W/bin"
cat > "$W/bin/pkcheck" <<'FAKE'
#!/usr/bin/env bash
# Records the call and refuses. Never asks anybody anything.
printf '%s\n' "$*" >> "$PKCHECK_LOG"
exit 1
FAKE
cat > "$W/bin/apex" <<'FAKE'
#!/usr/bin/env bash
# AgentService polls this from the moment it exists. An empty list keeps the
# test independent of whatever the developer happens to be running.
case "$*" in
    *json*) echo "[]" ;;
    *)      : ;;
esac
exit 0
FAKE
chmod +x "$W/bin/pkcheck" "$W/bin/apex"
export PKCHECK_LOG="$W/pkcheck.log"
: > "$PKCHECK_LOG"
export PATH="$W/bin:$PATH"

# ── the file under test ──────────────────────────────────────────────────────
# Five keys, four of which must survive untouched. `native: bypass` is
# criterion 3 in one line, and `shell_layout` is the `extra` catch-all that
# apex-agent-core's config.rs preserves on its own writes.
export XDG_CONFIG_HOME="$W/config"
export XDG_STATE_HOME="$W/state"
mkdir -p "$XDG_CONFIG_HOME/apex" "$XDG_STATE_HOME"
cat > "$XDG_CONFIG_HOME/apex/agent.json" <<'JSON'
{
  "default_agent": "claude",
  "native": "bypass",
  "sandbox": "unrestricted",
  "detach_key": "ctrl-]",
  "shell_layout": "grid"
}
JSON

# ── the compositor ───────────────────────────────────────────────────────────
export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
unset WAYLAND_DISPLAY
unset DISPLAY
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER=pixman
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland

case "$comp" in
    labwc)
        mkdir -p "$W/labwc"
        cp "$here/labwc-test-rc.xml" "$W/labwc/rc.xml" 2>/dev/null || true
        XDG_CONFIG_HOME="$W" "$comp" > "$W/comp.log" 2>&1 &
        ;;
    sway)
        printf 'output HEADLESS-1 mode 1920x1080\n' > "$W/sway.cfg"
        "$comp" -c "$W/sway.cfg" > "$W/comp.log" 2>&1 &
        ;;
esac
comp_pid=$!

sock=""
for _ in $(seq 1 60); do
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [[ -S "$f" ]] || continue
        sock="$(basename "$f")"
        break
    done
    [[ -n "$sock" ]] && break
    sleep 0.25
done
[[ -n "$sock" ]] || {
    echo "SKIP: $comp did not come up headless"; tail -5 "$W/comp.log"; exit 0; }
export WAYLAND_DISPLAY="$sock"
echo "host: $comp on $WAYLAND_DISPLAY (headless, private XDG_RUNTIME_DIR)"
echo "config: $XDG_CONFIG_HOME/apex/agent.json"

out="$(QT_LOGGING_RULES="qml=true" timeout 90 quickshell -p "$staged" 2>&1 \
       | sed 's/\x1b\[[0-9;]*m//g')"

echo "$out" | grep -E "PASS|FAIL|passed=" || true

if echo "$out" | grep -q "Failed to load configuration"; then
    echo "$out" | tail -30
    echo "RESULT: the test config failed to load"
    exit 1
fi
if ! echo "$out" | grep -q "agent-settings: passed="; then
    echo "$out" | tail -30
    echo "RESULT: the test did not run to completion"
    exit 1
fi

rc=0
if echo "$out" | grep -q "  FAIL"; then
    echo "RESULT: failing assertions"
    rc=1
fi

# ── what only the shell can check ────────────────────────────────────────────
echo
echo "── after the run ──"

final="$XDG_CONFIG_HOME/apex/agent.json"

# No eval anywhere here. A verdict assembled by expanding a string is one
# quoting mistake away from being about a different file, and the assertions
# below are the whole point of the run.
say() { local desc="$1"; shift; if "$@"; then echo "  PASS  $desc"; else echo "  FAIL  $desc"; rc=1; fi; }
jget() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' \
        "$final" "$1" 2>/dev/null
}
keyis() { [ "$(jget "$1")" = "$2" ]; }
isjson() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$final" 2>/dev/null; }
mode600() { [ "$(stat -c %a "$final")" = "600" ]; }
notmp()   { [ ! -e "$final.tmp" ]; }

say "the file is still valid JSON"          isjson
say "the sandbox key came back to project"  keyis sandbox project
# Criterion 3, proved on a real file: switching the sandbox off left dimension
# 1 exactly where the user had it.
say "the agent's own permission mode survived" keyis native bypass
say "the unrecognised key survived"         keyis shell_layout grid
say "the default agent survived"            keyis default_agent claude
say "the file is not world-readable"        mode600
say "no temporary file was left behind"     notmp

# Criteria 4 and 5 as one number. Switching off, then on, is exactly one call.
calls="$(wc -l < "$PKCHECK_LOG" | tr -d " ")"
if [ "$calls" = "1" ]; then
    echo "  PASS  pkcheck was called once: on the way in, not on the way out"
else
    echo "  FAIL  pkcheck was called $calls time(s), expected 1"
    cat "$PKCHECK_LOG"
    rc=1
fi
logged() { grep -q -- "$1" "$PKCHECK_LOG"; }
say "the call named the action the policy file declares" \
    logged org.apexos.shell.agent.set-always-unrestricted
say "the call was allowed to raise a prompt" logged --allow-user-interaction
say "the call named a subject rather than guessing one" logged --process

echo
[ "$rc" -eq 0 ] \
    && echo "RESULT: the toggle wrote one key, kept the other five, and asked for a password once" \
    || echo "RESULT: see the failures above"
exit "$rc"
