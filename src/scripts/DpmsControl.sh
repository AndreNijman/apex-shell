#!/bin/bash
# DpmsControl.sh — compositor-neutral display power control for hypridle.
#
# hypridle itself runs fine on Hyprland, niri and labwc — it only needs
# ext-idle-notify-v1, which all three implement — but the command that actually
# turns the display off differs per compositor, so this wrapper resolves it from
# the adapter and one hypridle.conf works under all of them.
#
# This used to end with a bare `exit 0` when it recognised neither Hyprland nor
# niri, which is what labwc got: the 6-minute screen-off listener fired, this
# script exited successfully, and the display stayed on all night. A silent
# success is the worst possible answer here, so an unknown compositor now says
# so on stderr and exits non-zero.
#
# usage: DpmsControl.sh {on|off}

# shellcheck source=src/scripts/compositor.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/compositor.sh"

case "$1" in
    on|off) ;;
    *) echo "usage: DpmsControl.sh {on|off}" >&2; exit 1 ;;
esac

if ! name="$(apex_compositor)"; then
    echo "DpmsControl.sh: no known compositor (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset})" >&2
    exit 1
fi

if ! apex_dpms_command "$name" "$1"; then
    echo "DpmsControl.sh: no display-power command for $name" >&2
    exit 1
fi

# apex_run reports a missing program itself and returns 127 — labwc's answer is
# wlopm, which is a separate package rather than part of the compositor, so that
# is a real outcome here and not a theoretical one.
apex_run "${APEX_CMD[@]}"
