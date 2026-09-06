#!/usr/bin/env bash
# P0-025: the shell writes Lua, and it does not eat a keybind it did not write.
#
#     ./tests/check-keybind-lua.sh
#
# ── The bug this exists for ──────────────────────────────────────────────────
#
# ~/.config/hypr/apex/shell-keybinds.lua has two writers. KeybindService
# regenerates it, whole, on every shell start. apex-hypr-migrate — the
# hyprlang-to-Lua migration in apex-os — converts the user's old
# ~/.config/apex-shell/ApexShellKeybinds.conf and writes the result to that same
# path, because it is the only name `require` can reach the module by.
#
# So the migration carried a hand-edited keybind across, and the next shell
# start silently deleted it. That is P0-025's "no user custom keybind, rule,
# monitor or input state is silently discarded, and generation does not
# overwrite user-owned custom Lua" — broken by the shell, not by the migration.
#
# The half of this file that runs the rescue script for real is the half that
# matters; the greps only stop the generator from drifting away from it.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

svc="$root/src/services/config_tab/KeybindService.qml"
rescue="$root/src/scripts/apex-keybinds-rescue.sh"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

[ -f "$svc" ]    || { echo "FAIL: no KeybindService.qml"; exit 1; }
[ -f "$rescue" ] || { echo "FAIL: no apex-keybinds-rescue.sh"; exit 1; }

echo "── the artifact is Lua, under the only directory require can name ──"

want "the Hyprland artifact is apex/shell-keybinds.lua" \
    grep -q '/apex/shell-keybinds.lua' "$svc"
# In code, not in the comments explaining why it is gone.
want "the hyprlang generator is not back" \
    bash -c 'sed "s|//.*||" "$1" | grep -q "ApexShellKeybinds.conf" && exit 1; exit 0' _ "$svc"
want "the generated module carries a marker the shell can recognise" \
    grep -q '_luaMarker: *"APEX-SHELL-GENERATED"' "$svc"
want "the generated module requires the user's own binds" \
    grep -q 'pcall(require, " *+ *root._luaStr(root._userModule)' "$svc"
# Order, not presence. A rescue that runs after the write has already lost the
# file it was meant to save.
wf_body="$(sed -n '/function _writeFiles/,/^    }/p' "$svc")"
wf_rescue="$(grep -nF 'bash "$5"' <<<"$wf_body" | head -1 | cut -d: -f1)"
wf_write="$(grep -nF 'printf %s' <<<"$wf_body" | head -1 | cut -d: -f1)"
if [ -n "$wf_rescue" ] && [ -n "$wf_write" ] && [ "$wf_rescue" -lt "$wf_write" ]; then
    ok "the rescue runs before the generated file is written"
else
    bad "the rescue does not run first (rescue=${wf_rescue:-none} write=${wf_write:-none})"
fi

# apex/keybindings.lua binds SUPER+T, SUPER+Q, SUPER+W, SUPER+E, SUPER+L and
# both Print keys — the same actions this generator owns. Rebinding one and
# claiming only the NEW combo leaves the old key firing the OS default, which is
# a rebind that did not rebind. The hyprlang generator got this right by
# accident, emitting an unbind for every default on every write.
want "a default the user moved off is released, not just the combo they moved to" \
    bash -c 'sed -n "/function _genLua/,/^    }/p" "$1" | grep -q "has moved off its default combo"' _ "$svc"

echo
echo "── the rescue, run for real ──"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
apex="$work/hypr/apex"
mkdir -p "$apex"
target="$apex/shell-keybinds.lua"
user="$apex/shell-keybinds-user.lua"

# 1  nothing there
rm -f "$target" "$user"
bash "$rescue" "$target" >/dev/null 2>&1
[ ! -e "$user" ] \
    && ok "a first install with no file rescues nothing" \
    || bad "the rescue invented a user module out of nothing"

# 2  a file this shell did not write — the migration's output
cat > "$target" <<'EOF'
-- Migrated from ApexShellKeybinds.conf by apex-hypr-migrate
hl.bind("SUPER + G", hl.dsp.exec_cmd("gimp"))
hl.bind("SUPER + SHIFT + M", hl.dsp.exec_cmd("my-own-script --flag"))
EOF
out="$(bash "$rescue" "$target" 2>&1)"
if [ -f "$user" ] && grep -q 'my-own-script --flag' "$user"; then
    ok "an unmarked file's binds are moved to the user module, verbatim"
else
    bad "the user's own binds did not survive"
fi
grep -q 'SUPER + G' "$user" 2>/dev/null \
    && ok "every bind is carried, not just the last one" \
    || bad "the rescue dropped a bind"
grep -q "$user" <<<"$out" \
    && ok "the rescue says where the binds went" \
    || bad "the rescue moved the file and said nothing (output: $out)"
grep -qi 'never regenerated\|Nothing regenerates it' "$user" 2>/dev/null \
    && ok "the user module says it is the user's" \
    || bad "the user module has no header explaining what it is"

# 3  idempotent: the generated file, marked, is left alone
before="$(md5sum < "$user")"
cat > "$target" <<'EOF'
-- APEX-SHELL-GENERATED — rewritten in full every time the shell starts.
hl.bind("SUPER + Q", hl.dsp.window.close())
pcall(require, "apex.shell-keybinds-user")
EOF
bash "$rescue" "$target" >/dev/null 2>&1
after="$(md5sum < "$user")"
[ "$before" = "$after" ] \
    && ok "a marked file is left alone; running twice changes nothing" \
    || bad "the rescue swallowed its own generated output"
grep -q 'SUPER + Q' "$user" 2>/dev/null \
    && bad "the generated binds leaked into the user module" \
    || ok "the generated binds stayed out of the user module"

# 4  a second unmarked file, with a user module already there
cat > "$target" <<'EOF'
hl.bind("SUPER + Z", hl.dsp.exec_cmd("zed"))
EOF
bash "$rescue" "$target" >/dev/null 2>&1
if grep -q 'my-own-script --flag' "$user" && grep -q 'SUPER + Z' "$user"; then
    ok "a second rescue appends rather than overwriting the first"
else
    bad "the second rescue destroyed what the first one saved"
fi

# 5  the result has to be a module Hyprland can load
if command -v luajit >/dev/null 2>&1; then
    # -b compiles and does not run: the module calls hl.bind, which only exists
    # inside Hyprland's Lua state. This is a parse check, and says so.
    if luajit -b "$user" /dev/null >/dev/null 2>&1; then
        ok "the rescued module parses as Lua"
    else
        bad "the rescue produced a file Lua cannot load"
    fi
else
    echo "  SKIP  no luajit; the rescued module was not parsed"
fi

# 6  never block a save
chmod 0500 "$apex" 2>/dev/null
cat > "$work/ro-target.lua" <<'EOF'
hl.bind("SUPER + Y", hl.dsp.exec_cmd("true"))
EOF
mkdir -p "$work/ro"; cp "$work/ro-target.lua" "$work/ro/shell-keybinds.lua"; chmod 0500 "$work/ro"
bash "$rescue" "$work/ro/shell-keybinds.lua" >/dev/null 2>&1
code=$?
chmod 0700 "$apex" "$work/ro" 2>/dev/null
[ "$code" -eq 0 ] \
    && ok "a rescue that cannot write still exits 0, so the save is not blocked" \
    || bad "a failed rescue blocks every keybind save (exit $code)"

echo
echo "check-keybind-lua: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
