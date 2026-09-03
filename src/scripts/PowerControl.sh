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

# The compositor adapter for scripts: detection, per-compositor commands, and
# apex_run — the ONE place this file is allowed to replace its own process.
# tests/check-compositor-backends.sh asserts that, and uses it to drive every
# verb below for every compositor without any of them running.
# shellcheck source=src/scripts/compositor.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/compositor.sh"

# power <verb>  — verb is poweroff|reboot|suspend (same name in systemctl/loginctl)
power() {
    if command -v systemctl >/dev/null 2>&1; then
        apex_run systemctl "$1"
    else
        apex_run loginctl "$1"
    fi
}

case "$1" in
    shutdown) power poweroff ;;
    reboot)   power reboot ;;
    # ── Log out ──────────────────────────────────────────────────────────────
    # This used to be `niri msg action quit` or else `hyprctl dispatch exit`.
    # labwc ships no hyprctl, so on the APEX Floating session the Log Out button
    # ran a command that does not exist and the session simply stayed put — an
    # Openbox-fallback experience on the desktop §24 promises behaves like a
    # mature one.
    #
    # Preference order, most correct first:
    #
    #   1. /usr/libexec/apex-session-logout, when APEX-OS ships it. Same job,
    #      already written, already tested there; calling it keeps the two repos
    #      from drifting into two different answers.
    #   2. `loginctl terminate-session $XDG_SESSION_ID` — compositor-neutral and
    #      the RIGHT answer wherever the session is registered with logind,
    #      because it tears the session down properly so user units stop and the
    #      greeter comes back. Killing the compositor leaves that to chance.
    #      Terminating your own session is allow_active in the shipped
    #      org.freedesktop.login1.manage policy, so it does not prompt.
    #      Guarded on XDG_SESSION_ID: `terminate-session` with no id is not a
    #      portable "this one".
    #   3. The compositor's own exit verb, from the adapter. This is what runs on
    #      a machine with no logind session at all, and it is the branch the
    #      coverage check requires all three compositors to have.
    logout)
        helper="${APEX_SESSION_LOGOUT:-/usr/libexec/apex-session-logout}"
        if [ -x "$helper" ]; then apex_run "$helper"; exit $?; fi
        if command -v loginctl >/dev/null 2>&1 && [ -n "${XDG_SESSION_ID:-}" ]; then
            apex_run loginctl terminate-session "${XDG_SESSION_ID}"; exit $?
        fi
        if ! name="$(apex_compositor)"; then
            echo "logout: no known compositor (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset})" >&2
            exit 1
        fi
        apex_logout_command "$name"
        apex_run "${APEX_CMD[@]}" ;;                        # quit compositor → back to greeter
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
    #
    # The desktop being left is written down first (user state, no privilege) so
    # `desktopmode` can bring the SAME desktop back. Best-effort: if it cannot be
    # recorded, Gaming Mode still works and the way back falls through to what is
    # installed.
    gamingmode)
        helper="${APEX_SESSION_HELPER:-/usr/libexec/apex-session-select}"
        if [ ! -x "$helper" ]; then
            echo "gaming mode: no session helper at $helper" >&2; exit 1
        fi
        apex_remember_desktop_session
        apex_run sudo -n "$helper" apex-gaming --switch ;;
    # Leave Gaming Mode: same mechanism, pointed back at the desktop session.
    #
    # This used to pass a literal `hyprland`, so a labwc or niri user who entered
    # Gaming Mode came back into Hyprland — a session they never chose, with a
    # different shell layout and different keybinds. The id now comes from the
    # adapter: what was remembered on the way in, else the compositor running
    # now, else the first desktop session this image actually installs. Note it
    # is a SESSION id and not a compositor name — APEX ships labwc as
    # `apex-labwc`, and apex-session-select validates against what is installed.
    desktopmode)
        helper="${APEX_SESSION_HELPER:-/usr/libexec/apex-session-select}"
        if [ ! -x "$helper" ]; then
            echo "desktop mode: no session helper at $helper" >&2; exit 1
        fi
        if ! session="$(apex_desktop_session_id)"; then
            echo "desktop mode: no desktop session installed in ${APEX_SESSION_DIR}" >&2
            exit 1
        fi
        apex_run sudo -n "$helper" "$session" --switch ;;
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
        [ "$1" = "windows-check" ] && apex_run sudo -n "$HELPER" --check
        apex_run sudo -n "$HELPER" ;;
    # Native Quickshell lock screen (windows/Lockscreen.qml via the "lockscreen"
    # IPC target). Unlock is PAM-only — there is no unlock IPC.
    lock)     apex_run qs ipc -c "$SHELL_DIR" call lockscreen lock ;;
    # Fallback: external hyprlock (kept for reference / emergencies)
    # lock)     pidof hyprlock >/dev/null 2>&1 || apex_run setsid -f hyprlock -c "$HYPRLOCK_CONF" ;;
    *)        echo "usage: PowerControl.sh {shutdown|reboot|logout|suspend|lock|gamingmode|desktopmode|windows|windows-check}" >&2; exit 1 ;;
esac
