#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-shell-migrate-test.sh — the WHOLE shell, started on a home that still
#  has only the APEX names, keeps that home's settings.
#
#  tests/check-shell-migrate.sh proves the migration script moves a home
#  correctly. It cannot prove the script runs before the shell touches the new
#  paths, and that is the half that decides whether a user keeps anything: at
#  start the keybind service writes ~/.config/rime-shell/RimeShellKeybinds.kdl
#  and the wallpaper service saves a default when it finds no wallpaper.json.
#  Either write makes ~/.config/rime-shell exist, the migration then refuses
#  to touch ~/.config/apex-shell, and the user is on factory defaults with
#  their settings stranded beside them. shell.qml builds nothing until the
#  migration has exited; this starts the real shell.qml and grades the home it
#  leaves.
#
#  The second run saves a wallpaper under a bundled file's pre-rename name;
#  the shell has to find it under the new one and apply that.
#
#  The third is a staged copy of the tree whose shell.qml opens the gate at
#  once and runs the migration three seconds late. It must FAIL the first
#  run's assertions, which is what shows they measure the ordering.
#
#  Headless labwc from tests/lib/headless.sh, private HOME and runtime dir.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell

qs_pid=""
cleanup() {
    [ -n "$qs_pid" ] && kill "$qs_pid" 2>/dev/null
    headless_cleanup
}
trap cleanup EXIT INT TERM

headless_begin
headless_start || exit 0

