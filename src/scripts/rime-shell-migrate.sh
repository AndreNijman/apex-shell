#!/usr/bin/env bash
# ─── rime-shell-migrate ───────────────────────────────────────────────────────
# Move this shell's per-user data from its APEX names to its Rime names, once.
#
# ── Why ──────────────────────────────────────────────────────────────────────
#
# Until the rename the shell kept everything a user sets under
# ~/.config/apex-shell (settings.json, wallpaper.json, keybinds.json, tasks,
# plugins, input.json, display.json …), ~/.cache/apex-shell (colors.json, the
# prompt, the greeting accent) and ~/.local/state/apex-shell. The renamed shell
# reads and writes the rime-shell names. A machine that boots the first Rime
# image still holds every byte under the old ones, and the rename must not cost
# it any of them.
#
# ── The contract, for anything else that calls this ─────────────────────────
#
# Run it BEFORE anything creates ~/.config/rime-shell, ~/.cache/rime-shell or
# $XDG_STATE_HOME/rime-shell. The shell runs it first thing at start
# (shell.qml builds nothing until it exits); an OS provisioner that seeds those
# directories must run it before its first mkdir, because once the new
# directory exists this script refuses to touch the old one.
#
# The tree is chosen by HOME and XDG_STATE_HOME and by nothing else, so a test
# points it at a fixture with `HOME=/some/dir`.
#
# For every pair old -> new:
#   old absent, or old is a symlink to new             nothing: already done
#                                                      (dangling or not)
#   old is someone else's symlink, new absent          new becomes a symlink to
#                                                      the same target
#   old is a real directory/file and new is absent     rename (same filesystem,
#                                                      never a copy) and leave a
#                                                      relative symlink at old
#   new is an EMPTY regular file (files only)          the same: an empty file is
#                                                      the placeholder a
#                                                      provisioner pre-creates
#                                                      for niri, and holds nothing
#   anything else (both real)                          nothing, one "conflict"
#                                                      line on stderr
#
# The pairs:
#   ~/.config/apex-shell                 -> ~/.config/rime-shell
#   ~/.cache/apex-shell                  -> ~/.cache/rime-shell
#   ${XDG_STATE_HOME:-~/.local/state}/apex-shell -> …/rime-shell
#   inside the config directory, the files named for the old shell
#     ApexShellKeybinds.kdl ApexShellInput.kdl ApexShellKeybinds.conf
#     ApexShellKeybinds.lua                 -> RimeShell…  (niri `include`s the
#                                              old absolute path, so the old name
#                                              has to keep resolving)
#   two matugen outputs outside the shell's directories, which a user wires in
#   by hand:
#     ~/.config/hypr/apex-shell-colors.conf -> rime-shell-colors.conf
#     ~/.config/ghostty/apex-shell-colors   -> rime-shell-colors
#
# ~/.config/hypr/apex (Hyprland's modules) is NOT moved here: the OS owns that
# directory and its own migration moves it to ~/.config/hypr/rime.
#
# Success is read off the state afterwards, never off mv's exit code: GNU mv -n
# exits 0 when it declines to replace, measured on coreutils 9.7.
#
# When nothing under an old name is left, it writes ~/.config/rime-shell/
# .rime-shell-migrated, and a shell that finds that file starts without waiting
# for this script (see the end of this file).
#
# Idempotent. Always exits 0 — a shell that will not start because a migration
# failed is worse than a shell that starts on defaults and says why. One line
# per action on stdout, conflicts and failures on stderr.
#
# usage: rime-shell-migrate.sh [--dry-run]
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

log()  { printf 'rime-shell-migrate: %s\n' "$*"; }
warn() { printf 'rime-shell-migrate: %s\n' "$*" >&2; }

if [ -z "${HOME:-}" ] || [ ! -d "${HOME}" ]; then
    warn "HOME is not a directory; nothing to migrate"
    exit 0
fi

STATE_BASE="${XDG_STATE_HOME:-${HOME}/.local/state}"

