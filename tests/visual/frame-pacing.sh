#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  frame-pacing.sh — frames delivered, hitches and forks while each surface
#  opens and closes (UI/UX roadmap v3 Phase 22).
#
#      tests/visual/frame-pacing.sh OUTDIR [warm-repeats]
#
#  The shell runs in headless.sh's private labwc on the machine's GPU (gles2,
#  when /dev/dri/renderD128 exists) with APEX_PACING_LOG=1, so every
#  SurfaceLifecycle logs, when an open or a close ends:
#      APEX pacing: <surface> <Opening|Closing> ms=<n> frames=<n> worst=<ms>
#  Each surface is opened and closed once cold, then N times warm (default 5).
#  Frames expected at 60 Hz are ms / 16.67; the difference is the miss count,
#  and `worst` is the longest gap between two delivered frames.
#
#  Forks: a watcher polls /proc every 2 ms for processes descended from the
#  shell, and each is attributed to the open or close window it started in —
#  the roadmap's rule is "no process forks in animation-critical paths". A
#  process that lives under 2 ms can be missed; the ones that matter (a bash,
#  an nmcli) do not.
#
#  What this cannot measure, said here so a green report is not read as more:
#  compositor-side presentation on the real panel (this counts the frames Qt's
#  animation driver advanced, not the ones a display scanned out), mixed refresh
#  rates, and input-to-visible latency below grim's cadence. It is a QA report
#  under tests/visual, not a CI gate: headless timing on a shared machine is
#  too noisy to fail a build on, and findings are fixed and recorded instead.
#
#  PACING_SURFACES="dashboard network" measures only those surfaces;
#  PACING_ENV="VAR=value ..." adds to the shell's environment (through env).
#
#  Writes OUTDIR/report.txt, OUTDIR/pacing.log (the raw lines), OUTDIR/forks.tsv.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
. "$root/tests/lib/headless.sh"
headless_require quickshell labwc python3

out="${1:-}"; [ -n "$out" ] || { echo "usage: $0 OUTDIR [warm-repeats]"; exit 2; }
reps="${2:-5}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"

headless_begin
ln -sf "$root/tests/lib/fake-nmcli" "$HEADLESS_W/bin/nmcli"
ln -sf "$root/tests/lib/fake-bluetoothctl" "$HEADLESS_W/bin/bluetoothctl"
ln -sf "$root/tests/lib/fake-brightnessctl" "$HEADLESS_W/bin/brightnessctl"
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0
python3 "$root/tests/lib/fake-mpris.py" /dev/null & player=$!
# Every background child dies with the run: an early exit that left the fake
# player behind held the caller's pipe open, and a `| sed` after this hung.
qs=""; watcher=""
trap 'kill $player $qs $watcher 2>/dev/null; headless_cleanup' EXIT

ud="$HOME/.config/apex-shell/src/user_data"; mkdir -p "$ud"
# PACING_SETTINGS='{...}' replaces the settings (an experiment: a surface off, a
# border width, a motion speed); the default is the shipped look.
printf '%s' "${PACING_SETTINGS:-{\"barEnabled\":true,\"animDuration\":320,\"motionScale\":1,\"dashboardWidth\":900,\"dashboardHeight\":520}}" > "$ud/settings.json"

env APEX_PACING_LOG=1 ${PACING_ENV:-} quickshell -p "$root/shell.qml" > "$HEADLESS_W/shell.log" 2>&1 & qs=$!
for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$HEADLESS_W/shell.log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$HEADLESS_W/shell.log" || { echo "FAIL: the shell did not load"; tail -20 "$HEADLESS_W/shell.log"; exit 1; }
sleep 4   # startup's own processes (probes, pollers) settle before anything is timed

# The fork watcher: every process whose ancestry reaches the shell.
python3 - "$qs" "$out/forks.tsv" <<'PY' & watcher=$!
import os, sys, time
qs, path = int(sys.argv[1]), sys.argv[2]
seen = set()
def ppid(p):
    try:
        with open(f"/proc/{p}/stat") as f: return int(f.read().rsplit(")", 1)[1].split()[1])
    except Exception: return -1
with open(path, "w") as out:
    while os.path.exists(f"/proc/{qs}"):
        for d in os.listdir("/proc"):
            if not d.isdigit(): continue
            p = int(d)
            if p in seen or p == qs: continue
            a, hops = p, 0
            while a > 1 and a != qs and hops < 8: a = ppid(a); hops += 1
            if a != qs: continue
            seen.add(p)
            try: cmd = open(f"/proc/{p}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace").strip()
            except Exception: cmd = ""
            if not cmd:
                try: cmd = "[" + open(f"/proc/{p}/comm").read().strip() + "]"
                except Exception: cmd = "?"
            out.write(f"{time.time()*1000:.0f}\t{p}\t{cmd[:160]}\n"); out.flush()
        time.sleep(0.002)
PY