pass=0
fail=0
QUIET=0
ok()  { [ "$QUIET" = 1 ] || echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { [ "$QUIET" = 1 ] || echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

is_real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
links_to() { [ -L "$1" ] && [ "$(readlink -- "$1")" = "$2" ]; }
json_is() {  # json_is FILE KEY VALUE — FILE parses and FILE[KEY] == VALUE
    python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if str(d.get(sys.argv[2])) == sys.argv[3] else 1)
PY
}

settings_old="$HOME/.config/apex-shell/src/user_data/settings.json"   # rime-rename: keep (an APEX home)
seed() {
    rm -rf "$HOME/.config/rime-shell" "$HOME/.config/apex-shell" \
           "$HOME/.cache/rime-shell" "$HOME/.cache/apex-shell" \
           "$XDG_STATE_HOME/rime-shell" "$XDG_STATE_HOME/apex-shell" \
           "$HOME/.config/hypr" "$HOME/.local/state"
    mkdir -p "$(dirname "$settings_old")" "$XDG_STATE_HOME/apex-shell"
    printf '{"cornerRadius": 23, "clockFormat": "24"}\n' > "$settings_old"
    printf '{"currentWall": "%s", "wallpaperDir": "~/Pictures/Wallpapers", "scheme": "content", "mode": "dark"}\n' \
        "$HEADLESS_WALLPAPER" > "$(dirname "$settings_old")/wallpaper.json"
    printf '{"dashboard-launcher": {"mods": "ALT", "key": "SPACE"}}\n' > "$(dirname "$settings_old")/keybinds.json"
    printf 'labwc\n' > "$XDG_STATE_HOME/apex-shell/desktop-session"
    headless_rime_palette dark "$HOME/.cache/apex-shell/colors.json"
}

# start TREE LOG — the shell from TREE, until it has been up long enough for
# the keybind and wallpaper services to have written whatever they write at
# start (both do within the first second on this harness).
start() {
    local tree="$1" log="$2"
    quickshell -p "$tree/shell.qml" >"$log" 2>&1 &
    qs_pid=$!
    local _
    for _ in $(seq 1 60); do
        grep -q "Configuration Loaded" "$log" && break
        sleep 0.25
    done
    sleep 5
    kill "$qs_pid" 2>/dev/null; wait "$qs_pid" 2>/dev/null; qs_pid=""
}

grade() {
    local log="$1"
    want "the shell loaded" grep -q "Configuration Loaded" "$log"
    want "the shell logged the move" grep -q "rime-shell-migrate: moved .*/.config/apex-shell" "$log"
    want "HOME/.config/rime-shell is a real directory" is_real_dir "$HOME/.config/rime-shell"
    want "HOME/.config/apex-shell is a symlink to it" links_to "$HOME/.config/apex-shell" rime-shell
    want "settings.json kept cornerRadius 23" \
        json_is "$HOME/.config/rime-shell/src/user_data/settings.json" cornerRadius 23
    want "settings.json kept clockFormat 24" \
        json_is "$HOME/.config/rime-shell/src/user_data/settings.json" clockFormat 24
    want "wallpaper.json still names the user's wallpaper, not a default" \
        json_is "$HOME/.config/rime-shell/src/user_data/wallpaper.json" currentWall "$HEADLESS_WALLPAPER"
    want "keybinds.json kept the user's launcher combo" \
        grep -qs '"ALT"' "$HOME/.config/rime-shell/src/user_data/keybinds.json"
    want "HOME/.cache/rime-shell is a real directory holding colors.json" \
        test -s "$HOME/.cache/rime-shell/colors.json" -a ! -L "$HOME/.cache/rime-shell"
    want "the state directory moved" test -s "$XDG_STATE_HOME/rime-shell/desktop-session"
    want "the migration left the marker the next start builds on" \
        test -s "$HOME/.config/rime-shell/.rime-shell-migrated"
}

echo "the shipped shell.qml on an APEX home"
seed
start "$root" "$HEADLESS_W/shell.log"
grade "$HEADLESS_W/shell.log"
real_pass=$pass real_fail=$fail
[ "$real_fail" -eq 0 ] || { echo "--- shell log (tail) ---"; tail -30 "$HEADLESS_W/shell.log"; }

# ── The next start ──────────────────────────────────────────────────────────
# With the marker there the gate is open from the first frame and the script
# does not run at all; the settings are simply where they now live.
echo
echo "the next start, on the migrated home"
start "$root" "$HEADLESS_W/second.log"
pass=0 fail=0
want "the shell loaded" grep -q "Configuration Loaded" "$HEADLESS_W/second.log"
want "the migration did not run again" bash -c '! grep -q "rime-shell-migrate" "$1"' _ "$HEADLESS_W/second.log"
want "settings.json still holds cornerRadius 23" \
    json_is "$HOME/.config/rime-shell/src/user_data/settings.json" cornerRadius 23
real_pass=$((real_pass + pass)) real_fail=$((real_fail + fail))

# ── A saved wallpaper the rename moved ──────────────────────────────────────
# The bundled wallpapers were apex-shell-default-N and are rime-shell-default-N
# now, so a wallpaper.json that names one points at nothing. The shell has to
# find it under the new name and apply it. (Nothing is drawn: the wallpaper
# setter and matugen are the harness's stubs, so the file is only a path here.)
echo
echo "a saved wallpaper under its pre-rename name"
seed
renamed_from="$root/src/assets/wallpapers/apex-shell-default-3.jpg"   # rime-rename: keep (a bundled wallpaper's old name)
renamed_to="$root/src/assets/wallpapers/rime-shell-default-3.jpg"
printf '{"currentWall": "%s", "wallpaperDir": "~/Pictures/Wallpapers", "scheme": "content", "mode": "dark"}\n' \
    "$renamed_from" > "$(dirname "$settings_old")/wallpaper.json"
start "$root" "$HEADLESS_W/wall.log"
pass=0 fail=0
want "the bundled wallpaper exists under its new name (fixture sanity)" test -f "$renamed_to"
want "the old name really is gone (fixture sanity)" test ! -e "$renamed_from"
want "the shell says it followed the rename" grep -q "was renamed; applying .*rime-shell-default-3.jpg" "$HEADLESS_W/wall.log"
want "wallpaper.json now names the wallpaper under its new name" \
    json_is "$HOME/.config/rime-shell/src/user_data/wallpaper.json" currentWall "$renamed_to"
real_pass=$((real_pass + pass)) real_fail=$((real_fail + fail))

# ── The late-migration mutant ───────────────────────────────────────────────
echo
echo "mutant: the gate open at once, the migration three seconds late"
tree="$HEADLESS_W/tree"
mkdir -p "$tree"
cp -a "$root/shell.qml" "$root/src" "$tree/"
perl -0pi -e 's/property bool _ready: migratedMarker\.text\(\) !== ""/property bool _ready: true/;
              s/running: !shellRoot\._ready/running: true/;
              s/command: \["bash", Quickshell\.shellDir \+ "\/src\/scripts\/rime-shell-migrate\.sh"\]/command: ["bash", "-c", "sleep 3; exec bash \\"\$0\\"", Quickshell.shellDir + "\/src\/scripts\/rime-shell-migrate.sh"]/' \
    "$tree/shell.qml"
if cmp -s "$root/shell.qml" "$tree/shell.qml" || ! grep -q '_ready: true' "$tree/shell.qml" \
   || ! grep -q 'sleep 3' "$tree/shell.qml" || ! grep -q '^ *running: true$' "$tree/shell.qml"; then
    echo "  FAIL  the mutant did not apply (shell.qml changed shape?)"
    real_fail=$((real_fail + 1))
else
    seed
    pass=0 fail=0 QUIET=1
    start "$tree" "$HEADLESS_W/mutant.log"
    grade "$HEADLESS_W/mutant.log"
    QUIET=0
    if [ "$fail" -gt 0 ]; then
        echo "  PASS  the late migration is caught ($fail assertion(s) failed on it)"
        real_pass=$((real_pass + 1))
    else
        echo "  FAIL  a migration that runs after the services went unnoticed"
        real_fail=$((real_fail + 1))
    fi
fi

echo
echo "passed=$real_pass failed=$real_fail"
[ "$real_fail" -eq 0 ]
