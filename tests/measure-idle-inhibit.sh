#!/usr/bin/env bash
# Measure which idle-inhibit mechanism actually stops the idle daemon, per
# compositor. MANUAL: it needs a Wayland session, so it is not wired into CI —
# the headless invariants that ARE wired in live in tests/check-idle-inhibit.sh.
#
# usage: tests/measure-idle-inhibit.sh [hyprland|labwc] [idle-timeout-seconds]
#
# ── What it found ────────────────────────────────────────────────────────────
# Recorded here because ShellState's comment cites these numbers, and a cited
# measurement should say where it came from. Run 2026-09-03, hypridle 0.1.8:
#
#   Hyprland 0.56.2
#     nothing held ............................ FIRED   (control)
#     layer surface present, no inhibitor ..... FIRED   (control)
#     Wayland inhibitor on a LAYER SURFACE .... FIRED   <- no effect
#     Wayland inhibitor on a toplevel ......... suppressed
#     logind --what=idle --mode=block ......... suppressed
#     org.freedesktop.ScreenSaver.Inhibit ..... suppressed
#     ...same, caller disconnects ............. FIRED   (correctly released)
#
#   labwc 0.9.6
#     nothing held ............................ FIRED   (control)
#     layer surface present, no inhibitor ..... FIRED   (control)
#     Wayland inhibitor on a LAYER SURFACE .... suppressed
#     Wayland inhibitor on a toplevel ......... suppressed
#     logind --what=idle --mode=block ......... suppressed
#     org.freedesktop.ScreenSaver.Inhibit ..... suppressed
#     ...same, caller disconnects ............. FIRED   (correctly released)
#
# The bar is a layer-shell surface, so Hyprland's row three is the shell's
# Caffeine: it did nothing there. The logind row is why Caffeine now holds a
# logind lock on every compositor.
#
# ── Three ways this measurement can lie, and what stops each ────────────────
# 1. A CONTROL THAT NEVER FIRES. "The daemon stayed quiet" means nothing unless
#    it demonstrably fires in the same setup, so every treated arm is paired
#    with a control and a control that fails to fire prints VACUOUS.
#
# 2. A DETECTOR THAT MATCHES THE CONFIG. The first version of this grepped
#    hypridle's log for the string its rule echoes. hypridle PRINTS ITS OWN
#    RULE at startup ("on-timeout: echo ..."), so that string was present in
#    every arm whether the rule ran or not and every arm read FIRED — a verdict
#    completely independent of what was being measured. The detector is now a
#    marker FILE the rule itself creates, which no amount of hypridle describing
#    the rule can produce.
#
# 3. STATE CARRIED BETWEEN ARMS. Run sequentially in one compositor, arms after
#    the first read no-fire regardless: an inhibitor from a previous arm was
#    still in force. Every arm therefore gets a FRESH compositor, a fresh
#    throwaway XDG_CONFIG_HOME and a fresh private session bus.
#
# ── It never touches the developer's session ────────────────────────────────
# The idle daemon under test runs inside a nested compositor with a throwaway
# config whose only action is `touch`: no lock_cmd, no before_sleep_cmd, no
# dpms, no brightness. It reads nothing under ~/.config. The private session bus
# matters too — a live hypridle already owns org.freedesktop.ScreenSaver, so
# without dbus-run-session the Inhibit arm would hit the REAL daemon.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

target="${1:-hyprland}"
TMO="${2:-8}"

case "$target" in
    hyprland|labwc) ;;
    *) echo "usage: $0 [hyprland|labwc] [idle-timeout-seconds]"; exit 2 ;;
esac

for bin in hypridle quickshell systemd-inhibit dbus-run-session python3; do
    command -v "$bin" >/dev/null 2>&1 \
        || { echo "SKIP: $bin is not installed"; exit 0; }
done
command -v "$([ "$target" = labwc ] && echo labwc || echo Hyprland)" >/dev/null 2>&1 \
    || { echo "SKIP: $target is not installed"; exit 0; }
