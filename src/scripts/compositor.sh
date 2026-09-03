# shellcheck shell=bash
# shellcheck disable=SC2034  # APEX_CMD is read by the scripts that source this.
# compositor.sh — the compositor adapter for APEX Shell's helper SCRIPTS.
#
# SOURCED, never executed. There is no shebang and no top-level action here on
# purpose: `bash compositor.sh` must do nothing.
#
# ── Why this file exists ─────────────────────────────────────────────────────
# src/services/compositor/ is §17's adapter layer for QML: one facade, one
# backend per compositor, and a capability map so a consumer never asks "am I on
# Hyprland". The helper scripts could not use it — they are spawned by hypridle
# and by the power menu, outside the QML engine — so each of them grew its own
# private answer to "which compositor am I on", and each of those answers was
# incomplete in a different way:
#
#   PowerControl.sh logout      niri, else `hyprctl dispatch exit`. labwc has no
#                               hyprctl, so the Log Out button did nothing at all.
#   PowerControl.sh desktopmode hardcoded the `hyprland` session id, so leaving
#                               Gaming Mode dropped a labwc or niri user into
#                               Hyprland.
#   DpmsControl.sh              Hyprland, niri, then `exit 0`. Idle screen-off
#                               was a silent no-op on labwc.
#
# This is the one place that answers the question for scripts, in the same
# detection order as src/state/Compositor.qml, and the one place that turns an
# answer into a command. A fourth compositor is a case label here and nothing
# anywhere else.
#
# ── The single exec point ────────────────────────────────────────────────────
# Every compositor-dependent action in these scripts runs through apex_run().
# That is what makes the coverage assertion in tests/check-compositor-backends.sh
# possible AND safe: the check can drive the real entry points of the real
# scripts for every compositor and see the command each one resolves, without
# any of them being able to run. The check also asserts that no `exec` survives
# outside apex_run, so "safe to dry-run" is enforced rather than promised.

# apex_run <argv...> — run the resolved command, replacing this process.
#
# With APEX_COMPOSITOR_DRY_RUN set, print the argv and return instead. Nothing
# in a session sets that variable; tests/check-compositor-backends.sh does.
#
# A missing program is reported here rather than left to `exec`, because some of
# these commands live in packages the compositor does not pull in (wlopm is the
# one that matters) and "wlopm: not found" from a hypridle listener at 3am is a
# message nobody will ever read as "your image is missing a package".
apex_run() {
    if [ -n "${APEX_COMPOSITOR_DRY_RUN:-}" ]; then
        printf '%s\n' "$*"
        return 0
    fi
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '%s: %s is not installed; cannot run: %s\n' "${0##*/}" "$1" "$*" >&2
        return 127
    fi
    exec "$@"
}

# apex_compositor — print hyprland | niri | labwc, or return 1 for anything else.
#
# Same order and the same signals as src/state/Compositor.qml, deliberately:
# two detectors that disagree are worse than one that is wrong. The instance
# variables come first because they prove a live compositor, and
# XDG_CURRENT_DESKTOP is consulted after because it is the ONLY signal labwc
# publishes — labwc exposes no IPC socket at all by design, so there is no
# LABWC_SOCKET to test for.
#
# Returning 1 rather than guessing is the point: on sway, river or KDE this
# refuses to answer, so a caller reports "no known compositor" instead of
# spawning hyprctl into the void.
#
# APEX_COMPOSITOR overrides detection. It is what the check drives, and it is
# also the escape hatch for a packager whose session sets neither signal. The
# QML override (the "compositor" key in config_Provider.json) is NOT read here:
# these scripts run before, after and independently of the shell process, and
# parsing that file in three scripts would be the fourth answer this file exists
# to delete.
apex_compositor() {
    local name="${APEX_COMPOSITOR:-}"
    local desktop

    if [ -z "$name" ]; then
        desktop="$(printf '%s' "${XDG_CURRENT_DESKTOP:-}" | tr '[:upper:]' '[:lower:]')"
        if   [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then name=hyprland
        elif [ -n "${NIRI_SOCKET:-}" ];                then name=niri
        else
            case "$desktop" in
                *hyprland*) name=hyprland ;;
                *niri*)     name=niri ;;
                *labwc*)    name=labwc ;;
            esac
        fi
    fi

    case "$name" in
        hyprland|niri|labwc) printf '%s\n' "$name" ;;
        *) return 1 ;;
    esac
}

# ── Resolved commands ────────────────────────────────────────────────────────
# Each of these fills the array APEX_CMD and returns 0, or returns 1 without
# touching anything the caller can run. An array and not a string: `wlopm --off
# '*'` has to reach execve with a literal asterisk, and a string command would
# be glob-expanded against the working directory on the way there.

# apex_logout_command <compositor> — end the graphical session, compositor-side.
#
# This is the FALLBACK, not the first choice. PowerControl.sh prefers
# `loginctl terminate-session`, which tears the session down through logind so
# user units stop and the greeter comes back; killing the compositor leaves that
# to chance. But the neutral path needs a registered logind session, and off
# systemd/elogind there is none — so every compositor still needs its own answer
# here, and the coverage check enforces that all three have one.
#
# labwc: `labwc --exit` sends SIGTERM to $LABWC_PID (labwc(1), OPTIONS). labwc
# ships no IPC socket, so this — not a hyprctl-shaped IPC call — is the exit verb.
apex_logout_command() {
    APEX_CMD=()
    case "${1:-}" in
        hyprland) APEX_CMD=(hyprctl dispatch exit) ;;
        niri)     APEX_CMD=(niri msg action quit --skip-confirmation) ;;
        labwc)    APEX_CMD=(labwc --exit) ;;
        *)        return 1 ;;
    esac
}

