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

# Resolve the shell checkout from this script's own location (src/scripts/ →
# repo root) rather than assuming ~/.local/src/apex-shell, which is only the
# default install path. Keeps `lock` working for system-wide and relocated
# installs.
SHELL_DIR="${APEX_SHELL_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"

HYPRLOCK_CONF="${HYPRLOCK_CONF:-$SHELL_DIR/src/config/hyprlock.conf}"

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
    # ── Enter Gaming Mode ────────────────────────────────────────────────────
    # Record the session the greeter should preselect, then end this session so
    # the greeter comes back with "APEX Gaming Mode" already chosen. One password
    # entry and gamescope + Steam Big Picture takes the display, with no desktop
    # compositor in the path.
    #
    # The write has to be privileged: the greeter's memory lives in
    # /var/lib/apex-greet, which is owned by the `greetd` user. The helper is
    # reached through a dedicated NOPASSWD sudoers rule and validates the session
    # id against the .desktop files actually installed, so nothing here hands it
    # a path. APEX_SESSION_HELPER is the override for packagers.
    #
    # Fails LOUDLY rather than logging you out into nothing: if the helper is
    # missing or refuses, the session is left exactly as it was. The shell only
    # offers this row when both the helper and the session file exist, so this is
    # the belt to that braces.
    gamingmode)
        helper="${APEX_SESSION_HELPER:-/usr/libexec/apex-session-select}"
        if [ ! -x "$helper" ]; then
            echo "gaming mode: no session helper at $helper" >&2; exit 1
        fi
        exec sudo -n "$helper" apex-gaming --switch ;;
    # Leave Gaming Mode: same mechanism, pointed back at the desktop session.
    desktopmode)
        helper="${APEX_SESSION_HELPER:-/usr/libexec/apex-session-select}"
        if [ ! -x "$helper" ]; then
            echo "desktop mode: no session helper at $helper" >&2; exit 1
        fi
        exec sudo -n "$helper" hyprland --switch ;;
    # One-shot reboot into Windows. The root-owned helper arms the EFI BootNext
    # variable (Windows Boot Manager, resolved and VERIFIED dynamically) and
    # reboots; BootNext is consumed after one boot, so the machine returns to the
    # default next time. Runs via a NOPASSWD sudoers rule, so no password prompt is
    # needed — a compositor-spawned script could not answer one.
    #
    # This used to hardcode a helper under /usr/local/bin, named after the project
    # this was forked from. Nothing in this repo has ever installed a helper there —
    # not install.sh, not dots-extra — so the button was dead for every user of this
    # shell, on every distro. On APEX-OS it could never work even in principle:
    # /usr is read-only there and /usr/local is redirected to per-machine state, so
    # no image can deliver a file to that path. APEX_WINDOWS_HELPER is the supported
    # override for packagers who put the helper somewhere else.
    #
    # The old name is deliberately not written out here: apex-os greps a vendored
    # copy of this file to prove the dead path is gone, and a mention in a comment
    # would either fail that check or be rewritten by its migration sed, turning
    # this explanation into a false statement.
    windows|windows-check)
        HELPER="${APEX_WINDOWS_HELPER:-/usr/libexec/apex-boot-windows}"
        if [ ! -x "$HELPER" ]; then
            # windows-check is a capability probe: stay quiet and just report "no",
            # so a shell on a distro without the helper simply hides the button.
            [ "$1" = "windows-check" ] && exit 1
            echo "PowerControl.sh: no Windows boot helper at $HELPER (set APEX_WINDOWS_HELPER to override)." >&2
            exit 1
        fi
        [ "$1" = "windows-check" ] && exec sudo -n "$HELPER" --check
        exec sudo -n "$HELPER" ;;
    # Native Quickshell lock screen (windows/Lockscreen.qml via the "lockscreen"
    # IPC target). Unlock is PAM-only — there is no unlock IPC.
    lock)     exec qs ipc -c "$SHELL_DIR" call lockscreen lock ;;
    # Fallback: external hyprlock (kept for reference / emergencies)
    # lock)     pidof hyprlock >/dev/null 2>&1 || exec setsid -f hyprlock -c "$HYPRLOCK_CONF" ;;
    *)        echo "usage: PowerControl.sh {shutdown|reboot|logout|suspend|lock|windows|windows-check}" >&2; exit 1 ;;
esac
