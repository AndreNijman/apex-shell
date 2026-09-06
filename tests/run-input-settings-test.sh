#!/usr/bin/env bash
# Run the Input settings suite (P0-019 / UI-003) against the real generator.
#
#     ./tests/run-input-settings-test.sh
#
# ── What is real and what is not ─────────────────────────────────────────────
#
# Real: /usr/libexec/apex-input-apply, a model file in a sandbox HOME, the
# shipped labwc rc.xml, and whatever the generator's capability table says about
# each compositor. Those answers are the thing under test — a suite that stubbed
# them would prove the page agrees with a stub.
#
# Fixtured: the device list, through APEX_INPUT_DEVICES. Asserting against
# whatever is plugged into the machine running this is how a test comes to pass
# on a laptop and fail on a build runner.
#
# ── Twice, because the interesting refusals are niri's ───────────────────────
#
# The suite runs once as labwc and once as niri. niri has no three-finger drag
# and no click method that produces no button, so it is the compositor that
# proves a control can be refused; labwc can do everything on the page, so it is
# the one that proves the refusals are not blanket. Neither run needs niri
# installed: the generator detects the session from XDG_CURRENT_DESKTOP, and
# what is being tested is the capability table, not niri itself. The generated
# KDL is validated against real niri by apex-os's own suite.
#
# ── Why this cannot touch the developer's session ────────────────────────────
#
# The shell runs inside a headless labwc, so it draws nothing. The generator's
# reload is suppressed the only way that is airtight: PATH is prefixed with a
# shim directory whose hyprctl, niri and labwc all exit 127, and
# HYPRLAND_INSTANCE_SIGNATURE, NIRI_SOCKET and DISPLAY are removed. The reload
# helper is also absent from a sandbox, so nothing reaches a live compositor
# even if detection went wrong.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

for tool in quickshell labwc python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 0; }
done

# A sibling apex-os CHECKOUT wins over the installed copy. This suite tests the
# pair — the page's questions and the generator's answers — so running it
# against whatever /usr happens to hold would report a shell change as broken
# whenever the machine's image is older than the branch, which is the normal
# case while both halves are in flight. Set APEX_INPUT_GENERATOR_REAL to pin it.
GEN="${APEX_INPUT_GENERATOR_REAL:-}"
if [ -z "$GEN" ]; then
    for cand in "$root/../apex-os/files/system/libexec/apex-input-apply" \
                "$root/../../apex-os/files/system/libexec/apex-input-apply" \
                /usr/libexec/apex-input-apply; do
        [ -f "$cand" ] && { GEN="$cand"; break; }
    done
fi
[ -f "$GEN" ] || { echo "SKIP: no input generator at $GEN (it ships with APEX-OS)"; exit 0; }
echo "generator: $GEN"

sandbox="$(mktemp -d)"
shim="$sandbox/shim"
mkdir -p "$shim" "$sandbox/home/.config/labwc" "$sandbox/home/.config/apex-shell" \
         "$sandbox/cfg"

# Nothing in here may reach a live compositor, and the two that could are the
# ones that talk to a running one: `hyprctl` and `labwc --reconfigure`. They are
# shimmed to exit 127.
#
# `niri` is deliberately NOT shimmed. `niri validate --config` reads a file and
# reaches no session, and the generator refuses to write a config its own
# compositor rejects — so a stubbed niri does not isolate the test, it makes the
# generator decline half its work and the suite then measures the stub. The
# shims only exist in the environment quickshell gets, so the harness's own
# labwc, launched above, is unaffected.
for prog in hyprctl labwc; do
    printf '#!/bin/sh\necho "%s is not available in the input settings test" >&2\nexit 127\n' \
        "$prog" > "$shim/$prog"
    chmod +x "$shim/$prog"
done

# The shipped rc.xml, so the labwc half writes into the file a user really has.
if [ -f "$root/../apex-os/files/desktop/labwc/rc.xml" ]; then
    cp "$root/../apex-os/files/desktop/labwc/rc.xml" "$sandbox/home/.config/labwc/rc.xml"
elif [ -f /usr/share/apex/labwc/rc.xml ]; then
    cp /usr/share/apex/labwc/rc.xml "$sandbox/home/.config/labwc/rc.xml"
else
    printf '<?xml version="1.0"?>\n<labwc_config>\n  <keyboard>\n  </keyboard>\n</labwc_config>\n' \
        > "$sandbox/home/.config/labwc/rc.xml"
fi