# apex_dpms_command <compositor> <on|off> — display power, for hypridle.
#
# There is no compositor-neutral answer worth having here. The neutral-looking
# candidate is `wlr-randr --output <name> --off`, which goes through
# wlr-output-management and DISABLES the output: layer-shell surfaces on it are
# destroyed and windows are re-laid-out onto whatever is left, every time the
# machine idles. That is worse than the no-op it would replace.
#
# labwc: wlopm(1), which implements zwlr-output-power-management-v1 — the
# protocol that blanks an output without reconfiguring it. Verified present in
# the labwc binary: `strings /usr/bin/labwc | grep -x zwlr_output_power_manager_v1`.
# `*` is wlopm's documented "every discovered output" argument.
#
# niri implements no such protocol (the same grep over /usr/bin/niri finds
# nothing) and answers on its own IPC instead, which is why this is a per-
# compositor table and not one clever command.
apex_dpms_command() {
    APEX_CMD=()
    case "${1:-}:${2:-}" in
        hyprland:on|hyprland:off) APEX_CMD=(hyprctl dispatch dpms "$2") ;;
        niri:on)                  APEX_CMD=(niri msg action power-on-monitors) ;;
        niri:off)                 APEX_CMD=(niri msg action power-off-monitors) ;;
        labwc:on)                 APEX_CMD=(wlopm --on '*') ;;
        labwc:off)                APEX_CMD=(wlopm --off '*') ;;
        *)                        return 1 ;;
    esac
}

# ── Session ids ──────────────────────────────────────────────────────────────
# Entering and leaving Gaming Mode is "tell the greeter which session to
# preselect, then end this one". The session id is a filename in
# /usr/share/wayland-sessions, and it is NOT the compositor's name: APEX ships
# labwc as apex-labwc.desktop, because the stock labwc.desktop is deleted (it
# launches labwc bare, with no APEX Shell and no config, and labwc is also the
# greeter's own fallback host compositor).
APEX_SESSION_DIR="${APEX_SESSION_DIR:-/usr/share/wayland-sessions}"

# Where "the desktop I left when I entered Gaming Mode" is remembered. The
# greeter's own /var/lib/apex-greet/last-session cannot answer that question: it
# is rewritten on every successful login, so by the time Gaming Mode is running
# it says "apex-gaming". This is the user's own state, needs no privilege, and
# its absence is handled.
APEX_DESKTOP_SESSION_STATE="${APEX_DESKTOP_SESSION_STATE:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/apex-shell/desktop-session}"

apex_session_installed() {
    [ -n "${1:-}" ] && [ -f "${APEX_SESSION_DIR}/$1.desktop" ]
}

# apex_session_ids_for <compositor> — candidate session ids, best first.
apex_session_ids_for() {
    case "${1:-}" in
        hyprland) printf '%s\n' hyprland ;;
        niri)     printf '%s\n' niri ;;
        labwc)    printf '%s\n' apex-labwc labwc ;;
        *)        return 1 ;;
    esac
}

# apex_desktop_session_id — which session "leave Gaming Mode" should return to.
#
# 1. What was remembered on the way in. Exact, and the only source that can tell
#    a labwc user apart from a Hyprland one once gamescope owns the display.
# 2. The compositor running right now, if there is one. Covers calling this from
#    a desktop session.
# 3. The first desktop session actually installed, in APEX's own order of
#    preference. Hyprland is the primary desktop, so it leads — but an image
#    that does not ship it lands on niri or labwc instead of on nothing, which
#    is the whole difference from the hardcoded `hyprland` this replaces.
apex_desktop_session_id() {
    local remembered="" id

    # `read` fills the variable even when the file has no trailing newline and
    # it therefore returns 1, so the failure is tolerated rather than used to
    # blank the answer.
    if [ -r "$APEX_DESKTOP_SESSION_STATE" ]; then
        IFS= read -r remembered < "$APEX_DESKTOP_SESSION_STATE" || :
    fi
    if apex_session_installed "$remembered"; then
        printf '%s\n' "$remembered"; return 0
    fi

    if id="$(apex_session_for_current_compositor)"; then
        printf '%s\n' "$id"; return 0
    fi

    for id in hyprland niri apex-labwc labwc; do
        if apex_session_installed "$id"; then printf '%s\n' "$id"; return 0; fi
    done
    return 1
}

# apex_session_for_current_compositor — the installed session id of whatever is
# running right now, or 1 if that cannot be answered.
apex_session_for_current_compositor() {
    local current id
    current="$(apex_compositor)" || return 1
    while IFS= read -r id; do
        if apex_session_installed "$id"; then printf '%s\n' "$id"; return 0; fi
    done < <(apex_session_ids_for "$current")
    return 1
}

# apex_remember_desktop_session — record the session we are leaving, so the trip
# back out of Gaming Mode returns here and not to whatever is listed first.
#
# Resolved from the RUNNING compositor, not from apex_desktop_session_id: that
# one prefers the remembered value, so a stale entry would keep rewriting itself
# and a user who moved from Hyprland to labwc would still be sent back to
# Hyprland forever.
#
# Best-effort. A machine that cannot write user state still gets Gaming Mode,
# and still gets a desktop back through the fallbacks above.
apex_remember_desktop_session() {
    local id
    id="$(apex_session_for_current_compositor)" || return 0
    mkdir -p "$(dirname "$APEX_DESKTOP_SESSION_STATE")" 2>/dev/null || return 0
    printf '%s\n' "$id" > "$APEX_DESKTOP_SESSION_STATE" 2>/dev/null || return 0
}