# Two runs at once — the OS provisioner and the shell start at the same login —
# are safe without a lock (the rename refuses to replace), but serialising them
# keeps the log to one account of what happened. The lock lives in the runtime
# directory, so it never litters HOME and is gone at logout; a run with no
# runtime directory or no flock (a test, a bare TTY) goes unlocked.
lockdir="${XDG_RUNTIME_DIR:-}"
if command -v flock >/dev/null 2>&1 && [ -n "$lockdir" ] && [ -d "$lockdir" ] && [ -w "$lockdir" ]; then
    # The braces keep the 2>/dev/null to this one statement: on a bare `exec`
    # it would silence stderr for the rest of the script.
    if { exec 9>>"${lockdir}/rime-shell-migrate.lock"; } 2>/dev/null; then
        flock -w 5 9 2>/dev/null || warn "another migration is still running; going ahead anyway"
    fi
fi

# is_real PATH — exists and is not a symlink.
is_real() { [ -e "$1" ] && [ ! -L "$1" ]; }

# same_fs OLD — OLD sits on the filesystem of the directory it lives in. A
# mount point (or a bind mount) would make mv copy and delete, which is slow,
# is not atomic and is not what anyone asked for.
same_fs() {
    local a b
    a="$(stat -c %d -- "$1" 2>/dev/null)" || return 1
    b="$(stat -c %d -- "$(dirname -- "$1")" 2>/dev/null)" || return 1
    [ "$a" = "$b" ]
}

# move_one KIND OLD NEW — KIND is dir or file. Applies the table above.
move_one() {
    local kind="$1" old="$2" new="$3" target
    target="$(basename -- "$new")"

    if [ -L "$old" ]; then
        # Ours (or another migration's), in whatever form it was written, and
        # whether or not the new path still exists: `rime recover reset`
        # deletes the new directory and leaves this link dangling, and moving a
        # dead link into place would be the wrong repair.
        [ "$(readlink -m -- "$old")" = "$(readlink -m -- "$new")" ] && return 0
        # Someone's own link — a dotfiles checkout linked in as
        # ~/.config/apex-shell. Give the new name the same target and leave
        # theirs alone; both parents are the same directory, so a relative
        # target means the same thing from either name.
        if [ -e "$old" ] && [ ! -e "$new" ] && [ ! -L "$new" ]; then
            if [ "$DRY" = 1 ]; then
                log "would link $new to what $old points at"
            elif ln -s -- "$(readlink -- "$old")" "$new" 2>/dev/null; then
                log "linked $new to $(readlink -- "$old"), which $old already points at"
            else
                warn "could not link $new to what $old points at"
            fi
        fi
        return 0
    fi
    [ -e "$old" ] || return 0

    if [ "$kind" = dir ] && [ ! -d "$old" ]; then
        warn "conflict: $old is not a directory; left alone"
        return 0
    fi
    if [ "$kind" = file ] && [ ! -f "$old" ]; then
        warn "conflict: $old is not a regular file; left alone"
        return 0
    fi

    local replace_empty=0
    if [ -e "$new" ] || [ -L "$new" ]; then
        if [ "$kind" = file ] && [ -f "$new" ] && [ ! -L "$new" ] && [ ! -s "$new" ]; then
            replace_empty=1
        else
            warn "conflict: both $old and $new exist; neither was touched"
            return 0
        fi
    fi

    if ! same_fs "$old"; then
        warn "conflict: $old is a mount point or on another filesystem; not moved"
        return 0
    fi

    if [ "$DRY" = 1 ]; then
        log "would move $old -> $new$([ "$replace_empty" = 1 ] && printf ' (replacing an empty placeholder)')"
        return 0
    fi

    if [ "$replace_empty" = 1 ]; then
        # rename(2) over a file is atomic; the placeholder is gone and the real
        # content is in place in one step.
        mv -f -T -- "$old" "$new" 2>/dev/null
    else
        # -n: renameat2(RENAME_NOREPLACE). If something created $new since the
        # check above, this declines instead of replacing it (an empty
        # directory would otherwise be replaced silently).
        mv -n -T -- "$old" "$new" 2>/dev/null
    fi

    if [ -e "$old" ] && [ ! -L "$old" ]; then
        warn "conflict: $new appeared while $old was being moved; $old left in place"
        return 0
    fi
    if ! is_real "$new"; then
        warn "could not move $old to $new"
        return 0
    fi

    if ln -s -- "$target" "$old" 2>/dev/null; then
        log "moved $old -> $new (a symlink stays at the old path)"
    else
        warn "moved $old -> $new, but could not leave a symlink at $old"
    fi
}

