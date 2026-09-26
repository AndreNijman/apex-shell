#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-desktop-launch.sh — src/scripts/desktop-launch.sh starts an entry on
#  the discrete GPU exactly when its desktop file asks, and otherwise runs the
#  command untouched.
#
#  The GPU is a stub: `switcherooctl` here records its argv and exports the one
#  variable the real one would on katana, then execs. The program is a recorder
#  that writes down its argv and whether that variable reached it. So "was it
#  offloaded" is graded on the launched process's own environment, the same
#  signal the Mesa/NVIDIA loaders read, not on which branch the script took.
#
#  No compositor, no GPU, no D-Bus. Runs anywhere bash does.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
script="${DESKTOP_LAUNCH:-$root/src/scripts/desktop-launch.sh}"

w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

mkdir -p "$w/bin" "$w/home/applications" "$w/sys/applications/vendor" "$w/out"

cat > "$w/bin/switcherooctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OUT/switcheroo.calls"
[ "$1" = "launch" ] && shift
export __NV_PRIME_RENDER_OFFLOAD=1
exec "$@"
STUB
cat > "$w/bin/probe" <<'REC'
#!/usr/bin/env bash
tag="$1"; shift
{
    printf 'prime=%s\n' "${__NV_PRIME_RENDER_OFFLOAD:-}"
    printf 'argc=%s\n' "$#"
    for a in "$@"; do printf 'arg=%s\n' "$a"; done
} > "$OUT/$tag"
REC
chmod +x "$w/bin/switcherooctl" "$w/bin/probe"

entry() {  # entry <dir> <file-id> <body…>
    local d="$1" f="$2"; shift 2
    { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=probe %s\n' "$f" "$f"
      printf '%s\n' "$@"; } > "$d/$f.desktop"
}
H="$w/home/applications"; S="$w/sys/applications"
entry "$H" wants-dgpu    'PrefersNonDefaultGPU=true'
entry "$H" says-false    'PrefersNonDefaultGPU=false'
entry "$H" no-key
entry "$H" kde-only      'X-KDE-RunOnDiscreteGpu=true'
entry "$H" std-wins      'PrefersNonDefaultGPU=false' 'X-KDE-RunOnDiscreteGpu=true'
entry "$H" spaced        'PrefersNonDefaultGPU = true  '
entry "$H" shadowed      'PrefersNonDefaultGPU=false'
entry "$S" shadowed      'PrefersNonDefaultGPU=true'
entry "$S" system-only   'PrefersNonDefaultGPU=true'
entry "$S/vendor" app    'PrefersNonDefaultGPU=true'
printf '[Desktop Entry]\r\nType=Application\r\nName=crlf\r\nExec=probe crlf\r\nPrefersNonDefaultGPU=true\r\n' \
    > "$H/crlf.desktop"
{ printf '[Desktop Entry]\nType=Application\nName=action\nExec=probe action-key\n\n'
  printf '[Desktop Action big]\nName=Big\nExec=probe x\nPrefersNonDefaultGPU=true\n'; } \
    > "$H/action-key.desktop"

run() {  # run <id> <argv…>   (PATH carries the stub)
    OUT="$w/out" PATH="$w/bin:/usr/bin:/bin" \
    XDG_DATA_HOME="$w/home" XDG_DATA_DIRS="$w/sys" \
        bash "$script" "$@"
}
prime() { sed -n 's/^prime=//p' "$w/out/$1" 2>/dev/null; }
calls() { grep -c . "$w/out/switcheroo.calls" 2>/dev/null || echo 0; }

expect() {  # expect <id> <tag> <want-prime: 1|""> <description>
    local id="$1" tag="$2" want="$3" what="$4" before
    before="$(calls)"
    run "$id" -- probe "$tag"
    if [ ! -f "$w/out/$tag" ]; then bad "$what (the program never ran)"; return; fi
    if [ "$(prime "$tag")" = "$want" ]; then ok "$what"; else
        bad "$what (prime='$(prime "$tag")', wanted '$want')"; fi
    local grew=$(( $(calls) - before ))
    if [ -n "$want" ] && [ "$grew" -ne 1 ]; then bad "$what: switcherooctl called $grew times"; fi
    if [ -z "$want" ] && [ "$grew" -ne 0 ]; then bad "$what: switcherooctl was called"; fi
}

