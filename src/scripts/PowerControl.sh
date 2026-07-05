#!/bin/bash
# PowerControl.sh — power-menu actions for Void Linux (runit + elogind).
# Void has NO systemd and `hyprshutdown` isn't installed, so the upstream
# `hyprshutdown --post-cmd "systemctl …"` calls are replaced with elogind/Hyprland
# equivalents. loginctl power actions are allowed for the active local session by
# elogind's default polkit policy, so no root/password is needed.

HYPRLOCK_CONF="${HYPRLOCK_CONF:-$HOME/.local/src/Brain_Shell/src/config/hyprlock.conf}"

case "$1" in
    shutdown) exec loginctl poweroff ;;
    reboot)   exec loginctl reboot ;;
    logout)   exec hyprctl dispatch exit ;;          # quit Hyprland → back to GDM
    suspend)  exec loginctl suspend ;;
    lock)     pidof hyprlock >/dev/null 2>&1 || exec setsid -f hyprlock -c "$HYPRLOCK_CONF" ;;
    *)        echo "usage: PowerControl.sh {shutdown|reboot|logout|suspend|lock}" >&2; exit 1 ;;
esac
