#!/usr/bin/env bash
# Screenshot, on any supported compositor.
#
# ── Why this is not just `grimblast` ─────────────────────────────────────────
# grimblast is a HYPRLAND tool. It refuses to start without
# HYPRLAND_INSTANCE_SIGNATURE and shells out to `hyprctl` in a dozen places to
# find the focused monitor and the active window. Under labwc or niri it exits
# immediately with "HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)"
# and no file is produced — which is exactly how screenshots were silently dead
# on labwc.
#
# So: use grimblast where it works (keeping its clipboard handling and its
# notification on Hyprland), and fall back to plain grim/slurp everywhere else.
# grim and slurp are compositor-agnostic — they use wlr-screencopy and
# layer-shell, which labwc and niri both implement.
#
# ── The screen freezes while an area is picked ──────────────────────────────
# `hyprpicker -rz` is put up first: a still of every output, drawn on an overlay
# layer, with no zoom lens (-z) and so no colour readout either (hyprpicker 0.4.7
# only draws that inside the lens). slurp selects over the still and grim
# captures it, so a video, a tooltip or a menu is taken as it was when the key
# went down rather than as it has become by the time the drag ends. grimblast
# does this itself with --freeze; the grim path does the same by hand. Measured
# in a nested Hyprland 0.56.2 and a headless labwc: grim reads the frozen frame
# while the live screen under it has changed, and the live screen once
# hyprpicker exits.
set -euo pipefail

target="${1:-area}"
case "${target}" in
    active | area | output | screen) ;;
    *)
        printf 'usage: %s [active|area|output|screen]\n' "$0" >&2
        exit 2
        ;;
esac

directory="${HOME:?}/Pictures/Screenshots"
mkdir -p "${directory}"

timestamp="$(date +'%Y-%m-%d_%H-%M-%S_%N')"
path="${directory}/Screenshot_${timestamp}.png"

notify() {
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a "APEX Shell" -i "${2:-camera-photo}" "$1" "${3:-}" || true
}

# ── Hyprland: grimblast, frozen ──────────────────────────────────────────────
if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v grimblast >/dev/null 2>&1; then
    # The still and slurp's selection are layer surfaces, and Hyprland would
    # fade both (apex_screenshot_layers_command says why, and what it costs).
    # Sourced here rather than at the top so a copy of this script that has no
    # adapter beside it still captures, frozen, on every compositor; it loses
    # only the exemption, which is cosmetic. SC1091 is off because CI lints
    # this file without -x, which cannot follow the source; -x still does.
    # shellcheck source=src/scripts/compositor.sh disable=SC1091
    if [[ "${target}" == area ]] \
        && . "$(dirname -- "${BASH_SOURCE[0]}")/compositor.sh" 2>/dev/null \
        && apex_screenshot_layers_command hyprland; then
        "${APEX_CMD[@]}" >/dev/null 2>&1 || true
    fi
    # Keep the clipboard behavior while making the on-disk capture authoritative.
    # --freeze applies to `area` only; grimblast ignores it for the targets that
    # capture at once.
    grimblast -n --freeze copysave "${target}" "${path}"
    exit 0
fi

# ── Everything else: grim (+ slurp for a region) ─────────────────────────────
command -v grim >/dev/null 2>&1 || {
    notify "Screenshot failed" "dialog-error" "grim is not installed"
    printf 'screenshot: grim is required off Hyprland\n' >&2
    exit 1
}

# The freeze is released by pid, never `pkill hyprpicker` (grimblast's way):
# that also ends a colour pick the user has open. The trap covers every exit —
# a cancelled selection, a failed grim under `set -e` — because a still left up
# is a screen that looks hung.
freeze_pid=""
unfreeze() {
    if [[ -n "${freeze_pid}" ]]; then
        kill "${freeze_pid}" 2>/dev/null || true
        freeze_pid=""
    fi
    return 0
}
trap unfreeze EXIT

geometry=""
case "${target}" in
    area)
        command -v slurp >/dev/null 2>&1 || {
            notify "Screenshot failed" "dialog-error" "slurp is not installed"
            printf 'screenshot: slurp is required for area capture\n' >&2
            exit 1
        }
        # Without hyprpicker the selection runs over the live screen, as before.
        # The 0.2 s is grimblast's: the layer maps before its still is drawn
        # (measured: live content at 30 ms, the still by 80 ms).
        if command -v hyprpicker >/dev/null 2>&1; then
            hyprpicker -rz >/dev/null 2>&1 &
            freeze_pid=$!
            sleep 0.2
        fi
        # A cancelled selection (Escape) is a normal outcome, not an error:
        # exit quietly rather than notifying a failure the user just chose.
        geometry="$(slurp 2>/dev/null)" || exit 0
        [[ -n "${geometry}" ]] || exit 0
        ;;
    active)
        # There is no compositor-agnostic way to ask for the focused window's
        # geometry: labwc publishes no IPC at all, and wlr-foreign-toplevel
        # reports titles but not positions. Rather than pretend, fall through to
        # the whole output and say so, so the result is never silently the wrong
        # thing.
        notify "Captured the whole screen" "camera-photo" \
               "Active-window capture needs Hyprland; use area capture instead."
        ;;
esac

if [[ -n "${geometry}" ]]; then
    grim -g "${geometry}" "${path}"
else
    grim "${path}"
fi
unfreeze

# grimblast's `copysave` puts the image on the clipboard too; match that.
#
# wl-copy must own the selection until something else claims it, so it stays
# resident. Detached deliberately: invoked from a keybind, a foreground wl-copy
# never returns, and the compositor is left with a hung child for every
# screenshot taken.
if command -v wl-copy >/dev/null 2>&1; then
    setsid wl-copy --type image/png < "${path}" >/dev/null 2>&1 &
fi

notify "Screenshot saved" "camera-photo" "${path##*/}"