cfg_old="${HOME}/.config/apex-shell"   # rime-rename: keep (the path an APEX shell wrote)
cfg_new="${HOME}/.config/rime-shell"
# Written when nothing is left to move; see the end of this file.
MARKER="${cfg_new}/.rime-shell-migrated"
cache_old="${HOME}/.cache/apex-shell"  # rime-rename: keep (the path an APEX shell wrote)
cache_new="${HOME}/.cache/rime-shell"
state_old="${STATE_BASE}/apex-shell"   # rime-rename: keep (the path an APEX shell wrote)
state_new="${STATE_BASE}/rime-shell"

move_one dir "$cfg_old"   "$cfg_new"
move_one dir "$cache_old" "$cache_new"
move_one dir "$state_old" "$state_new"

# Files inside the config directory that were named for the old shell. Looked
# for in the NEW directory, which is where they are once the directory moved —
# and a directory some other tool already moved gets the same treatment.
cfg_dir="$cfg_new"
# A dry run has moved nothing, so the files are still in the old directory.
[ "$DRY" = 1 ] && ! is_real "$cfg_new" && cfg_dir="$cfg_old"
if is_real "$cfg_dir" && [ -d "$cfg_dir" ]; then
    for base in Keybinds.kdl Input.kdl Keybinds.conf Keybinds.lua; do
        move_one file "${cfg_dir}/ApexShell${base}" "${cfg_dir}/RimeShell${base}"  # rime-rename: keep (old file names)
    done
fi

# matugen outputs outside the shell's own directories.
move_one file "${HOME}/.config/hypr/apex-shell-colors.conf" "${HOME}/.config/hypr/rime-shell-colors.conf"  # rime-rename: keep (old output name)
move_one file "${HOME}/.config/ghostty/apex-shell-colors"   "${HOME}/.config/ghostty/rime-shell-colors"    # rime-rename: keep (old output name)

# ── Done for good: the marker ────────────────────────────────────────────────
# shell.qml reads this file synchronously and, when it is there, builds at once
# instead of waiting for this script — so a machine that has nothing left to
# move starts exactly as it did before the rename. It is written only when
# NOTHING under an old name is still a real file or directory (a conflict left
# for a person keeps the shell waiting for this script at every start, which
# is the safe side), and only into a config directory that already exists: on
# a fresh install this never creates ~/.config/rime-shell.
pending=0
for p in "$cfg_old" "$cache_old" "$state_old" \
         "${HOME}/.config/hypr/apex-shell-colors.conf" \
         "${HOME}/.config/ghostty/apex-shell-colors"; do  # rime-rename: keep (old output names)
    is_real "$p" && pending=1
done
for base in Keybinds.kdl Input.kdl Keybinds.conf Keybinds.lua; do
    is_real "${cfg_new}/ApexShell${base}" && pending=1  # rime-rename: keep (old file names)
done
if [ "$DRY" = 0 ] && [ "$pending" = 0 ] && is_real "$cfg_new" && [ -d "$cfg_new" ] \
   && [ ! -s "$MARKER" ]; then
    printf 'rime-shell-migrate: nothing is left under the APEX names\n' > "$MARKER" 2>/dev/null \
        || warn "could not write $MARKER; the shell will wait for this script at every start"
fi

exit 0