ipc() { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }
now() { date +%s%3N; }
timeline="$out/timeline.tsv"; : > "$timeline"
# name | open command | close command
surfaces=(
    "dashboard|dashboard-home toggle|dashboard-home toggle"
    "dash-stats|dashboard-stats toggle|dashboard-stats toggle"
    "dash-agents|dashboard-agents toggle|dashboard-agents toggle"
    "dash-kanban|dashboard-kanban toggle|dashboard-kanban toggle"
    "dash-launcher|dashboard-launcher toggle|dashboard-launcher toggle"
    "network|wifi-toggle toggle|wifi-toggle toggle"
    "notifications|notification-toggle toggle|notification-toggle toggle"
    "audio|audioOut-toggle toggle|audioOut-toggle toggle"
    "power|PowerMenu-toggle toggle|PowerMenu-toggle toggle"
    "clipboard|clipboard-toggle toggle|clipboard-toggle toggle"
    "wallpaper|wallpaper-toggle toggle|wallpaper-toggle toggle"
    "context|context-menu open|context-menu close"
    "nexus|nexus open appearance|nexus close"
)
for entry in "${surfaces[@]}"; do
    IFS='|' read -r name opencmd closecmd <<<"$entry"
    # PACING_SURFACES="dashboard network" measures only those.
    [ -z "${PACING_SURFACES:-}" ] || [[ " $PACING_SURFACES " == *" $name "* ]] || continue
    for i in $(seq 0 "$reps"); do
        kind=warm; [ "$i" = 0 ] && kind=cold
        t0=$(now); ipc $opencmd; sleep 1.2; t1=$(now)
        printf '%s\t%s\topen\t%s\t%s\n' "$name" "$kind" "$t0" "$t1" >> "$timeline"
        t0=$(now); ipc $closecmd; sleep 1.0; t1=$(now)
        printf '%s\t%s\tclose\t%s\t%s\n' "$name" "$kind" "$t0" "$t1" >> "$timeline"
    done
done

kill "$qs" "$player" 2>/dev/null; sleep 0.3; kill "$watcher" 2>/dev/null
grep -a 'APEX pacing:' "$HEADLESS_W/shell.log" | sed 's/.*APEX pacing: //' > "$out/pacing.log"
grep -aE 'TypeError|ReferenceError|is not a type' "$HEADLESS_W/shell.log" | head -3
headless_cleanup

python3 - "$out" "${HEADLESS_WLR_RENDERER:-pixman}" <<'PY'
import sys, collections, statistics
out, renderer = sys.argv[1], sys.argv[2]
rows = collections.defaultdict(list)
for line in open(f"{out}/pacing.log"):
    parts = line.split()
    if len(parts) < 5: continue
    name, phase = parts[0], parts[1]
    kv = dict(p.split("=") for p in parts[2:] if "=" in p)
    rows[(name, phase)].append((int(kv["ms"]), int(kv["frames"]), int(kv["worst"]), float(kv.get("at", -1)), int(kv.get("first", -1))))
tl = [l.rstrip("\n").split("\t") for l in open(f"{out}/timeline.tsv")]
forks = [l.rstrip("\n").split("\t", 2) for l in open(f"{out}/forks.tsv")]
def forks_in(t0, t1, lead=450):
    # The animation-critical part of a window is its first `lead` ms: the open
    # or close itself. Anything later is the surface at rest (a poller that a
    # page starts once it is open is the refcounting working, not a hitch).
    return [f for f in forks if t0 <= float(f[0]) <= t0 + lead]
fk = collections.defaultdict(list)
for name, kind, act, t0, t1 in tl:
    for f in forks_in(float(t0), float(t1)):
        fk[(name, act, kind)].append(f[2])
with open(f"{out}/report.txt", "w") as r:
    r.write(f"frame pacing — renderer {renderer}, 60 Hz budget 16.67 ms\n\n")
    r.write(f"{'surface':15} {'phase':8} {'n':>3} {'ms(med)':>8} {'frames':>7} {'miss(max)':>9} {'worst(max)':>11} {'worst(med)':>11} {'at(med)':>8} {'first(med)':>10}\n")
    for (name, phase), v in sorted(rows.items()):
        ms = [x[0] for x in v]; fr = [x[1] for x in v]; wo = [x[2] for x in v]
        at = [x[3] for x in v]; fi = [x[4] for x in v]
        miss = [max(0, round(x[0] / 16.67) - x[1]) for x in v]
        r.write(f"{name:15} {phase:8} {len(v):>3} {statistics.median(ms):>8.0f} {statistics.median(fr):>7.0f} {max(miss):>9} {max(wo):>11} {statistics.median(wo):>11.0f} {statistics.median(at):>8.2f} {statistics.median(fi):>10.0f}\n")
    r.write("\nprocesses the shell started during an open or close (first 450 ms):\n")
    if not fk: r.write("  none\n")
    for (name, act, kind), cmds in sorted(fk.items()):
        r.write(f"  {name} {act} {kind}: {len(cmds)} — " + "; ".join(sorted(set(c[:70] for c in cmds))) + "\n")
print(open(f"{out}/report.txt").read())
PY
