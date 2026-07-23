#!/bin/bash
# PowerControl.sh — power-menu actions.
#
# APEX-OS (Fedora bootc) is systemd. systemd's `loginctl` has NO
# poweroff/reboot/suspend verbs (those are elogind-only), so the original
# `loginctl <verb>` calls silently failed there ("Unknown command verb"). Use
# `systemctl` when it is present (polkit lets the active local session run these
# without a password: CanPowerOff/CanReboot = yes), and fall back to `loginctl`
# on legacy elogind hosts (e.g. Void/runit) where systemctl is absent.
# See ~/Projects/apex-logs/30-power-actions-loginctl.md

HYPRLOCK_CONF="${HYPRLOCK_CONF:-$HOME/.local/src/apex-shell/src/config/hyprlock.conf}"

# power <verb>  — verb is poweroff|reboot|suspend (same name in systemctl/loginctl)
power() {
    if command -v systemctl >/dev/null 2>&1; then
        exec systemctl "$1"
    else
        exec loginctl "$1"
    fi
}

case "$1" in
    shutdown) power poweroff ;;
    reboot)   power reboot ;;
    logout)
        # niri: `niri msg action quit --skip-confirmation`; Hyprland: dispatch exit.
        if [ -n "$NIRI_SOCKET" ]; then exec niri msg action quit --skip-confirmation
        else exec hyprctl dispatch exit; fi ;;             # quit compositor → back to greeter
    suspend)  power suspend ;;
    # One-shot reboot into Windows. The root-owned helper arms the EFI BootNext
    # variable (Windows Boot Manager, resolved dynamically) and reboots; BootNext
    # is consumed after one boot, so the machine returns to the default next time.
    # Runs via the dedicated NOPASSWD sudoers rule, so no password prompt is needed.
    windows)  exec sudo -n /usr/local/bin/caelestia-boot-windows ;;
    # Native Quickshell lock screen (windows/Lockscreen.qml via the "lockscreen"
    # IPC target). Unlock is PAM-only — there is no unlock IPC.
    lock)     exec qs ipc -c "$HOME/.local/src/apex-shell" call lockscreen lock ;;
    # Fallback: external hyprlock (kept for reference / emergencies)
    # lock)     pidof hyprlock >/dev/null 2>&1 || exec setsid -f hyprlock -c "$HYPRLOCK_CONF" ;;
    *)        echo "usage: PowerControl.sh {shutdown|reboot|logout|suspend|lock|windows}" >&2; exit 1 ;;
esac
