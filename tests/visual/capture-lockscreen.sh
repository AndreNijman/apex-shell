#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# capture-lockscreen.sh OUTDIR — the real lock screen, locked over IPC inside the
# private headless compositor, typed into with wtype, and grabbed while the
# password shapes arrive, are deleted and are cleared (Escape). QA artifact.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:?usage: $0 OUTDIR}"; mkdir -p "$out"; out="$(cd "$out" && pwd)"
# shellcheck source=../lib/headless.sh
. "$root/tests/lib/headless.sh"
headless_require quickshell grim labwc wtype
headless_begin
qs_pid=""
cleanup() { [ -n "$qs_pid" ] && kill "$qs_pid" 2>/dev/null; headless_cleanup; }
trap cleanup EXIT INT TERM
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0
mkdir -p "$HOME/.cache/apex-shell"
if [ -n "${CAPTURE_PALETTE:-}" ] && [ -f "$CAPTURE_PALETTE" ]; then
    cp "$CAPTURE_PALETTE" "$HOME/.cache/apex-shell/colors.json"
else
    printf '%s' '{"background":"#171210","active":"#fab898","text":"#ece0dc","subtext":"#d6c2ba","border":"#52443e","iconFont":"#be8366"}' \
        > "$HOME/.cache/apex-shell/colors.json"
fi
if [ -n "${CAPTURE_REDUCED:-}" ]; then
    mkdir -p "$HOME/.config/apex-shell/src/user_data"
    printf '%s' '{"reduceMotion":true}' > "$HOME/.config/apex-shell/src/user_data/settings.json"
fi
log="$HEADLESS_W/shell.log"
quickshell -p "$root/shell.qml" > "$log" 2>&1 &
qs_pid=$!
for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
sleep 2
quickshell -p "$root/shell.qml" ipc call lockscreen lock >/dev/null 2>&1
sleep 1.5
crop() { grim -g "660,560 600x140" -l 0 "$out/$1.png" 2>/dev/null; }
crop 00-locked
if [ -n "${CAPTURE_FAST:-}" ]; then
    # Sustained typing, ~90 ms a key: several shapes in flight at once while
    # the centred row drifts. Grabbed between keys.
    for k in a b c d e f g h; do wtype "$k"; sleep 0.04; crop "01-fast-$k"; sleep 0.03; done
fi
for k in a b c d e f; do wtype "$k"; sleep 0.03; crop "01-type-$k-030ms"; sleep 0.25; done
crop 02-six
wtype -k BackSpace; sleep 0.04; crop 03-delete-040ms; sleep 0.3; crop 04-deleted
wtype -k Escape; sleep 0.05; crop 05-escape-050ms; sleep 0.35; crop 06-cleared
grep -E 'TypeError|ReferenceError|is not a type' "$log" | head -5
python3 "$here/contact-sheet.py" "$out" "0" "$out/sheet.png" --scale 1 --cols 3 >/dev/null && echo "sheet: $out/sheet.png"
