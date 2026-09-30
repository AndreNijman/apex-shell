#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  desktop-launch.sh — run a desktop entry's command on the GPU its file asks for.
#
#      desktop-launch.sh <desktop-file-id> -- <argv…>
#
#  Called by src/services/DesktopExec.qml for every Terminal=false launch. The
#  argv is the entry's Exec line exactly as Quickshell already parsed it (field
#  codes stripped); the id is only used to find the file again and read one key.
#
#  ── The defect this exists for ──────────────────────────────────────────────
#  /usr/share/applications/steam.desktop declares `PrefersNonDefaultGPU=true`,
#  the freedesktop key a launcher is meant to honour by starting the program on
#  the discrete GPU. GNOME and KDE do. Quickshell 0.3.1 parses a fixed key set
#  (Name, Exec, Path, Terminal, StartupWMClass, NoDisplay, Hidden, Categories,
#  Keywords, Actions) and this is not in it, so the shell launched Steam on the
#  integrated GPU, and every game Steam started inherited that.
#
#  On katana (Iris Xe + RTX 3070) that put Terraria/tModLoader's OpenGL on the
#  Iris Xe. On 2026-09-26 it hung that GPU twice (i915 `GPU HANG: ecode
#  12:1:84dffffb`, rcs0, in dotnet), and the reset took Hyprland's context with
#  it: Hyprland aborted in CHyprOpenGLImpl::begin and came back in safe mode,
#  in daily mode and gaming mode alike. With the game on the RTX 3070, a hang
#  in the game cannot reach the compositor's GPU.
#
#  ── Why switcherooctl ───────────────────────────────────────────────────────
#  switcheroo-control is enabled on every Rime image (Containerfile.core) and
#  already publishes the right environment per GPU — on katana
#  `__GLX_VENDOR_LIBRARY_NAME=nvidia __NV_PRIME_RENDER_OFFLOAD=1
#  __VK_LAYER_NV_optimus=NVIDIA_only VK_LOADER_DRIVERS_SELECT=*nvidia*`, on an
#  AMD pair the DRI_PRIME form. Hardcoding either here would be wrong on the
#  other. `switcherooctl launch` with no --gpu picks the first discrete GPU, and
#  when there is none, or the service is unreachable, it execs the command
#  UNCHANGED (read from its source, and the single-GPU L16 runs it that way) —
#  so a one-GPU machine needs no branch here.
#
#  It takes no `--`: a first argument of `--` would be exec'd as the program.
#
#  ── Game shortcuts inherit Steam's answer ───────────────────────────────────
#  The shortcuts Steam writes for a game (`Exec=steam steam://rungameid/<id>`)
#  state no GPU at all. When Steam is not running yet, that command STARTS
#  Steam, and every game after it inherits Steam's environment. On 2026-09-30
#  katana's tModLoader shortcut did exactly that: Steam came up on the Iris Xe,
#  the game hung it twice (the same ecode) and Hyprland aborted both times. So
#  an entry that runs `steam`, or hands a `steam://` URL to anything, and says
#  nothing itself takes the answer of Steam's own entry. An entry that states
#  the key, true or false, keeps its own answer.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

id="${1:-}"
[ $# -gt 0 ] && shift
[ "${1:-}" = "--" ] && shift
if [ $# -eq 0 ]; then
    echo "desktop-launch: no command for '${id}'" >&2
    exit 2
fi

# The file behind a desktop-file id, per the XDG base-directory search order.
# An id `foo-bar` may also be `applications/foo/bar.desktop` (the spec maps
# subdirectories to dashes), so that spelling is tried second.
find_entry() {
    local want="${1%.desktop}" dir
    [ -n "$want" ] || return 1
    # One variable, then split: a literal `:` between two expansions is not a
    # split point, so `for d in ${A}:${B}` iterates once over the whole string.
    local search="${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    local IFS=:
    for dir in $search; do
        [ -n "$dir" ] || continue
        if [ -f "$dir/applications/$want.desktop" ]; then
            printf '%s\n' "$dir/applications/$want.desktop"; return 0
        fi
        if [ -f "$dir/applications/${want//-//}.desktop" ]; then
            printf '%s\n' "$dir/applications/${want//-//}.desktop"; return 0
        fi
    done
    return 1
}

# Only the [Desktop Entry] group counts: an action group may carry keys of its
# own. PrefersNonDefaultGPU is the standard key and wins when present;
# X-KDE-RunOnDiscreteGpu is the older KDE spelling some entries still use.
# Prints "true" or "false", or nothing when the file states neither key.
gpu_pref() {
    local line key val group="" std="" kde=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            '['*']') group="$line"; continue ;;
            ''|'#'*) continue ;;
        esac
        [ "$group" = "[Desktop Entry]" ] || continue
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        case "$key" in
            PrefersNonDefaultGPU)   [ -z "$std" ] && std="$val" ;;
            X-KDE-RunOnDiscreteGpu) [ -z "$kde" ] && kde="$val" ;;
        esac
    done < "$1"
    val="${std:-$kde}"
    [ -n "$val" ] || return 0
    if [ "$val" = "true" ]; then echo true; else echo false; fi
}

# The program is Steam (any path to it), or some argument is a steam:// URL
# (xdg-open, a Flatpak Steam's `flatpak run … steam://…`).
runs_steam() {
    local a
    [ "${1##*/}" = "steam" ] && return 0
    for a in "$@"; do
        case "$a" in steam://*) return 0 ;; esac
    done
    return 1
}

want=""
if file="$(find_entry "$id")"; then want="$(gpu_pref "$file")"; fi
if [ -z "$want" ] && runs_steam "$@"; then
    for steam_id in steam com.valvesoftware.Steam; do
        if file="$(find_entry "$steam_id")"; then
            want="$(gpu_pref "$file")"
            [ -n "$want" ] && break
        fi
    done
fi

if [ "$want" = "true" ] && command -v switcherooctl >/dev/null 2>&1; then
    exec switcherooctl launch "$@"
fi
exec "$@"