echo "── which entries go to the discrete GPU ──"
expect wants-dgpu   wants-dgpu   1  "PrefersNonDefaultGPU=true is offloaded"
expect says-false   says-false   "" "PrefersNonDefaultGPU=false is not"
expect no-key       no-key       "" "an entry without the key is not"
expect kde-only     kde-only     1  "the older X-KDE-RunOnDiscreteGpu=true is honoured"
expect std-wins     std-wins     "" "the standard key wins over the KDE one"
expect spaced       spaced       1  "whitespace around = and after the value is ignored"
expect crlf         crlf         1  "a CRLF file is read"
expect action-key   action-key   "" "the key inside a [Desktop Action] group does not count"
expect shadowed     shadowed     "" "XDG_DATA_HOME shadows XDG_DATA_DIRS, as the spec orders it"
expect system-only  system-only  1  "an entry found only in XDG_DATA_DIRS is read"
expect vendor-app   vendor-app   1  "id vendor-app resolves to applications/vendor/app.desktop"
expect wants-dgpu.desktop dotted 1  "an id given with its .desktop suffix still resolves"
expect no-such-id   unknown      "" "an id with no file still launches, untouched"

echo
echo "── the argv arrives intact ──"
run wants-dgpu -- probe argv "a b" '$HOME' '*'
if [ "$(sed -n 's/^argc=//p' "$w/out/argv")" = "3" ] \
   && grep -qx 'arg=a b' "$w/out/argv" && grep -qx 'arg=$HOME' "$w/out/argv" \
   && grep -qx 'arg=\*' "$w/out/argv"; then
    ok "spaces, \$ and globs reach the program as-is through switcherooctl"
else bad "spaces, \$ and globs reach the program as-is through switcherooctl"; sed 's/^/        /' "$w/out/argv"; fi
if tail -n1 "$w/out/switcheroo.calls" | grep -q '^launch probe argv'; then
    ok "switcherooctl is handed 'launch <argv>' with no '--' it would exec"
else bad "switcherooctl is handed 'launch <argv>' with no '--' it would exec"; tail -n1 "$w/out/switcheroo.calls"; fi

echo
echo "── a machine without switcherooctl ──"
before="$(calls)"
OUT="$w/out" PATH="/usr/bin:/bin" XDG_DATA_HOME="$w/home" XDG_DATA_DIRS="$w/sys" \
    bash "$script" wants-dgpu -- "$w/bin/probe" nosw
if [ -f "$w/out/nosw" ] && [ -z "$(prime nosw)" ] && [ "$(calls)" = "$before" ]; then
    ok "PrefersNonDefaultGPU=true still launches, unoffloaded"
else bad "PrefersNonDefaultGPU=true still launches, unoffloaded"; fi

echo
echo "── refusals ──"
if run wants-dgpu -- 2>/dev/null; then bad "no command is refused"; else
    [ $? -eq 2 ] && ok "no command is refused with status 2" || bad "no command is refused with status 2"; fi

echo
echo "── the suite fails against a launcher that ignores the key ──"
mutant="$w/mutant.sh"
sed 's/^    exec switcherooctl launch "\$@"$/    exec "$@"/' "$script" > "$mutant"
if cmp -s "$script" "$mutant"; then
    bad "the mutation applied (the exec line moved; update the sed)"
else
    rm -f "$w/out/wants-dgpu"
    OUT="$w/out" PATH="$w/bin:/usr/bin:/bin" XDG_DATA_HOME="$w/home" XDG_DATA_DIRS="$w/sys" \
        bash "$mutant" wants-dgpu -- probe wants-dgpu
    if [ "$(prime wants-dgpu)" = "" ]; then ok "the mutant is caught by the first check"
    else bad "the mutant is caught by the first check"; fi
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
