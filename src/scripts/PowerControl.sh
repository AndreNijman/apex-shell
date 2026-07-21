#!/bin/bash
# PowerControl.sh — power-menu actions for Void Linux (runit + elogind).
# Void has NO systemd and `hyprshutdown` isn't installed, so the upstream
# `hyprshutdown --post-cmd "systemctl …"` calls are replaced with elogind/Hyprland
# equivalents. loginctl power actions are allowed for the active local session by
# elogind's default polkit policy, so no root/password is needed.

HYPRLOCK_CONF="${HYPRLOCK_CONF:-$HOME/.local/src/apex-shell/src/config/hyprlock.conf}"

case "$1" in
    shutdown) exec loginctl poweroff ;;
    reboot)   exec loginctl reboot ;;
    logout)
        # niri: `niri msg action quit --skip-confirmation`; Hyprland: dispatch exit.
        if [ -n "$NIRI_SOCKET" ]; then exec niri msg action quit --skip-confirmation
        else exec hyprctl dispatch exit; fi ;;             # quit compositor → back to GDM
    suspend)  exec loginctl suspend ;;
    # One-shot reboot into Windows. The root-owned helper arms the EFI BootNext
    # variable (Windows Boot Manager, resolved dynamically) and reboots; BootNext
    # is consumed after one boot, so the machine returns to Void next time. Runs
    # via the dedicated NOPASSWD sudoers rule, so no password prompt is needed.
    windows)  exec sudo -n /usr/local/bin/caelestia-boot-windows ;;
    # Native Quickshell lock screen (windows/Lockscreen.qml via the "lockscreen"
    # IPC target). Unlock is PAM-only — there is no unlock IPC.
    lock)     exec qs ipc -c "$HOME/.local/src/apex-shell" call lockscreen lock ;;
    # Fallback: external hyprlock (kept for reference / emergencies)
    # lock)     pidof hyprlock >/dev/null 2>&1 || exec setsid -f hyprlock -c "$HYPRLOCK_CONF" ;;
    *)        echo "usage: PowerControl.sh {shutdown|reboot|logout|suspend|lock|windows}" >&2; exit 1 ;;
esac