# Five kinds of device, none of them this machine's. `Fixture Switch` is here to
# prove the page drops what a settings page has nothing to say about.
cat > "$sandbox/devices.json" <<'JSON'
[ {"name":"Fixture Touchpad","type":"touchpad","hypr_name":"fixture-touchpad","hypr_name_source":"derived"},
  {"name":"Fixture TrackPoint","type":"trackpoint","hypr_name":"fixture-trackpoint","hypr_name_source":"derived"},
  {"name":"Fixture Mouse","type":"mouse","hypr_name":"fixture-mouse","hypr_name_source":"derived"},
  {"name":"Fixture Tablet","type":"tablet","hypr_name":"fixture-tablet","hypr_name_source":"derived"},
  {"name":"Fixture Touchscreen","type":"touchscreen","hypr_name":"fixture-touchscreen","hypr_name_source":"derived"},
  {"name":"Fixture Lid Switch","type":"other","hypr_name":"fixture-lid-switch","hypr_name_source":"derived"} ]
JSON

printf '<?xml version="1.0"?>\n<labwc_config></labwc_config>\n' > "$sandbox/cfg/rc.xml"

labwc_pid=""
shell_pid=""
cleanup() {
    [ -n "$shell_pid" ] && { kill -9 "$shell_pid" 2>/dev/null; wait "$shell_pid" 2>/dev/null; }
    [ -n "$labwc_pid" ] && { kill "$labwc_pid" 2>/dev/null; wait "$labwc_pid" 2>/dev/null; }
    rm -f "$root/.input-settings-test.qml"
    rm -rf "$sandbox"
    return 0
}
trap cleanup EXIT INT TERM

list_sockets() {
    local f name suffix
    for f in "${XDG_RUNTIME_DIR:?}"/wayland-*; do
        [ -S "$f" ] || continue
        name="${f##*/}"; suffix="${name#wayland-}"
        case "$suffix" in '' | *[!0-9]*) continue ;; esac
        printf '%s\n' "$name"
    done | sort
}
before="$(list_sockets)"

env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET -u DISPLAY \
    WLR_BACKENDS=headless WLR_RENDERER=pixman XDG_CURRENT_DESKTOP=labwc:wlroots \
    labwc -C "$sandbox/cfg" >"$sandbox/labwc.log" 2>&1 &
labwc_pid=$!

nested=""
for _ in $(seq 1 60); do
    nested="$(comm -13 <(echo "$before") <(list_sockets) | head -1)"
    [ -n "$nested" ] && break
    sleep 0.25
done
if [ -z "$nested" ]; then
    echo "FAIL: headless labwc did not come up"
    tail -20 "$sandbox/labwc.log"
    exit 1
fi
echo "headless labwc on $nested"

# Staged into the repo root because Quickshell refuses to import QML modules
# from outside the directory holding the entry point.
cp "$here/input-settings-test.qml" "$root/.input-settings-test.qml"

run_as() { # compositor
    local comp="$1" log="$sandbox/$1.log"
    rm -f "$sandbox/home/.config/apex-shell/input.json" \
          "$sandbox/home/.config/apex-shell/ApexShellInput.kdl"
    echo
    echo "── as ${comp} ──"
    ( cd "$root" && env -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET -u DISPLAY \
        WAYLAND_DISPLAY="$nested" \
        XDG_CURRENT_DESKTOP="$comp" \
        HOME="$sandbox/home" \
        PATH="$shim:$PATH" \
        APEX_INPUT_GENERATOR="$GEN" \
        APEX_INPUT_DEVICES="$sandbox/devices.json" \
        APEX_TEST_COMPOSITOR="$comp" \
        QT_LOGGING_RULES="qml=true" \
        timeout 240 quickshell -p "$root/.input-settings-test.qml" ) >"$log" 2>&1
    sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E "PASS|FAIL|passed=" | sed 's/^/  /' || true
    local summary
    summary="$(grep -o "passed=[0-9]* failed=[0-9]*" "$log" | tail -1)"
    if [ -z "$summary" ]; then
        bad "the ${comp} run never reached its summary"
        tail -25 "$log" | sed 's/^/        /'
        return
    fi
    pass=$((pass + $(echo "$summary" | sed 's/passed=\([0-9]*\).*/\1/')))
    fail=$((fail + $(echo "$summary" | sed 's/.*failed=\([0-9]*\)/\1/')))
}

run_as labwc
run_as niri

echo
echo "input settings: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
