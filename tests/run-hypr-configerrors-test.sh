#!/usr/bin/env bash
# P0-025: the Lua this shell generates has to load in the Hyprland APEX ships.
#
#     ./tests/run-hypr-configerrors-test.sh
#
# ── Headless, on nothing you can see ────────────────────────────────────────
#
# It used to nest Hyprland inside the session named by WAYLAND_DISPLAY, with a
# header asking whoever ran it to please use a spare machine. It now nests
# inside a HEADLESS labwc from tests/lib/headless.sh — Hyprland inside labwc
# inside a private runtime directory — so there is nothing to ask.
#
# That this works at all contradicts what the tree said. nav-geometry's header
# records "nested in a headless labwc: comes up" and then discards the recipe
# because the Hyprland it produces publishes no output and never asks its Qt
# client for another frame. True, and irrelevant here: `hyprctl configerrors`,
# `hyprctl reload` and `hyprctl version` all answer perfectly well on an
# instance with no output, because none of them draws anything. Measured on
# 0.56.2: signature published, configerrors clean, reload ok, monitors [].
#
# The one thing that DOES need an output is the shell that generates the Lua,
# so it runs on the host labwc — which has one — with
# HYPRLAND_INSTANCE_SIGNATURE pointed at the nested Hyprland. The generator
# writes a file and calls `hyprctl reload`; neither needs to be a client of the
# compositor it is reloading. The "a real output" assertion the suite used to
# make is therefore replaced by one that proves the same thing without needing
# a monitor: the instance answers `hyprctl version` with its own version.
#
# ── What this proves, and what it does not ───────────────────────────────────
#
# The acceptance criterion is "hyprctl reload and hyprctl configerrors are clean
# after any generated change". configerrors needs a RUNNING Hyprland, so this
# starts one — nested, with its own HYPRLAND_INSTANCE_SIGNATURE, its own
# XDG_RUNTIME_DIR and its own HOME — and asks that instance, by signature, never
# the ambient one.
#
# It covers the module this repository generates, apex/shell-keybinds.lua,
# loaded through the same absent-tolerant loader the seeded hyprland.lua uses.
# It does not cover the apex-os modules beside it; those ship from another
# repository and are verified there.
#
# ── Never the developer's session ────────────────────────────────────────────
#
# hyprctl with no -i talks to the newest instance it can find, which on a
# Hyprland desktop is the one the developer is looking at. So:
#
#   1. Every hyprctl call here passes -i "$sig", and $sig is read from the
#      runtime directory this script created, by diffing against what was there
#      before it started Hyprland.
#   2. The script refuses to run if that signature matches the ambient
#      HYPRLAND_INSTANCE_SIGNATURE. A nested instance that somehow came up as
#      the host is a bug, and reloading it would be reloading the desk.
#   3. The generator runs with HYPRLAND_INSTANCE_SIGNATURE set to the nested
#      one, so KeybindService's own `hyprctl reload` — which takes no -i,
#      because in a real session there is only one — reaches the nested
#      instance and nothing else.
#   4. HOME is a sandbox, so every file written is inside it.
#
# ── Two compositors, and why ────────────────────────────────────────────────
#
# Hyprland 0.56.2 will not start on its own headless backend on a machine with a
# GPU and no DRM master: AQ_BACKENDS=headless dies in CBackend::create(). It
# does come up nested in another Wayland compositor, and that compositor does
# not have to be one anybody can see — a labwc on WLR_BACKENDS=headless is
# enough. The host labwc must NOT be on the pixman renderer: aquamarine asks it
# for a dmabuf, a software-rendered host has none to give, and the only symptom
# is CBackend::create() failing with nothing else said.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

headless_require Hyprland hyprctl quickshell

cleanup() {
    rm -f "$root/.keybind-lua-gen.qml"
    headless_cleanup
    return 0
}
trap cleanup EXIT INT TERM

headless_begin
# Every hyprctl below is aimed at the nested instance by signature, so the real
# binary has to be on PATH rather than the sandbox stub.
headless_unstub hyprctl
# The host labwc deliberately does NOT use WLR_RENDERER=pixman here, so the
# nested Hyprland has a dmabuf to ask it for. headless_start would set pixman,
# so the host is started by hand.
mkdir -p "$HEADLESS_W/cfg/labwc"
cp "$here/labwc-test-rc.xml" "$HEADLESS_W/cfg/labwc/rc.xml" 2>/dev/null || true
_before="$(headless_sockets)"
XDG_CONFIG_HOME="$HEADLESS_W/cfg" XDG_CURRENT_DESKTOP=labwc:wlroots \
    labwc >"$HEADLESS_W/comp.log" 2>&1 &
