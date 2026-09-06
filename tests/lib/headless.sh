# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/lib/headless.sh — the compositor a graphical test runs on.
#
#  Source it; do not execute it.
#
#  ── Why this file exists ────────────────────────────────────────────────────
#
#  Nine runners in here used to start quickshell on whatever WAYLAND_DISPLAY
#  they inherited. On a build box that is nothing; on the machine somebody is
#  working at it is a window, or twenty windows, landing on top of them. The
#  usual repair — "skip if the session looks like a desktop" — is advisory, and
#  a runner that CAN fall back to the ambient session eventually does.
#
#  So there is no fallback. Every runner that needs a compositor gets one of its
#  own: a wlroots compositor on the headless backend, in a runtime directory
#  this file created, and the run aborts if the socket it ends up talking to is
#  not inside that directory. tests/run-nav-geometry-test.sh established the
#  shape; this is that shape written once.
#
#  ── The private HOME is not tidiness ────────────────────────────────────────
#
#  A suite that drives SettingsService writes
#  $HOME/.config/apex-shell/src/user_data/settings.json, and a crash midway
#  leaves the developer's live shell at 200% scale. A suite that starts the whole
#  shell also finds $XDG_RUNTIME_DIR/apex-agentd/control.sock and starts talking
#  to the sessions a person has open. Both are prevented by the same private
#  directory rather than by remembering not to.
#
#  Fonts are the one thing borrowed back, read-only: fontconfig finds user fonts
#  through HOME, and a run that cannot see them measures .notdef boxes.
#
#  ── Usage ───────────────────────────────────────────────────────────────────
#
#      . "$(dirname "${BASH_SOURCE[0]}")/lib/headless.sh"
#
#      headless_require quickshell            # SKIP 0 if a tool is missing
#      headless_begin                         # private W, HOME, XDG_*, stubs
#      cleanup() { rm -f "$staged"; headless_cleanup; }
#      trap cleanup EXIT INT TERM
#      headless_start || exit 0               # SKIP 0 if no compositor
#      # WAYLAND_DISPLAY now names a socket under $HEADLESS_RUNTIME.
#
#  Exported for the caller: HEADLESS_W (scratch dir), HEADLESS_COMP (which
#  compositor came up), HEADLESS_RUNTIME, HEADLESS_MODE, and the usual XDG_*.
# ─────────────────────────────────────────────────────────────────────────────

# What the ambient session is, captured before anything is changed. Every later
# refusal compares against these, so a bug that leaks the desktop's socket into
# a "private" runtime dir is caught rather than used.
HEADLESS_AMBIENT_DISPLAY="${WAYLAND_DISPLAY:-}"
HEADLESS_AMBIENT_RUNTIME="${XDG_RUNTIME_DIR:-}"
HEADLESS_AMBIENT_SIG="${HYPRLAND_INSTANCE_SIGNATURE:-}"
HEADLESS_AMBIENT_HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
[ -n "$HEADLESS_AMBIENT_HOME" ] || HEADLESS_AMBIENT_HOME="$HOME"

HEADLESS_W=""
HEADLESS_COMP=""
HEADLESS_RUNTIME=""
HEADLESS_MODE="${HEADLESS_MODE:-1920x1080}"
HEADLESS_COMP_PID=""
HEADLESS_NESTED_PID=""

# ── skipping ─────────────────────────────────────────────────────────────────
# Status 0 with a SKIP line, so CI on a machine with no compositor and no
# quickshell reports "not run here" rather than failing the build.
headless_require() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "SKIP: $tool not installed"
            exit 0
        }
    done
}

# ── the sandbox ──────────────────────────────────────────────────────────────
headless_begin() {
    HEADLESS_W="$(mktemp -d)"

    # Stubs first on PATH. A real settings page asks the real machine —
    # `apex recover status`, hyprctl, wlr-randr, a wallpaper scan — and a suite
    # measuring rectangles has no business interrogating, or applying to, the
    # desktop somebody is using. The pages under test are the shipped files;
    # only the machine they interrogate is a stub.
    mkdir -p "$HEADLESS_W/bin"
    cat > "$HEADLESS_W/bin/_stub" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *--json*|*-j*|*json*) echo "{}" ;;
    *)                    : ;;
