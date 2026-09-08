#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/colour-page-test.qml — the Display page's colour section (P1-041),
#  against a FAKE display engine, twice.
#
#      ./tests/run-colour-page-test.sh
#
#  ── The engine is a fake, and it must be ────────────────────────────────────
#
#  tests/run-display-transaction-test.sh runs the real engine on purpose. This
#  suite must not, and the reason is not tidiness:
#
#    * `color-assign` writes colord's own database. A one-shot tool can only
#      create a device at `normal` scope — a `temp` device dies with the D-Bus
#      client that made it — and `colormgr delete-device` does NOT remove the
#      device-to-profile rows it leaves in /var/lib/colord/mapping.db. Measured.
#    * colord is a system D-Bus service. There is no HOME, no XDG_CONFIG_HOME
#      and no PATH that isolates it. A suite that ran the real verb would
#      quietly accumulate assignments in the developer's colour database and
#      leave them there.
#
#  So the engine here is a script in a scratch directory that records its argv
#  and answers from a fixture, and every assertion is about what the shell
#  ASKED FOR. Nothing in this file can reach colormgr.
#
#  ── Two engines, because the shell has to survive the older one ─────────────
#
#  The shell and the OS image land independently and this page ships first. The
#  engine's argparse keeps its verbs in a `choices` list, so an engine that
#  predates them answers `color` with exit 2 and "invalid choice". The shell
#  therefore probes `--help`, and the legacy phase's central assertion is a
#  negative: the call log must contain no colour verb at all.
#
#      modern   --help lists the verbs; `color` prints the fixture
#      legacy   --help lists neither;   `color` exits 2, as argparse does
#
#  ── It brings its own compositor and its own machine ────────────────────────
#
#  Always, not "if there is no WAYLAND_DISPLAY": quickshell needs a compositor,
#  and nesting inside the developer's session puts this one mistake away from
#  drawing on his desktop. A headless wlroots compositor in a private
#  XDG_RUNTIME_DIR, with WAYLAND_DISPLAY and DISPLAY unset, and a scratch HOME.
#  The QML opens no window.
#
#  Skips cleanly (status 0) without quickshell, a wlroots compositor, or python3.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

for tool in quickshell python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 0; }
done

comp=""
for c in labwc sway; do
    command -v "$c" >/dev/null 2>&1 && { comp="$c"; break; }
done
[[ -n "$comp" ]] || { echo "SKIP: no wlroots compositor (labwc or sway) to host the test"; exit 0; }