# shellcheck disable=SC2034  # headless_cleanup reads it, across the source
# boundary shellcheck cannot follow.
HEADLESS_COMP_PID=$!
host_sock="$(headless_wait_socket "$_before")"
[ -n "$host_sock" ] || {
    echo "SKIP: the host labwc for the nested Hyprland did not come up"
    tail -5 "$HEADLESS_W/comp.log" 2>/dev/null
    exit 0; }
export WAYLAND_DISPLAY="$host_sock"
headless_assert_private || exit 1
echo "host: headless labwc on $WAYLAND_DISPLAY ($(Hyprland --version 2>&1 | head -1))"

home="$HOME"
rt="$XDG_RUNTIME_DIR"
mkdir -p "$home/.config/hypr/apex"

# ── the config ───────────────────────────────────────────────────────────────
# The same shape apex-os seeds: a loader that skips a generated module that has
# not been written yet, records one that fails, and re-raises at the end so
# configerrors still reports it. Reproduced here rather than copied from the
# other repository, because this test has to run without it.
cat > "$home/.config/hypr/hyprland.lua" <<'LUA'
local failures = {}
for name in pairs(package.loaded) do
    if name:sub(1, 5) == "apex." then package.loaded[name] = nil end
end
local function apex(name)
    local module = "apex." .. name
    if not package.searchpath(module, package.path) then return nil end
    local ok, result = pcall(require, module)
    if ok then return result end
    failures[#failures + 1] = ("apex/%s.lua: %s"):format(name, tostring(result))
    return nil
end
hl.config({ general = { gaps_in = 5, border_size = 2 } })
apex("keybindings")
apex("shell-keybinds")
if #failures > 0 then
    error("APEX config modules failed to load:\n  " .. table.concat(failures, "\n  "), 0)
end
LUA

# The handle table the generated module disables APEX defaults through. Same
# contract as apex-os's apex/keybindings.lua: a `disable(mods, key)` and one
# bind to disable, so `claim()` in the generated file has something real to do.
cat > "$home/.config/hypr/apex/keybindings.lua" <<'LUA'
local M = { binds = {} }
local function key(mods, k)
    local parts = {}
    for w in tostring(mods):gsub("%+", " "):gmatch("%S+") do parts[#parts + 1] = w:upper() end
    table.sort(parts)
    return table.concat(parts, "+") .. ":" .. tostring(k):upper()
end
local function bind(mods, k, action)
    local combo = (mods ~= "" and (mods .. " + " .. k)) or k
    M.binds[key(mods, k)] = hl.bind(combo, action)
end
function M.disable(mods, k)
    local h = M.binds[key(mods, k)]
    if h and h.set_enabled then h:set_enabled(false) end
end
bind("SUPER", "T", hl.dsp.exec_cmd("true"))
bind("SUPER", "Q", hl.dsp.window.close())
return M
LUA

# ── start the nested instance ────────────────────────────────────────────────
before="$(ls "$rt/hypr" 2>/dev/null | tr '\n' ' ')"
env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u WLR_BACKENDS -u WLR_RENDERER \
    AQ_BACKENDS=wayland AQ_NO_MODIFIERS=1 \
    XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    HOME="$home" XDG_CURRENT_DESKTOP=Hyprland \
    Hyprland -c "$home/.config/hypr/hyprland.lua" >"$HEADLESS_W/hypr.log" 2>&1 &
hypr_pid=$!
# shellcheck disable=SC2034  # same: headless_cleanup kills it on the way out.
HEADLESS_NESTED_PID=$hypr_pid

sig=""
for _ in $(seq 1 40); do
    for s in "$rt"/hypr/*; do
        [ -e "$s" ] || continue
        s="${s##*/}"
        case " $before " in *" $s "*) continue ;; esac
        sig="$s"
    done
    [ -n "$sig" ] && [ -S "$rt/hypr/$sig/.socket.sock" ] && break
    kill -0 "$hypr_pid" 2>/dev/null || break
    sleep 0.5
done

if [ -z "$sig" ] || [ ! -S "$rt/hypr/$sig/.socket.sock" ]; then
    echo "SKIP: the nested Hyprland did not come up"
    grep -iE "backend|abort|what\(\)|Fatal" "$HEADLESS_W/hypr.log" | tail -6 | sed 's/^/        /'
    exit 0
fi

# Defence 2. A nested instance that reports the host's signature is not nested.
headless_assert_not_ambient_signature "$sig" || exit 1
echo "nested Hyprland: $sig"
ok "a nested instance came up with a signature of its own"

hc() { env XDG_RUNTIME_DIR="$rt" hyprctl -i "$sig" "$@" 2>&1; }

clean() {
    local what="$1" out
    out="$(hc configerrors)"
    case "$out" in
        ""|"no errors, yay!"*|*"no errors"*)
            ok "configerrors is clean $what" ;;
        *)
            bad "configerrors is not clean $what"
            echo "$out" | head -12 | sed 's/^/        /' ;;
    esac
}

