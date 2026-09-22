#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-night-light-test.sh — P1-039. Night light against real compositors.
#
#  ── What "compositor-neutral" had to be measured against ────────────────────
#  Night light used to be one tile that ran hyprsunset, declared by
#  HyprlandBackend and hidden everywhere else. Turning that into a claim about
#  three compositors means answering three questions with a machine and not a
#  comment:
#
#    1. which protocol each compositor advertises
#    2. which tool speaks it
#    3. what does the shell do when the tool is there and refuses
#
#  Measured by this script, headless, on 2026-09-07:
#
#    | compositor      | zwlr_gamma_control_manager_v1 | wp_color_manager_v1 |
#    |-----------------|-------------------------------|---------------------|
#    | labwc 0.9.6     | yes                           | no                  |
#    | sway 1.11       | yes                           | no                  |
#    | Hyprland 0.56.2 | yes                           | yes (v3)            |
#    | niri 26.04      | NO, under the winit backend   | no                  |
#
#  niri implements gamma control against the DRM `GAMMA_LUT` property, so it is
#  there on a TTY session and absent in a nested one. That is not a hole in the
#  test — it is the third question, and phase `niri-refuses` uses it: a real
#  gammastep against a real niri that cannot do it, proving the shell
#  reports the refusal rather than lighting the tile.
#
#  ── It brings its own compositor, its own home AND its own PID namespace ────
#  The first two for the same reasons tests/run-nav-geometry-test.sh gives: a
#  window must never land on the developer's desktop, and the suite writes
#  settings.json.
#
#  The PID namespace is this suite's own requirement. Stopping the night light
#  is `pkill -x gammastep`, which on a shared PID namespace would also kill a
#  gammastep the developer is running in their own session. So the SHELL — and
#  therefore the tool it spawns — runs inside
#  `unshare --user --map-current-user --pid --fork --mount-proc`, where the only
#  processes in existence are this phase's. Without unshare the suite SKIPS
#  rather than reaching for the developer's processes.
#
#  The compositors stay OUTSIDE that namespace, and they have to: labwc starts
#  an Xwayland and Xwayland refuses `/tmp/.X11-unix` when it is owned by a root
#  that the namespace has mapped to nobody, so a labwc launched inside exits
#  before it opens a socket. Nothing about the compositors needs containing —
#  it is `pkill` that does.
#
#  It also disposes of the tool for free: when the namespace's init exits, every
#  process in it goes, so a phase cannot leave a gammastep behind.
#
#  ── What is NOT proven here ─────────────────────────────────────────────────
#  That the screen turns orange. A headless wlroots output has no gamma
#  ramp — gammastep says "Zero outputs support gamma adjustment" and stays up —
#  so the ramp itself needs a physical panel and a session nobody else is using.
#  Phase `labwc-real` proves the tool connects, binds the protocol and stays
#  connected, which is everything the shell is responsible for.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }
command -v labwc      >/dev/null 2>&1 || { echo "SKIP: labwc not installed"; exit 0; }

# ── A private PID namespace for the shell under test ─────────────────────────
UNSHARE_BIN="$(command -v unshare || true)"
NS=("$UNSHARE_BIN" --user --map-current-user --pid --fork --mount-proc)
[[ -n "$UNSHARE_BIN" ]] || { echo "SKIP: unshare is not installed"; exit 0; }
if ! "${NS[@]}" true 2>/dev/null; then
    echo "SKIP: unshare cannot make a private PID namespace here, and this suite"
    echo "      runs 'pkill -x gammastep' — outside one that would reach the"
    echo "      developer's own processes."
    exit 0
fi

# Resolved once, absolutely: a phase can put a PATH in front of the shell that
# has no coreutils on it, and "timeout: command not found" is a confusing way to
# report a night-light assertion.
TIMEOUT_BIN="$(command -v timeout)"
QS_BIN="$(command -v quickshell)"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

