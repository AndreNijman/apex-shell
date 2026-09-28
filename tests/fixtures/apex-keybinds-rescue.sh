#!/usr/bin/env bash
# ─── apex-keybinds-rescue ─────────────────────────────────────────────────────
# Get out of the way of a keybind file this shell did not write.
#
# ── The collision ────────────────────────────────────────────────────────────
#
# KeybindService generates ~/.config/hypr/apex/shell-keybinds.lua and rewrites
# it, whole, every time the shell starts. That is fine for a file only the
# generator ever writes.
#
# It is not the only writer. apex-hypr-migrate — the hyprlang-to-Lua migration
# in apex-os — converts the user's old ~/.config/apex-shell/ApexShellKeybinds.conf
# and writes the result to that exact path, because that is where the Lua module
# of the same name has to live. The migration goes to real trouble to carry a
# hand-edited keybind across; the next shell start then overwrote the lot,
# without a word. "No user custom keybind is silently discarded" is one of
# P0-025's acceptance criteria and that is precisely how it was being broken.
#
# ── What this does about it ──────────────────────────────────────────────────
#
# Before the generator writes, anything at that path with no APEX-SHELL-GENERATED
# marker in it is moved to apex/shell-keybinds-user.lua — a file the generator
# never touches — and the generated module requires that at the end. So the
# binds keep working, in a file that is now the user's, and the console says
# where they went. Running twice changes nothing: the second run finds the
# marker and stops.
#
# Never fails the save. A keybind edit that silently does not apply is worse
# than one that applies with an untidy backup beside it, so every failure here
# is reported and exits 0.
#
# usage: apex-keybinds-rescue.sh <generated-lua-path> [marker]
set -uo pipefail

target="${1:-}"
marker="${2:-APEX-SHELL-GENERATED}"

[ -n "$target" ] || { echo "usage: $0 <generated-lua-path> [marker]" >&2; exit 0; }
[ -e "$target" ] || exit 0
grep -q "$marker" "$target" 2>/dev/null && exit 0

dir="$(dirname "$target")"
user="$dir/shell-keybinds-user.lua"
when="$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo unknown)"

mkdir -p "$dir" 2>/dev/null

if [ -e "$user" ]; then
    # Appended rather than moved aside: a second unmarked file is rarer than a
    # user who has already been rescued once, and a Lua chunk is a sequence of
    # statements, so concatenating two of them is a valid module. Re-declaring
    # a local is legal.
    {
        printf '\n-- ── carried over %s ─────────────────────────────────────\n' "$when"
        cat "$target"
    } >> "$user" || { echo "apex-keybinds-rescue: could not append to $user" >&2; exit 0; }
else
    {
        cat <<'HEAD'
-- ==============================================================================
-- Your own Hyprland keybinds
-- ==============================================================================
-- APEX Shell found keybinds at apex/shell-keybinds.lua that it had not written
-- — hand-edited, or carried across by apex-hypr-migrate from the hyprlang
-- ApexShellKeybinds.conf — and moved them here before regenerating that file.
--
-- This file is YOURS. Nothing regenerates it. apex/shell-keybinds.lua requires
-- it last, so a combo bound in both places runs this one too.
--
-- Hyprland fires BOTH actions for a combo that is bound twice. If a key here
-- also has an APEX default, switch the default off first:
--
--     local defaults = require("apex.keybindings")
--     defaults.disable("SUPER", "Q")
-- ==============================================================================

HEAD
        cat "$target"
    } > "$user" || { echo "apex-keybinds-rescue: could not write $user" >&2; exit 0; }
fi

echo "apex-keybinds-rescue: $target was not written by this shell; your keybinds are now in $user and are still loaded" >&2
exit 0
