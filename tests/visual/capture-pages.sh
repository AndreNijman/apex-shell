#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  capture-pages.sh — every page Phase 17 redesigns, settled, with content in
#  it (UI/UX roadmap v3 Phase 17: "a layout and hierarchy pass" on Dashboard
#  Home, System, Agents, Tasks, Launcher, Network, Notifications and Nexus).
#
#      tests/visual/capture-pages.sh OUTDIR [dark|light ...]
#
#  capture-surfaces.sh measures motion on whatever the shell shows by default;
#  a layout pass needs the pages as a user sees them, full. So the content is
#  seeded, and nothing reaches the machine: headless.sh's private bus and HOME,
#  tests/lib/fake-nmcli and fake-bluetoothctl for the network panes,
#  fake-mpris.py for the player, fake-brightnessctl, a tasks.json with cards in
#  every column, and notifications sent to the shell on the private bus. The
#  palette is the fixture's (tests/fixtures/palettes-matugen-4.2.0.json, the
#  default wallpaper), dark and light.
#
#  Writes OUTDIR/<scheme>/<page>.png — one settled 1920x1080 frame per page.
#  CAPTURE_PAGES="home tasks" captures only those pages (default: all).
#  CAPTURE_UNRESTRICTED=1 turns Always Unrestricted on (the harness's own
#  ~/.config/apex/agent.json), so the Agents panel shows its indicator.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
. "$root/tests/lib/headless.sh"
headless_require quickshell labwc grim python3 gdbus

out="${1:-}"; shift || true
[ -n "$out" ] || { echo "usage: $0 OUTDIR [dark|light ...]"; exit 2; }
schemes=("$@"); [ ${#schemes[@]} -gt 0 ] || schemes=(dark light)
mkdir -p "$out"; out="$(cd "$out" && pwd)"

capture_scheme() {   # capture_scheme <dark|light> — one shell, every page
    local scheme="$1" qs="" player="" _
    headless_begin
    ln -sf "$root/tests/lib/fake-nmcli" "$HEADLESS_W/bin/nmcli"
    ln -sf "$root/tests/lib/fake-bluetoothctl" "$HEADLESS_W/bin/bluetoothctl"
    ln -sf "$root/tests/lib/fake-brightnessctl" "$HEADLESS_W/bin/brightnessctl"
    for n in nmtui blueman-manager rfkill hyprshade hyprsunset systemd-inhibit sing-box; do
        ln -sf "$HEADLESS_W/bin/_stub" "$HEADLESS_W/bin/$n"
    done
    [ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
    headless_start labwc 1920x1080 || return 0
    python3 "$root/tests/lib/fake-mpris.py" /dev/null & player=$!
    # The wallpaper the palette came from, behind the shell, as a user sees it.
    local wallpid=""
    if command -v swaybg >/dev/null 2>&1; then
        swaybg -m fill -i "$root/src/assets/wallpapers/apex-shell-default-0.png" >/dev/null 2>&1 & wallpid=$!
    fi

    local ud="$HOME/.config/apex-shell/src/user_data"
    mkdir -p "$ud" "$HOME/.cache/apex-shell"
    printf '{"barEnabled":true,"animDuration":320,"motionScale":1,"dashboardWidth":900,"dashboardHeight":520}' > "$ud/settings.json"
    python3 - "$root/tests/fixtures/palettes-matugen-4.2.0.json" "$scheme" "$HOME/.cache/apex-shell/colors.json" <<'PY'
import json, sys
p = next(x for x in json.load(open(sys.argv[1]))["palettes"]
         if x["wall"] == "apex-shell-default-0.png" and x["mode"] == sys.argv[2])
json.dump({k: p[k] for k in ("background", "active", "text", "subtext", "border", "iconFont")},
          open(sys.argv[3], "w"))
PY
    if [ "${CAPTURE_UNRESTRICTED:-0}" = 1 ]; then
        mkdir -p "$HOME/.config/apex"; printf '{"sandbox":"unrestricted"}' > "$HOME/.config/apex/agent.json"
    fi
    python3 - "$ud/tasks.json" <<'PY'
import json, sys, datetime
d = datetime.date.today()
t = lambda i, title, col, urg="", due="": {"id": i, "title": title, "column": col, "urgency": urg,
                                           "dueDate": due}
tasks = [t(0, "Draft the release notes for v2.2", 0, "high", (d + datetime.timedelta(days=1)).isoformat()),
         t(1, "Review the netinstall VM qualification", 0, "medium"),
         t(2, "Reply to the FIRST sponsor email", 0),
         t(3, "Port the agent colours to the light palette", 1, "low",
           (d + datetime.timedelta(days=4)).isoformat() + " 14:00"),
         t(4, "Profile the dashboard's first open", 1, "high"),
         t(5, "Merge the password shapes branch", 2),
         t(6, "Ship the hit-target check", 2, "low")]
json.dump({"tasks": tasks, "nextId": 7}, open(sys.argv[1], "w"))
PY
    quickshell -p "$root/shell.qml" > "$HEADLESS_W/shell.log" 2>&1 & qs=$!
    for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$HEADLESS_W/shell.log" && break; sleep 0.25; done
    sleep 3
    ipc() { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }
    shot() { grim "$out/$scheme/$1.png"; }
    want() { [ -z "${CAPTURE_PAGES:-}" ] || [[ " $CAPTURE_PAGES " == *" $1 "* ]]; }
    mkdir -p "$out/$scheme"

    local n
    for n in "Build finished|apex-os roadmap/v2.2: 0 failures, 1,240 commits" \
             "Sam Rivera|Are we still on for the robotics meeting at 4?" \
             "Update ready|APEX-OS 2.2.1 is staged and applies on the next restart" \
             "Battery|18 % remaining"; do
        gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
            --method org.freedesktop.Notifications.Notify "Pages" 0 "" "${n%%|*}" "${n#*|}" "[]" "{}" 0 >/dev/null 2>&1
        sleep 0.3
    done
    sleep 6   # let the toasts settle; expiry 0 keeps them in the centre

    local pair page cmd
    for pair in "home|dashboard-home" "system|dashboard-stats" "agents|dashboard-agents" "tasks|dashboard-kanban" \
                "launcher|dashboard-launcher" "config|dashboard-config"; do
        page="${pair%%|*}"; cmd="${pair#*|}"; want "$page" || continue
        ipc "$cmd" toggle; sleep 2.2; shot "$page"; ipc "$cmd" toggle; sleep 1.2
    done
    for pair in "network-wifi|wifi-toggle" "network-bluetooth|bluetooth-toggle" "network-vpn|vpn-toggle" \
                "notifications|notification-toggle"; do
        page="${pair%%|*}"; cmd="${pair#*|}"; want "$page" || continue
        ipc "$cmd" toggle; sleep 2; shot "$page"; ipc "$cmd" toggle; sleep 1.2
    done
    local p
    for p in $(quickshell -p "$root/shell.qml" ipc call nexus pages 2>/dev/null | tr ',' ' '); do
        want "nexus-$p" || continue
        ipc nexus open "$p"; sleep 1.6; shot "nexus-$p"
    done
    ipc nexus close; sleep 1

    kill "$qs" "$player" $wallpid 2>/dev/null
    grep -E 'TypeError|ReferenceError|is not a type' "$HEADLESS_W/shell.log" | head -3
    headless_cleanup
    echo "captured $scheme: $(ls "$out/$scheme" | wc -l) pages"
}

for s in "${schemes[@]}"; do capture_scheme "$s"; done