esac
exit 0
FAKE
    chmod +x "$HEADLESS_W/bin/_stub"
    local n
    for n in apex hyprctl wlr-randr niri matugen xdg-open playerctl wpctl \
             brightnessctl pkcheck notify-send swww systemctl loginctl; do
        ln -sf "$HEADLESS_W/bin/_stub" "$HEADLESS_W/bin/$n"
    done
    cat > "$HEADLESS_W/bin/git" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *describe*) echo "v0.0.0-test" ;;
    *)          : ;;
esac
exit 0
FAKE
    chmod +x "$HEADLESS_W/bin/git"
    export PATH="$HEADLESS_W/bin:$PATH"

    HEADLESS_RUNTIME="$HEADLESS_W/run"
    export XDG_RUNTIME_DIR="$HEADLESS_RUNTIME"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 0700 "$XDG_RUNTIME_DIR"

    export HOME="$HEADLESS_W/home"
    mkdir -p "$HOME/.config/apex-shell/src/user_data" \
             "$HOME/.local/share" "$HOME/Pictures/Wallpapers"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_STATE_HOME="$HEADLESS_W/state"
    export XDG_CACHE_HOME="$HEADLESS_W/cache"
    export XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

    ln -sfn "$HEADLESS_AMBIENT_HOME/.local/share/fonts" "$HOME/.local/share/fonts" 2>/dev/null
    ln -sfn "$HEADLESS_AMBIENT_HOME/.config/fontconfig" "$HOME/.config/fontconfig" 2>/dev/null

    # XDG_CURRENT_DESKTOP is how src/state/Compositor.qml decides which backend
    # to load, and inheriting the desktop's value is not a cosmetic mistake: a
    # client under a headless labwc that still reads "Hyprland" loads the
    # Hyprland adapter, asks the stub hyprctl for a window list, gets "{}" and
    # reports ten assertion failures about a compositor that is not running.
    # headless_start sets it to whatever actually came up.
    unset XDG_CURRENT_DESKTOP
    unset WAYLAND_DISPLAY
    unset DISPLAY
    unset HYPRLAND_INSTANCE_SIGNATURE
    unset NIRI_SOCKET
    unset SWAYSOCK

    export WLR_BACKENDS=headless
    export WLR_LIBINPUT_NO_DEVICES=1
    export WLR_HEADLESS_OUTPUTS=1
    export XDG_SESSION_TYPE=wayland
    export QT_QPA_PLATFORM=wayland
}

# Give a tool back its real binary. The stubs exist so a settings page cannot
# interrogate or reconfigure the live machine, but a suite whose whole point is
# to run `niri validate` needs the real niri. Named one at a time, so removing a
# stub is a decision in the runner rather than a hole in the sandbox.
headless_unstub() {
    local n
    for n in "$@"; do
        rm -f "$HEADLESS_W/bin/$n"
    done
}

# ── finding the socket ───────────────────────────────────────────────────────
# A nested compositor announces its display nowhere, so the runtime dir is
# diffed rather than a log scraped. Globbed and tested with -S, which drops the
# .lock file and the per-app sockets for free.
headless_sockets() {
    local f b
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [ -S "$f" ] || continue
        b="${f##*/}"
        case "${b#wayland-}" in '' | *[!0-9]*) continue ;; esac
        printf '%s\n' "$b"
    done | sort
}

headless_wait_socket() {
    local before="$1" got=""
    local _i
    for _i in $(seq 1 60); do
        got="$(comm -13 <(printf '%s\n' "$before") <(headless_sockets) | head -1)"
        [ -n "$got" ] && break
        sleep 0.25
    done
    printf '%s' "$got"
}

