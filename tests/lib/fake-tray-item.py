#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
#  fake-tray-item.py — one StatusNotifierItem with a small DBusMenu, for the
#  headless harness (tests/run-traymenu-keys-test.sh).
#
#  ONLY ever run on a private session bus (dbus-run-session). On the desktop's
#  bus it would register in the real tray; the caller refuses unless
#  APEX_CAPTURE_BUS=private, and this refuses too.
#
#  The menu is First / Second / — / Third. A row that is chosen prints
#  `CLICKED <label>` on stdout, so the caller can tell which one the keyboard
#  activated.
# ─────────────────────────────────────────────────────────────────────────────
import os, sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

if os.environ.get("APEX_CAPTURE_BUS") != "private":
    sys.exit("fake-tray-item: refusing — APEX_CAPTURE_BUS=private (a dbus-run-session bus) is required")

ITEM_XML = """
<node><interface name="org.kde.StatusNotifierItem">
  <property name="Category" type="s" access="read"/>
  <property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="IconName" type="s" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
</interface></node>"""

MENU_XML = """
<node><interface name="com.canonical.dbusmenu">
  <property name="Version" type="u" access="read"/>
  <property name="Status" type="s" access="read"/>
  <method name="GetLayout">
    <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
    <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
  </method>
  <method name="GetGroupProperties">
    <arg type="ai" direction="in"/><arg type="as" direction="in"/>
    <arg type="a(ia{sv})" direction="out"/>
  </method>
  <method name="GetProperty">
    <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/>
  </method>
  <method name="Event">
    <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/>
  </method>
  <method name="EventGroup">
    <arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/>
  </method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
  <method name="AboutToShowGroup">
    <arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/>
  </method>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface></node>"""

ROWS = [(1, "First", False), (2, "Second", False), (3, "", True), (4, "Third", False)]

def props(label, sep):
    if sep:
        return {"type": GLib.Variant("s", "separator"), "visible": GLib.Variant("b", True)}
    return {"label": GLib.Variant("s", label), "enabled": GLib.Variant("b", True),
            "visible": GLib.Variant("b", True)}

def layout():
    kids = [GLib.Variant("(ia{sv}av)", (i, props(l, s), [])) for i, l, s in ROWS]
    return (1, (0, {"children-display": GLib.Variant("s", "submenu")}, kids))

def on_item_call(conn, sender, path, iface, method, params, inv):
    inv.return_value(None)

def on_item_prop(conn, sender, path, iface, prop):
    return {"Category": GLib.Variant("s", "ApplicationStatus"), "Id": GLib.Variant("s", "apex-fake-tray"),
            "Title": GLib.Variant("s", "Fake tray item"), "Status": GLib.Variant("s", "Active"),
            "IconName": GLib.Variant("s", "dialog-information"), "ItemIsMenu": GLib.Variant("b", True),
            "Menu": GLib.Variant("o", "/Menu")}[prop]

def on_menu_call(conn, sender, path, iface, method, params, inv):
    if os.environ.get("FAKE_TRAY_TRACE"): print(f"CALL {method} {params}", flush=True)
    if method == "GetLayout":
        inv.return_value(GLib.Variant("(u(ia{sv}av))", layout()))
    elif method == "GetGroupProperties":
        ids = params.unpack()[0]
        out = [(i, props(l, s)) for i, l, s in ROWS if not ids or i in ids]
        inv.return_value(GLib.Variant("(a(ia{sv}))", (out,)))
    elif method == "GetProperty":
        inv.return_value(GLib.Variant("(v)", (GLib.Variant("s", ""),)))
    elif method == "Event":
        i, ev, _, _ = params.unpack()
        if ev == "clicked":
            label = next((l for j, l, s in ROWS if j == i), "?")
            print(f"CLICKED {label}", flush=True)
        inv.return_value(None)
    elif method == "EventGroup":
        for i, ev, _, _ in params.unpack()[0]:
            if ev == "clicked":
                label = next((l for j, l, s in ROWS if j == i), "?")
                print(f"CLICKED {label}", flush=True)
        inv.return_value(GLib.Variant("(ai)", ([],)))
    elif method == "AboutToShow":
        inv.return_value(GLib.Variant("(b)", (False,)))
    elif method == "AboutToShowGroup":
        inv.return_value(GLib.Variant("(aiai)", ([], [])))
    else:
        inv.return_value(None)

def on_menu_prop(conn, sender, path, iface, prop):
    return {"Version": GLib.Variant("u", 3), "Status": GLib.Variant("s", "normal")}[prop]

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
bus.register_object("/StatusNotifierItem", Gio.DBusNodeInfo.new_for_xml(ITEM_XML).interfaces[0],
                    on_item_call, on_item_prop, None)
bus.register_object("/Menu", Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces[0],
                    on_menu_call, on_menu_prop, None)
name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
Gio.bus_own_name_on_connection(bus, name, Gio.BusNameOwnerFlags.NONE, None, None)

def register():
    try:
        bus.call_sync("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                      "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
                      GLib.Variant("(s)", (name,)), None, Gio.DBusCallFlags.NONE, 2000, None)
        print("REGISTERED", flush=True)
        return False
    except GLib.Error:
        return True          # the watcher (the shell) is not up yet: try again

GLib.timeout_add(500, register)
GLib.MainLoop().run()
