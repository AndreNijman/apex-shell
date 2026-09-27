# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/lib/private-bus.sh — a private session bus for a runner that does not
#  use tests/lib/headless.sh. Source it before anything starts a Qt process:
#
#      . "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"
#
#  ── Why ─────────────────────────────────────────────────────────────────────
#  headless.sh gives its runners their own bus (see the note there: a private
#  XDG_RUNTIME_DIR does not move DBUS_SESSION_BUS_ADDRESS, and shells under test
#  saw the desktop's media players, tray icons and notification name). Twenty-
#  four runners bring their own compositor or run offscreen and never sourced
#  it, so every page and service they load — a NotificationServer, the tray
#  watcher, MPRIS — was on the desktop's own session bus (found by the Phase 17
#  review, 2026-09-26). check-headless-runners.sh now requires one or the other.
#
#  ── How ─────────────────────────────────────────────────────────────────────
#  The runner re-executes itself under dbus-run-session, which ends the bus
#  when the runner exits — no daemon outlives a run, whatever traps the runner
#  sets later. The bus config lists NO service directories, so nothing can be
#  activated on it: no portal, and no secrets service that could put a keyring
#  prompt on the screen. The daemon is started without the display variables;
#  the runner gets them back, unchanged, so its own skip logic is unaffected.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${APEX_TEST_BUS:-}" != private ]; then
    if command -v dbus-run-session >/dev/null 2>&1; then
        _apex_bus_conf="$(mktemp "${TMPDIR:-/tmp}/apex-test-bus.XXXXXX.conf")"
        cat > "$_apex_bus_conf" <<'CONF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
CONF
        export APEX_TEST_BUS=private APEX_TEST_BUS_CONF="$_apex_bus_conf"
        exec env -u WAYLAND_DISPLAY -u DISPLAY \
            dbus-run-session --config-file="$_apex_bus_conf" -- \
            env ${WAYLAND_DISPLAY+WAYLAND_DISPLAY="$WAYLAND_DISPLAY"} ${DISPLAY+DISPLAY="$DISPLAY"} \
            bash "$0" "$@"
    fi
    # No dbus-run-session: an address nothing listens on, never the desktop's.
    export APEX_TEST_BUS=private DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent/apex-test-bus"
fi
# The daemon has read its config by now.
[ -n "${APEX_TEST_BUS_CONF:-}" ] && rm -f "$APEX_TEST_BUS_CONF" && unset APEX_TEST_BUS_CONF
