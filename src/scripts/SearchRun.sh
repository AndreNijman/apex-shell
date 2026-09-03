#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  SearchRun.sh — every privileged or terminal-hosted action the unified search
#  surface (roadmap §15) can take, behind a closed set of verbs.
#
#  WHY THIS FILE EXISTS AT ALL
#
#  src/services/search.js owns the ACTIONS table: which actions exist, what
#  class each one is, what privilege it needs, and the argv that runs it. That
#  table is already a closed set, and the launcher already refuses to run a
#  non-safe action without a deliberate second gesture.
#
#  This is the SECOND lock on the same door, and it is a different kind of lock.
#  The table lives in a file the QML engine loads; this is a program that
#  receives an argv and decides for itself whether it will act on it. So a bug
#  in the shell — a row that carried an argument it should not have, a table
#  edited without thinking — meets a verb allowlist and an argument charset
#  before anything runs. Nothing here ever composes a command out of what it was
#  given; every command is written out in full, with the argument in a
#  positional slot.
#
#  WHY A TERMINAL FOR THE PACKAGE VERBS
#
#  The house rule, already followed by /usr/libexec/apex-agent-review: a
#  privileged operation belongs "somewhere sudo can authenticate and where the
#  full prompt, the reason and the resulting output are all visible". A package
#  transaction has output worth reading and a failure worth seeing. Swallowing
#  it into a subprocess with no window would hide exactly the part the user was
#  shown a preview of.
#
#  `unit-restart` is the exception and it is deliberate: one named unit, no
#  output worth reading, and pkexec's own dialog names the program and asks for
#  a password, which is a clear permission surface in its own right.
#
#  Every verb below exits non-zero on a refusal, and says why on stderr.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

APEX="${APEX_BIN:-$(command -v apex || echo /usr/bin/apex)}"

die() { printf 'apex-search: %s\n' "$1" >&2; exit 2; }

usage() {
    cat >&2 <<'EOF'
usage: SearchRun.sh <verb> [argument]

  unit-restart <unit>   restart one allow-listed system unit, via pkexec
  audio-restart         restart PipeWire for this user; no root
  install <package>     open a terminal on `sudo apex install <package>`
  remove <package>      open a terminal on `sudo apex remove <package>`
  os-update             open a terminal on `sudo apex update`
  os-rollback           open a terminal on `sudo apex rollback`
  ssh <device>          open a terminal connected to a trusted device
EOF
    exit 2
}

# ── The unit allowlist ───────────────────────────────────────────────────────
# Named units, not a charset. "restart any unit whose name looks sensible" is
# not a smaller capability than "run anything as root" — systemd units run
# arbitrary ExecStart lines, and a user-writable unit file under
# ~/.config/systemd would make this an escalation. Two units, both system
# services APEX ships and neither of them user-writable.
unit_allowed() {
    case "$1" in
        bluetooth|NetworkManager) return 0 ;;
        *) return 1 ;;
    esac
}

# ── The argument charset ─────────────────────────────────────────────────────
# A package name is a Fedora package name, a Flatpak application id, or a path
# to a local .rpm — but this script never accepts the path form: a launcher row
# offering to install a file the user did not name is not a feature. So: letters,
# digits, and the four punctuation characters real package names use, and it may
# not begin with "-" (which would be read as a flag by anything downstream).
valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

# An ssh destination is an alias from ~/.ssh/config or a user@host. No spaces,
# no shell metacharacters, and never a "-" first for the same reason.
valid_dest() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]]
}

# ── Opening a terminal ───────────────────────────────────────────────────────
# Candidates in preference order, each with its own exec flag, because getting
# the flag wrong opens an empty terminal and that looks like the action did
# nothing. Same list and same reasoning as /usr/libexec/apex-agent-review.
#
# The command is passed to the terminal as ONE argument, and it is built here
# from constants plus a single already-validated word. It is never built from
# anything this script received unchecked.
open_terminal() {
    local script="$1"
    local entry name flag
    for entry in "${TERMINAL:-}:-e" alacritty:-e ghostty:-e foot:-e kitty:-e \
                 wezterm:start xterm:-e; do
        name="${entry%%:*}"
        flag="${entry##*:}"
        [ -n "$name" ] || continue
        command -v "$name" >/dev/null 2>&1 || continue
        exec "$name" "$flag" bash -c "$script"
    done
    printf 'apex-search: no terminal emulator found\n' >&2
    printf 'apex-search: run it yourself:\n  %s\n' "$script" >&2
    exit 3
}

# The tail every terminal-hosted verb ends with, so the window stays on the
# result instead of vanishing before it can be read.
HOLD='printf "\n[press enter to close]"; read -r _'

[ "$#" -ge 1 ] || usage
verb="$1"
shift

case "$verb" in
    unit-restart)
        [ "$#" -eq 1 ] || usage
        unit_allowed "$1" || die "'$1' is not a unit this shell may restart"
        # pkexec, not sudo: this one has no output worth watching, and the
        # polkit dialog is itself the permission surface the user is shown.
        exec pkexec systemctl restart "$1"
        ;;

    audio-restart)
        [ "$#" -eq 0 ] || usage
        # Per-user units. No root, no polkit, nothing to authenticate — which is
        # exactly what the preview told the user.
        exec systemctl --user restart pipewire pipewire-pulse wireplumber
        ;;

    install)
        [ "$#" -eq 1 ] || usage
        valid_name "$1" || die "'$1' is not a package name"
        [ -x "$APEX" ] || die "apex is not installed"
        open_terminal "$(printf '%s resolve %s; printf "\\n"; sudo %s install %s; %s' \
            "$APEX" "$1" "$APEX" "$1" "$HOLD")"
        ;;

    remove)
        [ "$#" -eq 1 ] || usage
        valid_name "$1" || die "'$1' is not a package name"
        [ -x "$APEX" ] || die "apex is not installed"
        open_terminal "$(printf 'sudo %s remove %s; %s' "$APEX" "$1" "$HOLD")"
        ;;

    os-update)
        [ "$#" -eq 0 ] || usage
        [ -x "$APEX" ] || die "apex is not installed"
        open_terminal "$(printf 'sudo %s update; %s' "$APEX" "$HOLD")"
        ;;

    os-rollback)
        [ "$#" -eq 0 ] || usage
        [ -x "$APEX" ] || die "apex is not installed"
        open_terminal "$(printf 'sudo %s rollback; %s' "$APEX" "$HOLD")"
        ;;

    ssh)
        [ "$#" -eq 1 ] || usage
        valid_dest "$1" || die "'$1' is not an ssh destination"
        # `apex host run -t` when the trusted-device registry knows this name,
        # plain ssh otherwise. Either way the connection is made HERE, by a
        # terminal the user opened — never while they were typing. §15 is
        # explicit that an SSH-host provider lists hosts and does not reach them.
        if [ -x "$APEX" ] && "$APEX" host list --json >/dev/null 2>&1; then
            open_terminal "$(printf '%s host run -t %s' "$APEX" "$1")"
        else
            open_terminal "$(printf 'ssh %s' "$1")"
        fi
        ;;

    *)
        usage
        ;;
esac
