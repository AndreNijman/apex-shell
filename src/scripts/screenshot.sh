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
# So: use grimblast where it works (preserving the exact previous behaviour on
# Hyprland, including its clipboard handling and its notification), and fall back
# to plain grim/slurp everywhere else. grim and slurp are compositor-agnostic —
# they use wlr-screencopy and layer-shell, which labwc and niri both implement.
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

# ── Hyprland: unchanged path ─────────────────────────────────────────────────
if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v grimblast >/dev/null 2>&1; then
    # Keep the clipboard behavior while making the on-disk capture authoritative.
    grimblast -n copysave "${target}" "${path}"
    exit 0
fi

# ── Everything else: grim (+ slurp for a region) ─────────────────────────────
command -v grim >/dev/null 2>&1 || {
    notify "Screenshot failed" "dialog-error" "grim is not installed"
    printf 'screenshot: grim is required off Hyprland\n' >&2
    exit 1
}

geometry=""
case "${target}" in
    area)
        command -v slurp >/dev/null 2>&1 || {
            notify "Screenshot failed" "dialog-error" "slurp is not installed"
            printf 'screenshot: slurp is required for area capture\n' >&2
            exit 1
        }
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
