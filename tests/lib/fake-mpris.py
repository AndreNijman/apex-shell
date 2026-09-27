#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
#  fake-mpris.py — a media player that plays nothing, for keyboard tests of
#  the Dashboard's player card (UI/UX roadmap v3 Phase 21). The companion of
#  fake-nmcli.
#
#  Owns org.mpris.MediaPlayer2.apexkeytest on the session bus it is started
#  on — a runner's PRIVATE bus (tests/lib/headless.sh), never the desktop's,
#  where the card would otherwise find the user's own player and a key would
#  pause their music. One paused track, 3:00 long, at 1:00; it can do
#  everything. Every call is appended to the log (argv[1]) as one line —
#  `Play`, `SetPosition /apex/track/1 65000000`, `Seek 5000000` — and changes
#  nothing, so the card's reading of the player stays fixed between keys.
# ─────────────────────────────────────────────────────────────────────────────
import sys

from gi.repository import Gio, GLib

LOG = sys.argv[1] if len(sys.argv) > 1 else "/dev/null"
TRACK = "/apex/track/1"

XML = """
<node>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/><method name="Quit"/>
    <property name="Identity" type="s" access="read"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="DesktopEntry" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Next"/><method name="Previous"/><method name="Pause"/>
    <method name="PlayPause"/><method name="Stop"/><method name="Play"/>
    <method name="Seek"><arg direction="in" name="Offset" type="x"/></method>
    <method name="SetPosition">
      <arg direction="in" name="TrackId" type="o"/>
      <arg direction="in" name="Position" type="x"/>
    </method>
    <method name="OpenUri"><arg direction="in" name="Uri" type="s"/></method>
    <signal name="Seeked"><arg name="Position" type="x"/></signal>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="LoopStatus" type="s" access="readwrite"/>
    <property name="Rate" type="d" access="readwrite"/>
    <property name="Shuffle" type="b" access="readwrite"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="Volume" type="d" access="readwrite"/>
    <property name="Position" type="x" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
  </interface>
</node>
"""

PROPS = {
    "Identity": GLib.Variant("s", "Keytest Player"),
    "CanQuit": GLib.Variant("b", False),
    "CanRaise": GLib.Variant("b", False),
    "HasTrackList": GLib.Variant("b", False),
    "DesktopEntry": GLib.Variant("s", "keytest"),
    "SupportedUriSchemes": GLib.Variant("as", []),
    "SupportedMimeTypes": GLib.Variant("as", []),
    "PlaybackStatus": GLib.Variant("s", "Paused"),
    "LoopStatus": GLib.Variant("s", "None"),
    "Rate": GLib.Variant("d", 1.0),
    "Shuffle": GLib.Variant("b", False),
    "Metadata": GLib.Variant("a{sv}", {
        "mpris:trackid": GLib.Variant("o", TRACK),
        "mpris:length": GLib.Variant("x", 180_000_000),
        "xesam:title": GLib.Variant("s", "Keytest Track"),
        "xesam:artist": GLib.Variant("as", ["Keytest Artist"]),
    }),
    "Volume": GLib.Variant("d", 1.0),
    "Position": GLib.Variant("x", 60_000_000),
    "MinimumRate": GLib.Variant("d", 1.0),
    "MaximumRate": GLib.Variant("d", 1.0),
    "CanGoNext": GLib.Variant("b", True),
    "CanGoPrevious": GLib.Variant("b", True),
    "CanPlay": GLib.Variant("b", True),
    "CanPause": GLib.Variant("b", True),
    "CanSeek": GLib.Variant("b", True),
    "CanControl": GLib.Variant("b", True),
}


def record(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")


def on_call(_conn, _sender, _path, _iface, method, params, invocation):
    args = " ".join(str(a) for a in params.unpack())
    record(f"{method} {args}".rstrip())
    invocation.return_value(None)


def on_get(_conn, _sender, _path, _iface, prop):
    return PROPS.get(prop)


def on_set(_conn, _sender, _path, _iface, prop, value):
    record(f"set {prop} {value.unpack()}")
    return True


def on_bus(conn, _name):
    node = Gio.DBusNodeInfo.new_for_xml(XML)
    for iface in node.interfaces:
        conn.register_object("/org/mpris/MediaPlayer2", iface, on_call, on_get, on_set)


def on_lost(_conn, _name):
    sys.exit(1)


Gio.bus_own_name(Gio.BusType.SESSION, "org.mpris.MediaPlayer2.apexkeytest",
                 Gio.BusNameOwnerFlags.NONE, on_bus, None, on_lost)
GLib.MainLoop().run()