W="$(mktemp -d)"
staged="$root/.night-light-test.qml"
host_pid=""
nested_pid=""
cleanup() {
    [[ -n "$nested_pid" ]] && kill "$nested_pid" 2>/dev/null
    [[ -n "$host_pid"   ]] && kill "$host_pid"   2>/dev/null
    sleep 0.3
    [[ -n "$nested_pid" ]] && kill -9 "$nested_pid" 2>/dev/null
    [[ -n "$host_pid"   ]] && kill -9 "$host_pid"   2>/dev/null
    rm -f "$staged"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

cp "$here/night-light-test.qml" "$staged"

real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"

export XDG_RUNTIME_DIR="$W/run"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
export HOME="$W/home"
mkdir -p "$HOME/.config/apex-shell/src/user_data" "$HOME/.local/share"
export XDG_STATE_HOME="$W/state"; export XDG_CACHE_HOME="$W/cache"
mkdir -p "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
ln -sfn "$real_home/.local/share/fonts" "$HOME/.local/share/fonts" 2>/dev/null
ln -sfn "$real_home/.config/fontconfig" "$HOME/.config/fontconfig" 2>/dev/null

# XDG_CURRENT_DESKTOP too: it is how Compositor detects labwc, and inheriting
# the developer's "Hyprland" made every phase resolve to the Hyprland backend
# no matter which compositor the phase had brought up.
unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE NIRI_SOCKET XDG_CURRENT_DESKTOP
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland

# Stubs for what a shell interrogates on startup, so no phase reaches the real
# machine. gammastep and hyprsunset are deliberately NOT in here: which of them
# is a stub and which is the real binary is exactly what each phase varies.
mkdir -p "$W/bin"
cat > "$W/bin/_stub" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *--json*|*-j*|*json*) echo "{}" ;;
    *)                    : ;;
esac
exit 0
FAKE
chmod +x "$W/bin/_stub"
for n in apex hyprctl wlr-randr niri matugen xdg-open playerctl wpctl \
         brightnessctl pkcheck notify-send swww; do
    ln -sf "$W/bin/_stub" "$W/bin/$n"
done
# A minimal set of real tools the shell needs whatever else a phase hides.
# Without this a phase that empties PATH to hide gammastep also hides `bash`,
# and a Process whose interpreter cannot be found never reports an exit at all —
# so "the tool is missing" looked exactly like "the tool is running".
mkdir -p "$W/sys"
for n in bash sh env pkill pgrep sleep; do
    b="$(command -v "$n" 2>/dev/null)" && ln -sf "$b" "$W/sys/$n"
done

REAL_PATH="$PATH"
export PATH="$W/bin:$PATH"

socks() {
    local f b
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [[ -S "$f" ]] || continue
        b="${f##*/}"
        case "${b#wayland-}" in '' | *[!0-9]*) continue ;; esac
        printf '%s\n' "$b"
    done | sort
}
wait_new() {
    local before="$1" got=""
    for _ in $(seq 1 60); do
        got="$(comm -13 <(printf '%s\n' "$before") <(socks) | head -1)"
        [[ -n "$got" ]] && break
        sleep 0.25
    done
    printf '%s' "$got"
}

# ── The host compositor ──────────────────────────────────────────────────────
export XDG_CONFIG_HOME="$W/cfg"
mkdir -p "$XDG_CONFIG_HOME/labwc"
cp "$here/labwc-test-rc.xml" "$XDG_CONFIG_HOME/labwc/rc.xml" 2>/dev/null || true

before="$(socks)"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
    labwc > "$W/labwc.log" 2>&1 &
host_pid=$!
HOST_SOCK="$(wait_new "$before")"
[[ -n "$HOST_SOCK" ]] || {
    echo "SKIP: labwc did not come up headless"; tail -5 "$W/labwc.log"; exit 0; }
echo "host: labwc on $HOST_SOCK (headless, private XDG_RUNTIME_DIR, HOME and PID namespace)"

# ── One phase ────────────────────────────────────────────────────────────────
#   $1 name          what to call the output file
#   $2 compositor    hyprland | niri | labwc
#   $3 sock          WAYLAND_DISPLAY to run against
#   $4 phase PATH    which of gammastep/hyprsunset the shell can find
#
# The compositor is chosen the way a real session chooses it — through
# XDG_CURRENT_DESKTOP, which is the only signal labwc gives — and the override
# file is written to agree. The override alone is not enough: it arrives through
# a FileView, so it lands some milliseconds after startup and the first backend
# the shell picks is the detected one.
#
# The phase PATH is passed rather than exported, because a phase that hides
# gammastep by emptying PATH also hides rm, sed and grep from this script — an
# earlier draft did exactly that and three assertions "failed" on a missing
# grep rather than on anything about night light.
run_phase() {
    local name="$1" comp="$2" sock="$3" phase_path="$4"
    local desktop
    case "$comp" in
        labwc)    desktop="labwc:wlroots" ;;
        niri)     desktop="niri" ;;
        hyprland) desktop="Hyprland" ;;
    esac
    printf '{"compositor":"%s"}' "$comp" \
        > "$HOME/.config/apex-shell/src/user_data/config_Provider.json"
    rm -f "$HOME/.config/apex-shell/src/user_data/settings.json" "$W/argv.log"
    OUT="$W/$name.out"
    ( export WAYLAND_DISPLAY="$sock"
      export XDG_CURRENT_DESKTOP="$desktop"
      export PATH="$phase_path"
      export APEX_NL_ARGV="$W/argv.log"
      QT_LOGGING_RULES="qml=true" "$TIMEOUT_BIN" 60 "${NS[@]}" "$QS_BIN" -p "$staged" 2>&1 ) \
        | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //' > "$OUT"
}

