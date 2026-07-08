#!/bin/bash
# DpmsControl.sh — compositor-neutral display power control for hypridle.
#
# hypridle itself runs fine on both Hyprland and niri, but the DPMS command
# differs: Hyprland uses `hyprctl dispatch dpms`, niri uses
# `niri msg action power-{off,on}-monitors`. This wrapper picks the right one
# from the environment so a single hypridle.conf works under either compositor.
#
# usage: DpmsControl.sh {on|off}

case "$1" in
    on|off) ;;
    *) echo "usage: DpmsControl.sh {on|off}" >&2; exit 1 ;;
esac

if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
    exec hyprctl dispatch dpms "$1"
elif [ -n "$NIRI_SOCKET" ]; then
    if [ "$1" = "off" ]; then
        exec niri msg action power-off-monitors
    else
        exec niri msg action power-on-monitors
    fi
fi

# Neither compositor detected — nothing to do.
exit 0
