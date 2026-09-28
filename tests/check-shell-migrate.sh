#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-shell-migrate.sh — src/scripts/rime-shell-migrate.sh against fixture
#  homes, and against mutants of itself.
#
#  ── What is at stake ────────────────────────────────────────────────────────
#  The rename moved the shell's user data from ~/.config/apex-shell,
#  ~/.cache/apex-shell and ~/.local/state/apex-shell to the rime-shell names.
#  A machine booting its first Rime image holds all of it under the old names,
#  and the migration is the only thing standing between that user and a shell
#  on factory defaults. So every rule in the script's header is a case here,
#  run on a throwaway HOME, and graded on the tree the run leaves behind —
#  never on what the script printed.
#
#  ── Why the mutants ─────────────────────────────────────────────────────────
#  A check that passes on a broken migration is worse than none. Each mutant
#  below is one plausible way to write this script wrongly (copy instead of
#  rename, forget the symlink, move over a directory that already exists,
#  "repair" a dangling link by moving it into place, skip the niri files), and
#  the cases must fail on every one of them.
#
#  Nothing here touches the real HOME: every run is `env -i HOME=<fixture>`.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
script="$root/src/scripts/rime-shell-migrate.sh"

pass=0
fail=0
QUIET=0
ok()  { [ "$QUIET" = 1 ] || echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { [ "$QUIET" = 1 ] || echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

[ -s "$script" ] || { echo "  FAIL  $script is missing"; echo; echo "passed=0 failed=1"; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/check-shell-migrate.XXXXXX")"
cleanup() { chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT INT TERM

# run SCRIPT HOME [args…] — the migration with nothing of this shell's
# environment in it. Its exit code lands in $rc and its output in the files
# $out and $err. Never call it in $(…): the assignments would die with the
# subshell and every assertion on $out would be graded against nothing.
out="$work/out" err="$work/err" rc=""
run() {
    local s="$1" h="$2"; shift 2
    env -i PATH="$PATH" HOME="$h" ${XDG_STATE_HOME_FIX:+XDG_STATE_HOME="$XDG_STATE_HOME_FIX"} \
        bash "$s" "$@" >"$out" 2>"$err"
    rc=$?
}

inode() { stat -c %i -- "$1" 2>/dev/null; }
is_real_dir()  { [ -d "$1" ] && [ ! -L "$1" ]; }
is_real_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
links_to() { [ -L "$1" ] && [ "$(readlink -- "$1")" = "$2" ]; }
holds() { [ "$(cat -- "$1" 2>/dev/null)" = "$2" ]; }
# listing DIR — every path, its type and its link target, sorted.
listing() { (cd "$1" && find . -printf '%y %p %l\n' | sort); }

# An APEX user's home, as the old shell left it.
seed_apex_home() {
    local h="$1"
    mkdir -p "$h/.config/apex-shell/src/user_data" "$h/.config/apex-shell/plugins/clock" \
             "$h/.cache/apex-shell" "$h/.local/state/apex-shell" \
             "$h/.config/hypr" "$h/.config/ghostty" "$h/.config/niri"
    printf '{"uiScale":1.37}\n'                  > "$h/.config/apex-shell/src/user_data/settings.json"
    printf '{"currentWall":"/w/mine.jpg"}\n'     > "$h/.config/apex-shell/src/user_data/wallpaper.json"
    printf '{"configProvider":"lua"}\n'          > "$h/.config/apex-shell/src/user_data/config_Provider.json"
    printf '{"launcher":{"mods":"ALT"}}\n'       > "$h/.config/apex-shell/src/user_data/keybinds.json"
    printf '{"id":"clock"}\n'                    > "$h/.config/apex-shell/plugins/clock/plugin.json"
    printf 'binds-kdl\n'                         > "$h/.config/apex-shell/ApexShellKeybinds.kdl"
    printf 'input-kdl\n'                         > "$h/.config/apex-shell/ApexShellInput.kdl"
    printf '{"accent":"#123456"}\n'              > "$h/.cache/apex-shell/colors.json"
    printf 'hyprland\n'                          > "$h/.local/state/apex-shell/desktop-session"
    printf 'col.active_border = 0xff123456\n'    > "$h/.config/hypr/apex-shell-colors.conf"
    printf 'palette = 0=#123456\n'               > "$h/.config/ghostty/apex-shell-colors"
    # What a user's own niri config names: the OLD absolute path.
    printf 'include "%s"\n' "$h/.config/apex-shell/ApexShellKeybinds.kdl" > "$h/.config/niri/config.kdl"
}

# suite SCRIPT — every case. Returns through $fail.
suite() {
    local s="$1" h ino before after

    # ── 1. A home from APEX moves, whole, by rename ─────────────────────────
    h="$work/h1"; rm -rf "$h"; mkdir -p "$h"; seed_apex_home "$h"
    ino="$(inode "$h/.config/apex-shell")"
    run "$s" "$h"
    want "an APEX home: the migration exits 0" test "$rc" = 0
    want "HOME/.config/rime-shell is a real directory" is_real_dir "$h/.config/rime-shell"
    want "HOME/.config/apex-shell is left as a symlink to rime-shell" links_to "$h/.config/apex-shell" rime-shell
    want "it is the same directory, renamed and not copied (inode kept)" \
        test "$(inode "$h/.config/rime-shell")" = "$ino"
    want "settings.json arrives intact" holds "$h/.config/rime-shell/src/user_data/settings.json" '{"uiScale":1.37}'
    want "wallpaper.json arrives intact" holds "$h/.config/rime-shell/src/user_data/wallpaper.json" '{"currentWall":"/w/mine.jpg"}'
    want "keybinds.json arrives intact" holds "$h/.config/rime-shell/src/user_data/keybinds.json" '{"launcher":{"mods":"ALT"}}'
    want "an installed plugin arrives intact" holds "$h/.config/rime-shell/plugins/clock/plugin.json" '{"id":"clock"}'
    want "HOME/.cache/rime-shell is real and holds colors.json" holds "$h/.cache/rime-shell/colors.json" '{"accent":"#123456"}'
    want "HOME/.cache/apex-shell is a symlink to rime-shell" links_to "$h/.cache/apex-shell" rime-shell
    want "the state directory moves too" holds "$h/.local/state/rime-shell/desktop-session" hyprland
    want "HOME/.local/state/apex-shell is a symlink to rime-shell" links_to "$h/.local/state/apex-shell" rime-shell
    want "ApexShellKeybinds.kdl becomes RimeShellKeybinds.kdl" is_real_file "$h/.config/rime-shell/RimeShellKeybinds.kdl"
    want "  with its content" holds "$h/.config/rime-shell/RimeShellKeybinds.kdl" binds-kdl
    want "  and a symlink at the old name" links_to "$h/.config/rime-shell/ApexShellKeybinds.kdl" RimeShellKeybinds.kdl
    want "ApexShellInput.kdl becomes RimeShellInput.kdl" holds "$h/.config/rime-shell/RimeShellInput.kdl" input-kdl
    want "a niri include of the OLD absolute path still reads the keybinds" \
        holds "$(sed -n 's/^include "\(.*\)"$/\1/p' "$h/.config/niri/config.kdl")" binds-kdl
    want "the Hyprland colour output moves, with a symlink at the old name" \
        links_to "$h/.config/hypr/apex-shell-colors.conf" rime-shell-colors.conf
    want "  and its content" holds "$h/.config/hypr/rime-shell-colors.conf" 'col.active_border = 0xff123456'
    want "the ghostty colour output moves, with a symlink at the old name" \
        links_to "$h/.config/ghostty/apex-shell-colors" rime-shell-colors
    want "stdout says what moved" grep -q 'moved .*/.config/apex-shell -> .*/.config/rime-shell' "$out"
    want "a clean migration writes nothing to stderr" test ! -s "$err"

    # ── 2. Running it again changes nothing ─────────────────────────────────
    before="$(listing "$h")"
    run "$s" "$h"
    want "a second run exits 0" test "$rc" = 0
    after="$(listing "$h")"
    want "a second run leaves the tree exactly as the first did" test "$before" = "$after"
    want "a second run prints nothing" test ! -s "$out" -a ! -s "$err"

    # ── 3. Both exist: nothing is touched ───────────────────────────────────
    h="$work/h3"; rm -rf "$h"; mkdir -p "$h"; seed_apex_home "$h"
    mkdir -p "$h/.config/rime-shell/src/user_data"
    printf '{"uiScale":1}\n' > "$h/.config/rime-shell/src/user_data/settings.json"
    run "$s" "$h"
    want "new dir already there: the old one stays a real directory" is_real_dir "$h/.config/apex-shell"
    want "  with its settings" holds "$h/.config/apex-shell/src/user_data/settings.json" '{"uiScale":1.37}'
    want "  and the new one keeps its own" holds "$h/.config/rime-shell/src/user_data/settings.json" '{"uiScale":1}'
    want "  and stderr names the conflict" grep -q 'conflict: both .*/.config/apex-shell and .*/.config/rime-shell exist' "$err"

    h="$work/h3b"; rm -rf "$h"; mkdir -p "$h"; seed_apex_home "$h"
    mkdir -p "$h/.config/rime-shell"
    run "$s" "$h"
    want "an EMPTY new directory is not replaced either (rename(2) would)" is_real_dir "$h/.config/apex-shell"
    want "  and the old settings stay where they were" \
        holds "$h/.config/apex-shell/src/user_data/settings.json" '{"uiScale":1.37}'
    want "  and the new directory is still empty" test -z "$(ls -A "$h/.config/rime-shell")"

    # ── 4. Our own link, dangling: the new directory was deleted on purpose ─
    h="$work/h4"; rm -rf "$h"; mkdir -p "$h/.config"
    ln -s rime-shell "$h/.config/apex-shell"
    run "$s" "$h"
    want "a dangling apex-shell -> rime-shell link is left as it is" links_to "$h/.config/apex-shell" rime-shell
    want "  and no rime-shell is conjured from it" test ! -e "$h/.config/rime-shell" -a ! -L "$h/.config/rime-shell"

    # ── 5. Someone's own link (a dotfiles checkout) ─────────────────────────
    h="$work/h5"; rm -rf "$h"; mkdir -p "$h/.config" "$h/dotfiles/shell-conf/src/user_data"
    printf '{"uiScale":2}\n' > "$h/dotfiles/shell-conf/src/user_data/settings.json"
    ln -s ../dotfiles/shell-conf "$h/.config/apex-shell"
    run "$s" "$h"
    want "a user's own apex-shell link is left pointing where it did" links_to "$h/.config/apex-shell" ../dotfiles/shell-conf
    want "  and rime-shell points at the same place" links_to "$h/.config/rime-shell" ../dotfiles/shell-conf
    want "  so the settings are found under the new name" holds "$h/.config/rime-shell/src/user_data/settings.json" '{"uiScale":2}'

    # ── 6. Files in an already-moved directory, and niri's empty placeholders ─
    h="$work/h6"; rm -rf "$h"; mkdir -p "$h/.config/rime-shell"
    printf 'input-kdl\n' > "$h/.config/rime-shell/ApexShellInput.kdl"
    : > "$h/.config/rime-shell/RimeShellInput.kdl"
    printf 'old-binds\n' > "$h/.config/rime-shell/ApexShellKeybinds.kdl"
    printf 'new-binds\n' > "$h/.config/rime-shell/RimeShellKeybinds.kdl"
    run "$s" "$h"
    want "an empty RimeShellInput.kdl placeholder gives way to the real file" \
        holds "$h/.config/rime-shell/RimeShellInput.kdl" input-kdl
    want "  and the old name becomes a symlink to it" links_to "$h/.config/rime-shell/ApexShellInput.kdl" RimeShellInput.kdl
    want "a NON-empty RimeShellKeybinds.kdl is not overwritten" holds "$h/.config/rime-shell/RimeShellKeybinds.kdl" new-binds
    want "  and the old file is left as it was" holds "$h/.config/rime-shell/ApexShellKeybinds.kdl" old-binds

    # ── 7. A fresh install has nothing to move and gets nothing made ────────
    h="$work/h7"; rm -rf "$h"; mkdir -p "$h"
    run "$s" "$h"
    want "a fresh home: exit 0" test "$rc" = 0
    want "  and no directory is created" test -z "$(ls -A "$h")"

    # ── 8. XDG_STATE_HOME decides where state lives ─────────────────────────
    h="$work/h8"; rm -rf "$h"; mkdir -p "$h/st/apex-shell"
    printf 'niri\n' > "$h/st/apex-shell/desktop-session"
    XDG_STATE_HOME_FIX="$h/st" run "$s" "$h"
    want "state under XDG_STATE_HOME moves" holds "$h/st/rime-shell/desktop-session" niri
    want "  and leaves a symlink" links_to "$h/st/apex-shell" rime-shell

    # ── 9. A read-only ~/.config: nothing lost, still exit 0 ────────────────
    if [ "$(id -u)" != 0 ]; then
        h="$work/h9"; rm -rf "$h"; mkdir -p "$h"; seed_apex_home "$h"
        chmod a-w "$h/.config"
        run "$s" "$h"
        want "read-only .config: exit 0" test "$rc" = 0
        want "  the old directory is untouched" \
            holds "$h/.config/apex-shell/src/user_data/settings.json" '{"uiScale":1.37}'
        want "  and stderr says it could not move it" grep -q 'could not move\|appeared while' "$err"
        chmod u+w "$h/.config"
    fi

    # ── 10. --dry-run moves nothing ─────────────────────────────────────────
    h="$work/h10"; rm -rf "$h"; mkdir -p "$h"; seed_apex_home "$h"
    before="$(listing "$h")"
    run "$s" "$h" --dry-run
    want "--dry-run changes nothing" test "$before" = "$(listing "$h")"
    want "  and lists what it would do, the niri files included" grep -q 'would move .*ApexShellKeybinds.kdl' "$out"

    # ── 11. No HOME ─────────────────────────────────────────────────────────
    want "with no HOME it exits 0" test "$(env -i PATH="$PATH" bash "$s" >/dev/null 2>&1; echo $?)" = 0
}

echo "rime-shell-migrate.sh"
suite "$script"
real_pass=$pass real_fail=$fail

# ── Mutants: each must break at least one case ──────────────────────────────
mutate() {
    local name="$1" expr="$2" m="$work/mutant.sh"
    perl -0pe "$expr" "$script" > "$m"
    if cmp -s "$script" "$m"; then
        echo "  FAIL  mutant '$name' did not change the script (stale pattern)"
        real_fail=$((real_fail + 1)); return
    fi
    pass=0 fail=0 QUIET=1
    suite "$m"
    QUIET=0
    if [ "$fail" -gt 0 ]; then
        echo "  PASS  mutant caught: $name ($fail case(s) failed)"
        real_pass=$((real_pass + 1))
    else
        echo "  FAIL  mutant NOT caught: $name"
        real_fail=$((real_fail + 1))
    fi
}
echo
echo "mutants"
mutate "copies instead of renaming" 's/mv -n -T -- "\$old" "\$new" 2>\/dev\/null/cp -a -- "\$old" "\$new"/'
mutate "leaves no symlink at the old path" 's/if ln -s -- "\$target" "\$old" 2>\/dev\/null; then/if true; then/'
mutate "moves even when the new path exists" 's/if \[ -e "\$new" \] \|\| \[ -L "\$new" \]; then/if false; then/; s/mv -n -T/mv -T/'
mutate "moves a dangling link into place" 's/    if \[ -L "\$old" \]; then\n/    if false; then\n/; s/\[ -e "\$old" \] \|\| return 0/[ -e "\$old" ] || [ -L "\$old" ] || return 0/; s/\[ "\$kind" = dir \] && \[ ! -d "\$old" \]/false/'
mutate "skips the files named for the old shell" 's/for base in Keybinds\.kdl Input\.kdl Keybinds\.conf Keybinds\.lua; do/for base in; do/'
mutate "overwrites a non-empty new file" 's/\[ ! -s "\$new" \]/true/'
mutate "ignores XDG_STATE_HOME" 's/\$\{XDG_STATE_HOME:-\$\{HOME\}\/\.local\/state\}/\${HOME}\/.local\/state/'
mutate "does not follow a user's own link" 's/elif ln -s -- "\$\(readlink -- "\$old"\)" "\$new" 2>\/dev\/null; then/elif false; then/'

echo
echo "passed=$real_pass failed=$real_fail"
[ "$real_fail" -eq 0 ]