# ── the compositor ───────────────────────────────────────────────────────────
#   headless_start [labwc|sway] [WxH]
#
# Returns 1 after printing SKIP when nothing suitable is installed or the
# compositor does not come up; the caller exits 0 on that, because a machine
# without a wlroots compositor cannot run the suite and has not failed it.
headless_start() {
    local want="${1:-${HEADLESS_COMP_WANT:-}}"
    local mode="${2:-$HEADLESS_MODE}"
    HEADLESS_MODE="$mode"

    [ -n "$HEADLESS_W" ] || { echo "FAIL: headless_start before headless_begin"; return 2; }

    case "$mode" in
        *x*) : ;;
        *)   echo "FAIL: mode must be WxH, got '$mode'"; return 2 ;;
    esac

    if [ -n "$want" ]; then
        command -v "$want" >/dev/null 2>&1 || { echo "SKIP: $want is not installed"; return 1; }
        HEADLESS_COMP="$want"
    else
        local c
        for c in labwc sway; do
            command -v "$c" >/dev/null 2>&1 && { HEADLESS_COMP="$c"; break; }
        done
    fi
    [ -n "$HEADLESS_COMP" ] || {
        echo "SKIP: no wlroots compositor (labwc or sway) to host the test"
        return 1
    }

    local before
    before="$(headless_sockets)"

    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    case "$HEADLESS_COMP" in
        labwc)
            mkdir -p "$HEADLESS_W/cfg/labwc"
            cp "$here/labwc-test-rc.xml" "$HEADLESS_W/cfg/labwc/rc.xml" 2>/dev/null || true
            WLR_RENDERER=pixman XDG_CONFIG_HOME="$HEADLESS_W/cfg" \
                XDG_CURRENT_DESKTOP=labwc:wlroots \
                labwc > "$HEADLESS_W/comp.log" 2>&1 &
            HEADLESS_COMP_PID=$!
            ;;
        sway)
            printf 'output HEADLESS-1 mode %s\n' "$mode" > "$HEADLESS_W/sway.cfg"
            WLR_RENDERER=pixman XDG_CURRENT_DESKTOP=sway:wlroots \
                sway -c "$HEADLESS_W/sway.cfg" > "$HEADLESS_W/comp.log" 2>&1 &
            HEADLESS_COMP_PID=$!
            ;;
        *)
            echo "FAIL: headless_start does not know how to run $HEADLESS_COMP headless"
            return 2
            ;;
    esac

    local sock
    sock="$(headless_wait_socket "$before")"
    [ -n "$sock" ] || {
        echo "SKIP: $HEADLESS_COMP did not come up headless"
        tail -5 "$HEADLESS_W/comp.log" 2>/dev/null
        return 1
    }
    export WAYLAND_DISPLAY="$sock"
    case "$HEADLESS_COMP" in
        labwc) export XDG_CURRENT_DESKTOP=labwc:wlroots ;;
        sway)  export XDG_CURRENT_DESKTOP=sway:wlroots ;;
    esac

    headless_assert_private || return 2

    # labwc has no output stanza in rc.xml, so the mode is set over
    # wlr-output-management once it is up. sway takes it from its config.
    # The stub wlr-randr is shadowing the real one here, which is fine: the
    # default headless output is 1920x1080 and that is the default mode.
    if [ "$HEADLESS_COMP" = "labwc" ] && [ "$mode" != "1920x1080" ]; then
        local rr out
        rr="$(command -v wlr-randr)"
        case "$rr" in
            "$HEADLESS_W/bin/"*) rr="" ;;
        esac
        if [ -n "$rr" ]; then
            out="$("$rr" 2>/dev/null | awk 'NR==1{print $1}')"
            [ -n "$out" ] && "$rr" --output "$out" --custom-mode "$mode" >/dev/null 2>&1
        fi
    fi

    echo "host: $HEADLESS_COMP on $WAYLAND_DISPLAY at $mode (headless, private XDG_RUNTIME_DIR and HOME)"
    return 0
}

# ── the filler ───────────────────────────────────────────────────────────────
# A compositor with nothing running inside it is not a session, and the
# difference is not cosmetic: the app dock has nothing to list, the
# foreign-toplevel feed nothing to publish, and any assertion over the window
# list is an empty loop that passes without testing anything. The facade suite
# names the presence of a toplevel as an explicit precondition for that reason,
# so the harness has to provide one.
#
# quickshell rather than a terminal emulator: it is already a hard requirement
# of every harness in here, so this adds no dependency.
#
# Returns 1 if the filler died, and the caller must treat that as a failure
# rather than a skip — a filler that is not there turns every window assertion
# into a vacuous pass, which is worse than no test at all.
HEADLESS_FILLER_PID=""
headless_filler() {
    local qml="$HEADLESS_W/filler.qml"
    cat > "$qml" <<'FILLER'
import Quickshell
import QtQuick

ShellRoot {
    FloatingWindow {
        title:          "apex-headless-filler"
        visible:        true
        implicitWidth:  360
        implicitHeight: 240
        Rectangle { anchors.fill: parent; color: "#1b1b1b" }
    }
}
FILLER
    quickshell -p "$qml" >"$HEADLESS_W/filler.log" 2>&1 &
    HEADLESS_FILLER_PID=$!

    # The window has to be mapped and published over foreign-toplevel before
    # anything reads the window list, and nothing announces either step. A fixed
    # wait is the honest option; the check afterwards is what matters.
    sleep 2
    if ! kill -0 "$HEADLESS_FILLER_PID" 2>/dev/null; then
        echo "FAIL: the filler toplevel did not stay up; window assertions would be vacuous"
        tail -5 "$HEADLESS_W/filler.log" 2>/dev/null
        HEADLESS_FILLER_PID=""
        return 1
    fi
    return 0
}