W="$(mktemp -d)"
staged="$root/.colour-page-test.qml"
comp_pid=""
cleanup() {
    [[ -n "$comp_pid" ]] && kill "$comp_pid" 2>/dev/null
    sleep 0.2
    [[ -n "$comp_pid" ]] && kill -9 "$comp_pid" 2>/dev/null
    rm -f "$staged"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

# Quickshell refuses to import QML modules from outside the directory holding
# the entry point, so the suite is staged into the repository root.
cp "$here/colour-page-test.qml" "$staged"

# ── The fixture ──────────────────────────────────────────────────────────────
# The reason is written to its own file and inserted into the JSON from there,
# so "carried byte for byte" is a claim about the transport rather than about
# whether two string literals in this repository still match.
#
# It is the sentence the real engine composes when no ICC loader is installed
# and the compositor's gamma LUT is the one the night light writes — which is
# every APEX build measured so far, on labwc, sway and niri.
printf %s 'no ICC curve loader is installed (xcalib, argyll'"'"'s dispwin and wl-gammactl are all absent), so an assigned profile'"'"'s vcgt is stored and reported but not pushed into the hardware; and on this compositor the gamma LUT is the same slot the night light writes, so a curve and a night light cannot both be active' \
    > "$W/reason.txt"

mkdir -p "$W/engine"
python3 - "$W/reason.txt" "$W/colour.json" <<'GEN'
import json, sys

reason = open(sys.argv[1]).read()

def prof(pid, title, base, vcgt):
    return {"id": pid, "title": title,
            "filename": "/usr/share/color/icc/colord/%s.icc" % base,
            "kind": "display-device", "vcgt": vcgt}

# Six display profiles, shaped like the image's own set: one with a real gamma
# table (Bluish is the only one of the seven that has one), one whose file
# cannot be parsed at all — `null`, which is deliberately a THIRD answer from
# `false`, because "there is no calibration in this file" and "I cannot read
# this file" are opposite things to tell someone about their monitor profile.
profiles = [
    prof("prof-srgb",     "sRGB",         "sRGB",         False),
    prof("prof-adobe",    "AdobeRGB1998", "AdobeRGB1998", False),
    prof("prof-bluish",   "Bluish",       "Bluish",       True),
    prof("prof-rec709",   "Rec709",       "Rec709",       False),
    prof("prof-prophoto", "ProPhotoRGB",  "ProPhotoRGB",  False),
    prof("prof-broken",   "Unreadable",   "Unreadable",   None),
]

state = {
    "compositor": "labwc",
    "colord": {"available": True, "registered": 0},
    "profiles": profiles,
    "outputs": [
        # The developer's own panel, as measured: LEN MNG007QT1-2, one CTA-861
        # extension block with no HDR static metadata block and no colorimetry
        # block, and NO serial in its EDID — so its device id is make and model
        # only.
        {"name": "eDP-1", "device": "apex-display-LEN-MNG007QT1-2",
         "make": "LEN", "model": "MNG007QT1-2", "serial": None,
         "hdr": {"edid": True, "static_metadata": False,
                 "colorimetry": False, "eotf": None},
         "profile": profiles[0]},
        # And a desk monitor that does advertise HDR, so the verdict is proven
        # to be per output and read from that output's own EDID.
        {"name": "DP-2", "device": "apex-display-DEL-U2723QE-7NKM3T3",
         "make": "DEL", "model": "U2723QE", "serial": "7NKM3T3",
         "hdr": {"edid": True, "static_metadata": True,
                 "colorimetry": True, "eotf": 6},
         "profile": None},
    ],
    "curve": {"loader": None, "lut_shared_with_night_light": True,
              "reason": reason},
}
json.dump(state, open(sys.argv[2], "w"), indent=2)
GEN
[[ -s "$W/colour.json" ]] || { echo "FAIL: the colour fixture was not generated"; exit 1; }

# ── The fake engines ─────────────────────────────────────────────────────────
# Deliberately NOT in a directory that goes on PATH: nothing may pick this up
# as `apex-display-apply` by accident, and the only way to reach it is the
# APEX_DISPLAY_ENGINE the shell is handed.
#
# `color` re-reads the assignment state each time it is asked, so the readback
# after an assign is a real readback — a fake that answered the same JSON twice
# would let an optimistic page pass.
cat > "$W/engine/modern" <<MODERN
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/calls.log"
case "\${1:-list}" in
    --help|-h)
        cat <<'HELP'
usage: apex-display-apply [-h] [--model MODEL] [--dry-run] [--no-persist]
                          [--self-test]
                          [{list,apply,save,compositor,color,color-assign}]
                          [rest ...]

positional arguments:
  {list,apply,save,compositor,color,color-assign}
  rest                  OUTPUT PROFILE, for color-assign
HELP
        exit 0 ;;
    list)
        printf '[]\n'; exit 0 ;;
    color)
        python3 "$W/engine/render.py" "$W/colour.json" "$W/assigned"; exit 0 ;;
    color-assign)
        out="\${2:-}"; want="\${3:-}"
        title="\$(python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))