[ -n "${WAYLAND_DISPLAY:-}" ] \
    || { echo "SKIP: no WAYLAND_DISPLAY; this needs a Wayland session to nest in"; exit 0; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

# ── The Wayland clients ──────────────────────────────────────────────────────
# A layer surface (what the bar is) and a toplevel, each with and without an
# inhibitor. exclusiveZone 0 and a 40x20 footprint so that even if someone runs
# this against a real session by mistake, no window is moved.
write_client() {
    local path="$1" surface="$2" inhibit="$3"
    {
        echo 'import Quickshell'
        [ "$inhibit" = yes ] && echo 'import Quickshell.Wayland'
        echo 'import QtQuick'
        echo 'ShellRoot {'
        if [ "$surface" = layer ]; then
            echo '  PanelWindow {'
            echo '    id: win'
            echo '    visible: true'
            echo '    exclusiveZone: 0'
            echo '    anchors { bottom: true; left: true }'
            echo '    implicitWidth: 40'
            echo '    implicitHeight: 20'
            echo '    color: "#004400"'
        else
            echo '  FloatingWindow {'
            echo '    id: win'
            echo '    visible: true'
            echo '    implicitWidth: 200'
            echo '    implicitHeight: 120'
            echo '    Rectangle { anchors.fill: parent; color: "#004400" }'
        fi
        [ "$inhibit" = yes ] && echo '    IdleInhibitor { window: win; enabled: true }'
        echo '  }'
        echo '}'
    } > "$path"
}

write_client "$work/layer-plain.qml"    layer    no
write_client "$work/layer-inhibit.qml"  layer    yes
write_client "$work/top-inhibit.qml"    toplevel yes

# ── The ScreenSaver D-Bus holder ─────────────────────────────────────────────
# Must hold the connection open: the daemon releases the inhibit when the caller
# disconnects, which is itself one of the arms below.
cat > "$work/hold-ss.py" <<'PY'
import sys, gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
secs = float(sys.argv[1]); drop = float(sys.argv[2]) if len(sys.argv) > 2 else -1.0
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
p = Gio.DBusProxy.new_sync(bus, Gio.DBusProxyFlags.NONE, None,
    "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
    "org.freedesktop.ScreenSaver", None)
c = p.call_sync("Inhibit", GLib.Variant("(ss)", ("apex-shell-probe", "measuring")),
                Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
print("INHIBIT-COOKIE %d" % c, flush=True)
loop = GLib.MainLoop()
GLib.timeout_add(int((drop if drop > 0 else secs) * 1000),
                 lambda: (loop.quit(), False)[1])
loop.run()
PY

# ── Nested compositor plumbing ───────────────────────────────────────────────
list_sockets() {
    local f name suffix
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [ -S "$f" ] || continue
        name="${f##*/}"; suffix="${name#wayland-}"
        case "$suffix" in '' | *[!0-9]*) continue ;; esac
        printf '%s\n' "$name"
    done | sort
}

# Hyprland's per-instance dir under $XDG_RUNTIME_DIR/hypr IS its signature.
# Diffing the listing identifies the nested instance; Hyprland does not print
# its socket anywhere scrapeable.
list_sigs() {
    local d
    for d in "$XDG_RUNTIME_DIR"/hypr/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"; printf '%s\n' "${d##*/}"
    done | sort
}

pass=0
vacuous=0
declare -a RESULTS=()

# arm <label> <expect: fire|suppress> <mech: none|logind|dbus|dbus-drop> [qml]
arm() {
    local label="$1" expect="$2" mech="$3" qml="${4:-}"
    local home cfgdir clog dlog marker before sigs_before nested sig cpid lpid qpid=""

    home="$work/home.$$.$RANDOM"; cfgdir="$home/.config/hypr"
    mkdir -p "$cfgdir"
    clog="$(mktemp -p "$work")"; dlog="$(mktemp -p "$work")"
    marker="$home/FIRED.marker"

    printf 'listener {\n    timeout = %s\n    on-timeout = touch %s\n}\n' \
        "$TMO" "$marker" > "$cfgdir/hypridle.conf"

    before="$(list_sockets)"; sigs_before="$(list_sigs)"
    if [ "$target" = labwc ]; then
        cp "$here/labwc-test-rc.xml" "$home/rc.xml"
        env -u HYPRLAND_INSTANCE_SIGNATURE -u NIRI_SOCKET \
            XDG_CURRENT_DESKTOP=labwc:wlroots labwc -C "$home" >"$clog" 2>&1 &
    else
        HYPRLAND_NO_SD_NOTIFY=1 Hyprland -c "$here/measure-idle-hyprland.conf" \
            >"$clog" 2>&1 &
    fi
    lpid=$!

    nested=""
    for _ in $(seq 1 80); do
        nested="$(comm -13 <(echo "$before") <(list_sockets) | head -1)"
        [ -n "$nested" ] && break
        kill -0 "$lpid" 2>/dev/null || break
        sleep 0.25
    done
    sig=""
    [ "$target" = hyprland ] && sig="$(comm -13 <(echo "$sigs_before") <(list_sigs) | head -1)"

    teardown() {
        [ -n "$qpid" ] && { kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null; }
        kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null
        # Only the dir this arm created, identified by diff — never a glob over
        # $XDG_RUNTIME_DIR/hypr, which also holds the live session's socket.
        [ -n "$sig" ] && [ -d "$XDG_RUNTIME_DIR/hypr/$sig" ] \
            && rm -rf "$XDG_RUNTIME_DIR/hypr/$sig"
        rm -rf "$home"
    }

    if [ -z "$nested" ]; then
        RESULTS+=("  VACUOUS  $label -- no nested $target display")
        vacuous=$((vacuous + 1)); teardown; return
    fi
    sleep 2

    local desktop="Hyprland"
    [ "$target" = labwc ] && desktop="labwc:wlroots"

    if [ -n "$qml" ]; then
        env WAYLAND_DISPLAY="$nested" XDG_CURRENT_DESKTOP="$desktop" \
            HYPRLAND_INSTANCE_SIGNATURE="$sig" \
            quickshell -p "$qml" >/dev/null 2>&1 &
        qpid=$!
        sleep 2.5
        if ! kill -0 "$qpid" 2>/dev/null; then
            RESULTS+=("  VACUOUS  $label -- the Wayland client exited before measuring")
            vacuous=$((vacuous + 1)); teardown; return
        fi
    fi

    env WAYLAND_DISPLAY="$nested" XDG_CURRENT_DESKTOP="$desktop" \
        HYPRLAND_INSTANCE_SIGNATURE="$sig" \
        HOME="$home" XDG_CONFIG_HOME="$home/.config" \
        P_MECH="$mech" P_TMO="$TMO" P_WORK="$work" \
        P_CFG="$cfgdir/hypridle.conf" P_DLOG="$dlog" \
    dbus-run-session -- bash -c '
        hypridle -c "$P_CFG" >/dev/null 2>&1 &
        hpid=$!
        sleep 2
        holder=""
        case "$P_MECH" in
            logind)
                systemd-inhibit --what=idle --who="APEX Shell probe" \
                    --why="measuring" --mode=block sleep 120 >/dev/null 2>&1 &
                holder=$!
                sleep 1
                busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
                    org.freedesktop.login1.Manager BlockInhibited 2>&1 \
                    | sed "s/^/BLOCKINHIBITED /" >> "$P_DLOG" ;;
            dbus)
                python3 "$P_WORK/hold-ss.py" 120 >> "$P_DLOG" 2>&1 & holder=$!
                sleep 1 ;;
            dbus-drop)
                python3 "$P_WORK/hold-ss.py" 120 2 >> "$P_DLOG" 2>&1 & holder=$!
                sleep 1 ;;
        esac
        if [ -n "$holder" ]; then
            kill -0 "$holder" 2>/dev/null || echo "HOLDER-DIED" >> "$P_DLOG"
        fi
        sleep $((P_TMO + 7))
        [ -n "$holder" ] && { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; }
        kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
    ' _

    local notes=""
    grep -q "HOLDER-DIED" "$dlog" 2>/dev/null && notes="$notes HOLDER-DIED"
    grep -q 'BLOCKINHIBITED s "idle"' "$dlog" 2>/dev/null && notes="$notes logind=idle"
    grep -q "INHIBIT-COOKIE" "$dlog" 2>/dev/null && notes="$notes cookie"

    # THE detector: a file the idle rule itself created.
    local got verdict
    if [ -f "$marker" ]; then got="fire"; else got="suppress"; fi

    if [ -n "$notes" ] && grep -q "HOLDER-DIED" <<<"$notes"; then
        RESULTS+=("  VACUOUS  $label -- the inhibitor holder died; nothing was held")
        vacuous=$((vacuous + 1)); teardown; return
    fi

    if [ "$got" = "$expect" ]; then verdict="ok      "; pass=$((pass + 1))
    else                            verdict="MISMATCH"; fi
    RESULTS+=("  $verdict $(printf '%-9s' "$got") $label${notes:+   [${notes# }]}")

    teardown
}