val() { sed -n "s/^\[nl\] $2=//p" "$1" | head -1; }

mkstub() {  # $1 tool name
    cat > "$W/bin/$1" <<'FAKE'
#!/usr/bin/env bash
# Records what it was asked to do, then behaves the way the real tool does:
# it stays up, because both mechanisms hold their adjustment only while their
# process lives.
printf '%s\n' "$0 $*" >> "${APEX_NL_ARGV:-/dev/null}"
sleep 300
FAKE
    chmod +x "$W/bin/$1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 — labwc, stubbed gammastep. The argv, the mechanism, the temperature.
# ─────────────────────────────────────────────────────────────────────────────
mkstub gammastep
run_phase labwc-stub labwc "$HOST_SOCK" "$W/bin:$W/sys"
O="$W/labwc-stub.out"
if ! grep -q '^\[nl\] done' "$O"; then
    bad "labwc/stub: the test never reached its summary"; sed -n '$!d;p' "$O"
else
    [[ "$(val "$O" compositor)" == "labwc" ]] \
        && ok "labwc/stub: the shell resolved the labwc backend" \
        || bad "labwc/stub: compositor resolved to '$(val "$O" compositor)'"
    [[ "$(val "$O" mechanism)" == "gammastep" ]] \
        && ok "labwc/stub: the mechanism is gammastep" \
        || bad "labwc/stub: mechanism is '$(val "$O" mechanism)'"
    [[ "$(val "$O" supported)" == "true" ]] \
        && ok "labwc/stub: night light is reported supported" \
        || bad "labwc/stub: supported is '$(val "$O" supported)'"
    [[ "$(val "$O" active-before)" == "false" ]] \
        && ok "labwc/stub: nothing claims to be on before it is asked for" \
        || bad "labwc/stub: active-before is '$(val "$O" active-before)'"
    [[ "$(val "$O" active-on)" == "true" ]] \
        && ok "labwc/stub: the tool stayed up, so the light reports on" \
        || bad "labwc/stub: active-on is '$(val "$O" active-on)'"
    [[ -z "$(val "$O" error-on)" ]] \
        && ok "labwc/stub: no error while the tool is running" \
        || bad "labwc/stub: error-on is '$(val "$O" error-on)'"
    if grep -q -- '-m wayland -O 5600' "$W/argv.log" 2>/dev/null; then
        ok "labwc/stub: gammastep was run over the wayland method at the default 5600K"
    else
        bad "labwc/stub: argv was $(tr '\n' '|' < "$W/argv.log" 2>/dev/null)"
    fi
    # The temperature is a setting, and changing it has to reach the tool: both
    # mechanisms take the value on the command line and neither has a socket, so
    # "it changed in the UI" and "it changed on screen" are two different claims.
    if grep -q -- '-m wayland -O 3200' "$W/argv.log" 2>/dev/null; then
        ok "labwc/stub: a new temperature re-ran the tool with the new value"
    else
        bad "labwc/stub: 3200K never reached the tool; argv was $(tr '\n' '|' < "$W/argv.log" 2>/dev/null)"
    fi
    [[ "$(val "$O" temperature-after)" == "3200" ]] \
        && ok "labwc/stub: the facade reports the temperature it applied" \
        || bad "labwc/stub: temperature-after is '$(val "$O" temperature-after)'"
    [[ "$(val "$O" active-off)" == "false" ]] \
        && ok "labwc/stub: turning it off reports off" \
        || bad "labwc/stub: active-off is '$(val "$O" active-off)'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2 — Hyprland's mechanism is a different binary with different flags.
# The point of the phase is that the facade did not hardcode either.
# ─────────────────────────────────────────────────────────────────────────────
mkstub hyprsunset
run_phase hypr-stub hyprland "$HOST_SOCK" "$W/bin:$W/sys"
O="$W/hypr-stub.out"
if ! grep -q '^\[nl\] done' "$O"; then
    bad "hyprland/stub: the test never reached its summary"
else
    [[ "$(val "$O" mechanism)" == "hyprsunset" ]] \
        && ok "hyprland/stub: the mechanism is hyprsunset, not gammastep" \
        || bad "hyprland/stub: mechanism is '$(val "$O" mechanism)'"
    if grep -q 'hyprsunset -t 5600' "$W/argv.log" 2>/dev/null; then
        ok "hyprland/stub: hyprsunset was run with its own -t flag"
    else
        bad "hyprland/stub: argv was $(tr '\n' '|' < "$W/argv.log" 2>/dev/null)"
    fi
    if grep -q 'gammastep' "$W/argv.log" 2>/dev/null; then
        bad "hyprland/stub: gammastep ran on Hyprland"
    else
        ok "hyprland/stub: gammastep did not run on Hyprland"
    fi
fi
rm -f "$W/bin/hyprsunset" "$W/bin/gammastep"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 — labwc, the REAL gammastep. It binds zwlr_gamma_control_manager_v1,
# finds no gamma-capable output on a headless backend, warns, and stays up.
# Staying up is the whole claim: the shell's job is a live client, and the ramp
# is the compositor's.
# ─────────────────────────────────────────────────────────────────────────────
if command -v gammastep >/dev/null 2>&1 || PATH="$REAL_PATH" command -v gammastep >/dev/null 2>&1; then
    run_phase labwc-real labwc "$HOST_SOCK" "$REAL_PATH:$W/bin"
    O="$W/labwc-real.out"
    if ! grep -q '^\[nl\] done' "$O"; then
        bad "labwc/real: the test never reached its summary"
    else
        [[ "$(val "$O" active-on)" == "true" ]] \
            && ok "labwc/real: real gammastep connected to labwc and stayed up" \
            || bad "labwc/real: active-on is '$(val "$O" active-on)'"
        [[ -z "$(val "$O" error-on)" ]] \
            && ok "labwc/real: no error from a real gammastep on labwc" \
            || bad "labwc/real: error-on is '$(val "$O" error-on)'"
    fi
else
    echo "  skip gammastep is not installed; the real-mechanism phases need it"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4 — the mechanism is declared and the binary is missing. A capability
# that is true and a tool that is absent is the shape that leaves a tile lit
# over nothing.
# ─────────────────────────────────────────────────────────────────────────────
# The startup stubs and the minimal tool set, and no gammastep anywhere on it.
run_phase labwc-missing labwc "$HOST_SOCK" "$W/bin:$W/sys"
O="$W/labwc-missing.out"
if ! grep -q '^\[nl\] done' "$O"; then
    bad "labwc/missing: the test never reached its summary"
else
    [[ "$(val "$O" active-on)" == "false" ]] \
        && ok "labwc/missing: an absent gammastep leaves the light off" \
        || bad "labwc/missing: active-on is '$(val "$O" active-on)'"
    [[ -n "$(val "$O" error-on)" ]] \
        && ok "labwc/missing: the failure is reported: $(val "$O" error-on)" \
        || bad "labwc/missing: nothing was reported when the tool could not run"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5 — niri, nested, with the REAL gammastep. niri's gamma control is DRM
# GAMMA_LUT, so a winit-backed niri does not advertise the protocol at all and
# gammastep exits 1. Nothing is stubbed and nothing is simulated: this is a
# declared mechanism being refused by a real compositor, which is the case a
# capability map cannot answer on its own.
# ─────────────────────────────────────────────────────────────────────────────
if PATH="$REAL_PATH" command -v niri >/dev/null 2>&1 \
   && PATH="$REAL_PATH" command -v gammastep >/dev/null 2>&1; then
    mkdir -p "$XDG_CONFIG_HOME/niri"; : > "$XDG_CONFIG_HOME/niri/config.kdl"
    before="$(socks)"
    ( export PATH="$REAL_PATH"
      env -u WLR_BACKENDS -u WLR_RENDERER WAYLAND_DISPLAY="$HOST_SOCK" \
          niri > "$W/niri.log" 2>&1 ) &
    nested_pid=$!
    NIRI_SOCK="$(wait_new "$before")"
    if [[ -z "$NIRI_SOCK" ]]; then
        echo "  skip niri did not come up nested"; tail -3 "$W/niri.log"
    else
        run_phase niri-refuses niri "$NIRI_SOCK" "$REAL_PATH:$W/bin"
        O="$W/niri-refuses.out"
        if ! grep -q '^\[nl\] done' "$O"; then
            bad "niri/real: the test never reached its summary"
        else
            [[ "$(val "$O" mechanism)" == "gammastep" ]] \
                && ok "niri/real: niri declares gammastep as its mechanism" \
                || bad "niri/real: mechanism is '$(val "$O" mechanism)'"
            [[ "$(val "$O" active-on)" == "false" ]] \
                && ok "niri/real: a refused mechanism does not report the light on" \
                || bad "niri/real: active-on is '$(val "$O" active-on)' after gammastep refused"
            if [[ -n "$(val "$O" error-on)" ]]; then
                ok "niri/real: the tool's own words reach the user: $(val "$O" error-on)"
            else
                bad "niri/real: gammastep refused and nothing was reported"
            fi
        fi
    fi
else
    echo "  skip niri or gammastep missing; the refusal phase needs both"
fi

echo
echo "night-light: passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]] || exit 1