print(next((p["title"] for p in s["profiles"] if p["id"]==sys.argv[2]), ""))' "$W/colour.json" "\$want")"
        if [ -z "\$title" ]; then
            printf 'apex-display: no colord profile matches %s\n' "\$want" >&2
            exit 1
        fi
        printf '%s\t%s\n' "\$out" "\$want" >> "$W/assigned"
        printf 'apex-display: %s is now the profile for %s\n' "\$title" "\$out" >&2
        vcgt="\$(python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))
print(next((repr(p["vcgt"]) for p in s["profiles"] if p["id"]==sys.argv[2]), ""))' "$W/colour.json" "\$want")"
        if [ "\$vcgt" = "False" ]; then
            printf 'apex-display: this profile carries no vcgt, so there is no curve to load even where one could be\n' >&2
        fi
        exit 0 ;;
esac
exit 0
MODERN

# The engine as it shipped before the colour verbs: argparse's own answer to a
# choice it does not have. Reproduced exactly, exit code and wording, because
# the shell's probe exists to avoid provoking it.
cat > "$W/engine/legacy" <<LEGACY
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/calls.log"
case "\${1:-list}" in
    --help|-h)
        cat <<'HELP'
usage: apex-display-apply [-h] [--model MODEL] [--dry-run] [--no-persist]
                          [--self-test] [{list,apply,save,compositor}] [rest ...]

positional arguments:
  {list,apply,save,compositor}
HELP
        exit 0 ;;
    list)
        printf '[]\n'; exit 0 ;;
    color|color-assign)
        printf "usage: apex-display-apply [-h] [--model MODEL] [--dry-run]\n" >&2
        printf "apex-display-apply: error: argument action: invalid choice: '%s'\n" "\$1" >&2
        exit 2 ;;
esac
exit 0
LEGACY

cat > "$W/engine/render.py" <<'RENDER'
import json, sys
state = json.load(open(sys.argv[1]))
by_id = {p["id"]: p for p in state["profiles"]}
try:
    for line in open(sys.argv[2]):
        name, _, pid = line.rstrip("\n").partition("\t")
        for o in state["outputs"]:
            if o["name"] == name and pid in by_id:
                o["profile"] = by_id[pid]
except FileNotFoundError:
    pass
json.dump(state, sys.stdout, indent=2)
RENDER
chmod +x "$W/engine/modern" "$W/engine/legacy"

# ── The scratch machine ──────────────────────────────────────────────────────
# Every service the Display page pulls in shells out to something. Left alone
# they would interrogate — and the Appearance page could write to — the
# developer's own machine, so anything a page runs answers empty from here.
mkdir -p "$W/bin"
cat > "$W/bin/_stub" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *--json*|*json*) echo "{}" ;;
    *)               : ;;
esac
exit 0
FAKE
chmod +x "$W/bin/_stub"
# colormgr among them, and named first: if any path in this suite ever reaches
# for the real colour daemon, it finds a stub that says nothing instead.
for n in colormgr apex hyprctl wlr-randr niri matugen xdg-open playerctl \
         wpctl brightnessctl pkcheck notify-send swww kanshi gammastep \
         hyprsunset; do
    ln -sf "$W/bin/_stub" "$W/bin/$n"
done
cat > "$W/bin/git" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
    *describe*) echo "v0.0.0-test" ;;
    *)          : ;;
esac
exit 0
FAKE
chmod +x "$W/bin/git"
export PATH="$W/bin:$PATH"

real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
export HOME="$W/home"
export XDG_CONFIG_HOME="$W/home/.config"
export XDG_STATE_HOME="$W/state"
export XDG_CACHE_HOME="$W/cache"
mkdir -p "$HOME/.config/apex-shell/src/user_data" "$HOME/.local/share" \
         "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$HOME/Pictures/Wallpapers"
ln -sfn "$real_home/.local/share/fonts" "$HOME/.local/share/fonts" 2>/dev/null

# ── The compositor ───────────────────────────────────────────────────────────
export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
unset WAYLAND_DISPLAY
unset DISPLAY
unset HYPRLAND_INSTANCE_SIGNATURE
unset NIRI_SOCKET
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER=pixman
export WLR_HEADLESS_OUTPUTS=1
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland

case "$comp" in
    labwc)
        mkdir -p "$W/labwc/labwc"
        cp "$here/labwc-test-rc.xml" "$W/labwc/labwc/rc.xml" 2>/dev/null || true
        XDG_CONFIG_HOME="$W/labwc" "$comp" > "$W/comp.log" 2>&1 &
        ;;
    sway)
        printf 'output HEADLESS-1 mode 1920x1080\n' > "$W/sway.cfg"
        "$comp" -c "$W/sway.cfg" > "$W/comp.log" 2>&1 &
        ;;
esac
comp_pid=$!

sock=""
for _ in $(seq 1 60); do
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
        [[ -S "$f" ]] || continue
        sock="$(basename "$f")"
        break
    done
    [[ -n "$sock" ]] && break
    sleep 0.25
done
[[ -n "$sock" ]] || {
    echo "SKIP: $comp did not come up headless"; tail -5 "$W/comp.log"; exit 0; }
export WAYLAND_DISPLAY="$sock"

[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || {
    echo "FAIL: WAYLAND_DISPLAY does not name a socket in the private runtime dir"
    exit 1; }

echo "host: $comp on $WAYLAND_DISPLAY (headless, private XDG_RUNTIME_DIR)"
echo "home: $HOME"
echo "engine: a fake in $W/engine — nothing here can reach colormgr"

pass=0
fail=0

# phase <modern|legacy> <floor> — run the suite against one engine.
phase() {
    local name="$1" floor="$2"
    : > "$W/calls.log"
    rm -f "$W/assigned"
    echo
    echo "── $name ──"

    local log="$W/$name.log"
    ( cd "$root" && env \
        APEX_DISPLAY_ENGINE="$W/engine/$name" \
        APEX_DISPLAY_TXN_DIR="$W/txn-$name" \
        APEX_COLOUR_PHASE="$name" \
        APEX_COLOUR_CALLS="$W/calls.log" \
        APEX_COLOUR_REASON="$W/reason.txt" \
        QT_LOGGING_RULES="qml=true" \
        timeout 180 quickshell -p "$staged" ) >"$log" 2>&1

    sed -i -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //' "$log"
    grep -E "^(  PASS|  FAIL|\[colour-page\])" "$log" || true

    if grep -qE "is not a type|Cannot assign|Unable to assign|Failed to load configuration" "$log"; then
        grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration" "$log" | head -10
        echo "  FAIL  the page failed to build in the $name phase"
        fail=$((fail + 1))
        return
    fi

    local summary
    summary="$(grep -o 'passed=[0-9]* failed=[0-9]*' "$log" | tail -1)"
    if [[ -z "$summary" ]]; then
        tail -25 "$log" | sed 's/^/        /'
        echo "  FAIL  the $name phase never reached its summary"
        fail=$((fail + 1))
        return
    fi
    local p f
    p="${summary#*passed=}"; p="${p%% *}"
    f="${summary##*failed=}"
    pass=$((pass + p))
    fail=$((fail + f))

    # A phase that stopped early reports green with its assertions unrun, which
    # is the failure this repository has shipped before.
    if [[ "$p" -lt "$floor" ]]; then
        echo "  FAIL  only $p assertions ran in the $name phase (wanted $floor+)"
        fail=$((fail + 1))
    fi
}

phase modern 28
phase legacy 8

# ── The fake was never allowed near the real daemon ──────────────────────────
# Belt and braces, and cheap: the whole reason for the fake is that a real
# `color-assign` would leave rows in the developer's colour database.
if grep -q "colormgr" "$W/calls.log" 2>/dev/null; then
    echo "  FAIL  the suite reached for colormgr"
    fail=$((fail + 1))
else
    echo "  PASS  no path in the suite reached colormgr"
    pass=$((pass + 1))
fi

echo
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