# NOT "it has a monitor". A Hyprland nested in a headless labwc publishes no
# output at all, and nothing this suite asks it to do needs one. What has to be
# true is that the instance is alive and is the version under test, which is
# what the About panel's own probe asks for.
ver="$(hc version | head -1)"
case "$ver" in
    Hyprland\ [0-9]*) ok "the nested instance answers as itself ($ver)" ;;
    *)                bad "the nested instance did not answer hyprctl version ($ver)" ;;
esac
clean "with the generated module absent"

# ── generate ─────────────────────────────────────────────────────────────────
# Staged into the repo root: Quickshell will not import QML modules from outside
# the directory holding the entry point.
cp "$here/keybind-lua-gen.qml" "$root/.keybind-lua-gen.qml"
gen_log="$HEADLESS_W/gen.log"
# The generator runs on the HOST labwc, which has an output; the nested
# Hyprland is only ever the target of its `hyprctl reload`, which is why the
# signature is passed and the display is not.
( cd "$root" && env -u DISPLAY \
    XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    HOME="$home" XDG_CURRENT_DESKTOP=Hyprland \
    QT_LOGGING_RULES="qml=true" \
    timeout 180 quickshell -p "$root/.keybind-lua-gen.qml" ) >"$gen_log" 2>&1

lua="$home/.config/hypr/apex/shell-keybinds.lua"
if grep -q "GEN1-READY" "$gen_log" && [ -s "$lua" ]; then
    ok "the shipped generator wrote apex/shell-keybinds.lua"
else
    bad "the generator produced no Lua module"
    tail -20 "$gen_log" | sed 's/^/        /'
    echo
    echo "passed=$pass failed=$fail"
    exit 1
fi

grep -q "APEX-SHELL-GENERATED" "$lua" \
    && ok "the generated module carries its marker" \
    || bad "the generated module has no marker, so the rescue cannot recognise it"
grep -q 'pcall(require, "apex.shell-keybinds-user")' "$lua" \
    && ok "the generated module requires the user's own binds" \
    || bad "the generated module does not load apex/shell-keybinds-user.lua"
grep -q "hyprctl dispatch" "$lua" \
    && bad "the generator is still shelling out to hyprctl dispatch" \
    || ok "no bind spawns hyprctl to talk to the compositor it is running in"

hc reload >/dev/null
sleep 1
clean "after the first generated write"

if grep -q "GEN2-READY" "$gen_log"; then
    ok "a rebind through the Keybinds page path regenerated the module"
else
    bad "the second generation never completed"
    tail -20 "$gen_log" | sed 's/^/        /'
fi
grep -q 'hl.bind("SUPER + SHIFT + T"' "$lua" \
    && ok "the rebound combo is in the module" \
    || bad "the rebind did not reach the generated file"
grep -q 'claim("SUPER", "T")' "$lua" \
    && ok "the APEX default on the vacated combo is claimed, not left double-bound" \
    || bad "nothing disables the default the rebind replaced"

hc reload >/dev/null
sleep 1
clean "after a generated change"

# ── the rescue does not break the config ─────────────────────────────────────
# The module the rescue creates is required by the generated one, so a rescue
# that produced something Hyprland cannot load would take the keybinds down.
# Exactly the state apex-hypr-migrate leaves behind: the user's converted binds
# at the generated module's path, with no marker. Then a shell start over it.
cat > "$lua" <<'LUA'
-- Migrated from the hyprlang ApexShellKeybinds fragment by apex-hypr-migrate
hl.bind("SUPER + G", hl.dsp.exec_cmd("true"))
LUA
user="$home/.config/hypr/apex/shell-keybinds-user.lua"
rm -f "$user"
# The generator runs on the HOST labwc, which has an output; the nested
# Hyprland is only ever the target of its `hyprctl reload`, which is why the
# signature is passed and the display is not.
( cd "$root" && env -u DISPLAY \
    XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    HOME="$home" XDG_CURRENT_DESKTOP=Hyprland \
    QT_LOGGING_RULES="qml=true" \
    timeout 180 quickshell -p "$root/.keybind-lua-gen.qml" ) >"$HEADLESS_W/gen2.log" 2>&1

grep -q 'SUPER + G' "$user" 2>/dev/null \
    && ok "a migrated bind at the generated path survives the next shell start" \
    || bad "the shell overwrote a keybind the migration carried across"
grep -q "APEX-SHELL-GENERATED" "$lua" \
    && ok "and the generated module was still written" \
    || bad "the rescue stopped the generator from writing"

hc reload >/dev/null
sleep 1
clean "with a rescued user module loaded"

hc dispatch exit >/dev/null 2>&1
sleep 1
hypr_pid=""

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