# ── the refusals ─────────────────────────────────────────────────────────────
# Three things have to be true at once, and each has failed somewhere before:
# the runtime dir must not be the one the desktop uses, the socket must be
# inside it, and the display name must not be the ambient one. The third is not
# redundant — a private dir holding a symlink to the host's socket satisfies the
# first two, which is how tests/run-hypr-configerrors-test.sh reaches the
# session it nests in.
headless_assert_private() {
    if [ -n "$HEADLESS_AMBIENT_RUNTIME" ] && [ "$XDG_RUNTIME_DIR" = "$HEADLESS_AMBIENT_RUNTIME" ]; then
        echo "FAIL: XDG_RUNTIME_DIR is still the session's own; refusing to open a window on it"
        return 1
    fi
    local path="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
    if [ ! -S "$path" ]; then
        echo "FAIL: WAYLAND_DISPLAY does not name a socket in the private runtime dir"
        return 1
    fi
    if [ -L "$path" ]; then
        echo "FAIL: the private socket is a symlink, so it points somewhere this run does not own"
        return 1
    fi
    if [ -n "$HEADLESS_AMBIENT_DISPLAY" ] && [ "$WAYLAND_DISPLAY" = "$HEADLESS_AMBIENT_DISPLAY" ]; then
        echo "FAIL: the display this run came up on is the ambient one"
        return 1
    fi
    return 0
}

# A nested instance reporting the host's signature is not nested, and reloading
# it would reload the desk. Same defence tests/run-hypr-configerrors-test.sh
# carries, available to anything that nests.
headless_assert_not_ambient_signature() {
    local sig="$1"
    if [ -n "$HEADLESS_AMBIENT_SIG" ] && [ "$sig" = "$HEADLESS_AMBIENT_SIG" ]; then
        echo "FAIL: the nested signature is the ambient one; refusing to touch it"
        return 1
    fi
    return 0
}

# ── the opt-in gate ──────────────────────────────────────────────────────────
# For the two or three suites that genuinely cannot go headless — Hyprland
# 0.56.2 will not start on a GPU box with no DRM master, measured — a header
# saying "run this on a machine you are not using" is advisory and gets ignored.
# This refuses by default instead. Call it before anything touches the display.
headless_require_nested_optin() {
    local what="${1:-this suite}"
    if [ "${APEX_TEST_ALLOW_NESTED_ON_DESK:-0}" != "1" ]; then
        echo "SKIP: $what nests a compositor inside the session named by"
        echo "      WAYLAND_DISPLAY, which puts a window on that desktop for as"
        echo "      long as it runs. It refuses to do that to whoever is sitting"
        echo "      there. Re-run it on a machine you are not using with:"
        echo
        echo "          APEX_TEST_ALLOW_NESTED_ON_DESK=1 $0"
        exit 0
    fi
}

# ── teardown ─────────────────────────────────────────────────────────────────
# Killed by pid, never by name: a pkill for a compositor on a developer's
# machine takes down the session they are working in.
headless_cleanup() {
    [ -n "$HEADLESS_FILLER_PID" ] && kill "$HEADLESS_FILLER_PID" 2>/dev/null
    [ -n "$HEADLESS_NESTED_PID" ] && kill "$HEADLESS_NESTED_PID" 2>/dev/null
    [ -n "$HEADLESS_COMP_PID" ]   && kill "$HEADLESS_COMP_PID" 2>/dev/null
    sleep 0.3
    [ -n "$HEADLESS_FILLER_PID" ] && kill -9 "$HEADLESS_FILLER_PID" 2>/dev/null
    [ -n "$HEADLESS_NESTED_PID" ] && kill -9 "$HEADLESS_NESTED_PID" 2>/dev/null
    [ -n "$HEADLESS_COMP_PID" ]   && kill -9 "$HEADLESS_COMP_PID" 2>/dev/null
    [ -n "$HEADLESS_W" ] && rm -rf "$HEADLESS_W"
    return 0
}