echo "### $target + hypridle $(hypridle --version 2>&1 | head -1), idle timeout ${TMO}s"
echo "    fresh compositor + throwaway config + private session bus per arm"
echo "    detector: a marker file the idle rule creates, not a grep of the daemon's log"
echo

# Controls first. If either reads suppress, the apparatus is broken and nothing
# below means anything.
arm "control: nothing held"                              fire     none
arm "control: layer surface present, no inhibitor"       fire     none "$work/layer-plain.qml"

# The mechanism the bar actually uses.
arm "wayland: inhibitor on a LAYER SURFACE (the bar)"    "${LAYER_EXPECT:-suppress}" none "$work/layer-inhibit.qml"
arm "wayland: inhibitor on a toplevel"                   suppress none "$work/top-inhibit.qml"

# The compositor-independent mechanisms.
arm "logind:  systemd-inhibit --what=idle --mode=block"  suppress logind
arm "dbus:    org.freedesktop.ScreenSaver.Inhibit"       suppress dbus
arm "dbus:    ...caller disconnects mid-run"             fire     dbus-drop

printf '%s\n' "${RESULTS[@]}"
echo
echo "arms matching expectation: $pass   vacuous: $vacuous"
echo
echo "NOTE: on Hyprland the LAYER SURFACE arm is EXPECTED to fire — Hyprland"
echo "      ignores idle inhibitors on layer-shell surfaces. Re-run that arm with"
echo "      LAYER_EXPECT=fire to assert the known-bad behaviour instead."
[ "$vacuous" -eq 0 ]
