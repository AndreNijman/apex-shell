#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-terminal-entry-test.sh — a desktop entry that says `Terminal=true` has to
#  end up inside a terminal when the shell launches it.
#
#  ── The defect this exists for ──────────────────────────────────────────────
#  /usr/share/applications/nvim.desktop ships from the neovim rpm on every APEX
#  image and declares `Terminal=true`. `apex install neovim` correctly refuses —
#  apex-pkg skips a package whose exact NEVRA the image already provides — so
#  the user is told the editor is "provided by APEX-OS", clicks it, and nothing
#  happens. The binary was never broken. `nvim --version` exits 0 on every
#  machine checked. What was broken is the launch: nvim was started with no
#  terminal, wrote its UI to a pipe, and died.
#
#  src/services/AppLauncher.qml carried a comment saying `entry.execute()`
#  "respects Terminal=, Path= and Exec field codes". That was a claim, never a
#  measurement. This suite is the measurement, kept.
#
#  ── Why the raw call is graded too ──────────────────────────────────────────
#  The shell's routing is only correct while Quickshell's own `execute()` does
#  NOT acquire a terminal. If a future Quickshell starts honouring `Terminal=`,
#  routing on top of it opens a terminal inside a terminal, and the symptom
#  would be blamed on APEX. So the assumption the fix rests on is asserted
#  rather than assumed, and it fails loudly when upstream changes.
#
#  ── The terminal is a stub, and that is deliberate ──────────────────────────
#  The stub `xdg-terminal-exec` records its argv and then runs the command under
#  a real pty (python3's `pty.spawn`), so `[ -t 1 ]` inside the launched program
#  is the graded signal — the same signal a real foot or alacritty would give it
#  — and no window opens anywhere. Whether the shipped helper picks a sensible
#  emulator is the apex-os half's question, asserted in its
#  tests/test-apex-editors.sh; this half only asks whether the shell hands the
#  entry to it at all.
#
#  Skips cleanly (status 0) without quickshell, python3, or a compositor.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell python3

staged="$root/.terminal-entry-test.qml"
cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin

pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# ── the sentinels, the recorder, the fixtures, the terminal ──────────────────
SENT="$HEADLESS_W/sentinels"
mkdir -p "$SENT"
# Somewhere for `Path=` to point at. Both terminal fixtures carry it, so the
# suite measures whether execute() honours Path= (a claim this repo made in a
# comment for as long as the Terminal= one it got wrong) AND whether the routed
# path carries it through to the terminal.
CWD="$HEADLESS_W/probe-cwd"
mkdir -p "$CWD"

# The recorder is what a "terminal application" is reduced to here: it answers
# the one question that separates a terminal launch from a pipe, and it answers
# it about its own file descriptors rather than about who its parent is.
# Parentage is not usable — both paths detach, and a detached child is reparented
# to init in both cases.
cat > "$HEADLESS_W/bin/apex-probe-record" <<'REC'
#!/usr/bin/env bash
tag="$1"; shift
out="$SENTDIR/$tag"
# The tty tests run BEFORE the redirection, and that is the whole trick. The
# first version of this recorder asked `[ -t 1 ]` inside `{ ... } > "$out"`,
# where fd 1 is the sentinel file by construction — so it reported "no
# terminal" for every arm including the one running under a real pty, and the
# suite would have passed on a launcher that did nothing at all.
if [ -t 0 ]; then in_tty=1; else in_tty=0; fi
if [ -t 1 ]; then out_tty=1; else out_tty=0; fi
# fd 1 is duplicated to fd 9 first: a command substitution runs in a subshell
# whose OWN fd 1 is the substitution pipe, so `$(readlink /proc/self/fd/1)`
# reports "pipe:" even when the real stdout is a pty. Only the graded `[ -t 1 ]`
# above was ever right, and a diagnostic that contradicts it is worse than none.
exec 9>&1
fd1="$(readlink /proc/self/fd/9 2>/dev/null)"
{
    printf 'ran=1\n'
    printf 'stdin_tty=%s\n' "$in_tty"
    printf 'stdout_tty=%s\n' "$out_tty"
    printf 'fd1=%s\n' "$fd1"
    printf 'term_env=%s\n' "${TERM:-}"
    printf 'pwd=%s\n' "$PWD"
    printf 'argc=%s\n' "$#"
    printf 'argv=%s\n' "$*"
} > "$out.tmp" && mv "$out.tmp" "$out"
REC
chmod +x "$HEADLESS_W/bin/apex-probe-record"
export SENTDIR="$SENT"

# The terminal. Records that it was asked, then gives the command a pty.
cat > "$HEADLESS_W/bin/xdg-terminal-exec" <<'TERMSTUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$SENTDIR/helper.argv"
printf 'invocations=1\n' >> "$SENTDIR/helper.count"
exec python3 -c 'import pty,sys; sys.exit(pty.spawn(sys.argv[1:]))' "$@" >/dev/null 2>&1
TERMSTUB
chmod +x "$HEADLESS_W/bin/xdg-terminal-exec"

apps="$XDG_DATA_HOME/applications"
mkdir -p "$apps"
# `%F` is carried on purpose: the entry nvim ships has `Exec=nvim %F`, and what
# the launch path does with an unfilled field code is part of what is measured.
# THREE fixtures, not two, and the first two are identical but for their
# sentinel. One fixture served both terminal arms in the first version, so the
# routed launch overwrote the raw launch's sentinel and the suite reported that
# the routed program had never started while its terminal stub plainly had.
cat > "$apps/apex-probe-raw.desktop" <<FIXTURE
[Desktop Entry]
Type=Application
Name=APEX raw terminal probe
Exec=apex-probe-record raw %F
Path=$CWD
Terminal=true
NoDisplay=true
FIXTURE
cat > "$apps/apex-probe-term.desktop" <<FIXTURE
[Desktop Entry]
Type=Application
Name=APEX terminal probe
Exec=apex-probe-record termed %F
Path=$CWD
Terminal=true
NoDisplay=true
FIXTURE
cat > "$apps/apex-probe-plain.desktop" <<FIXTURE
[Desktop Entry]
Type=Application
Name=APEX plain probe
Exec=apex-probe-record plain
Terminal=false
NoDisplay=true
FIXTURE
export XDG_DATA_DIRS="$XDG_DATA_HOME:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# "raw" takes only the ungraded-by-the-shell measurement; "shell" also drives
# the shell's own launch path. The runner picks "shell" when the tree has one.
route="raw"
if grep -q '^singleton DesktopExec' "$root/src/services/qmldir" 2>/dev/null; then
    route="shell"
fi
export APEX_PROBE_ROUTE="$route"

headless_start || exit 0

cp "$here/terminal-entry-test.qml" "$staged"
out="$(QT_LOGGING_RULES="qml=true" timeout 90 quickshell -p "$staged" 2>&1 || true)"
grep -E '^.*PROBE ' <<<"$out" | sed 's/.*PROBE /  probe: /'

if ! grep -q 'PROBE done=1' <<<"$out"; then
    tail -25 <<<"$out"
    echo "RESULT: the probe did not run to completion"
    exit 1
fi

field() { sed -n "s/^$2=//p" "$SENT/$1" 2>/dev/null | head -n1; }
probed() { sed -n "s/.*PROBE $1=//p" <<<"$out" | head -n1; }

echo
echo "── what Quickshell's own DesktopEntry.execute() does ──"

if [ "$(probed 'raw.found')" = "1" ] && [ "$(probed 'term.found')" = "1" ]; then
    ok "the Terminal=true fixtures were seen by DesktopEntries"
else bad "the Terminal=true fixtures were seen by DesktopEntries"; fi

if [ "$(probed 'term.runInTerminal')" = "1" ]; then
    ok "Quickshell parsed Terminal=true into runInTerminal"
else
    bad "Quickshell parsed Terminal=true into runInTerminal"
fi

if [ -f "$SENT/raw" ]; then
    ok "execute() did start the program (so the entry itself is fine)"
    # THE measurement. A terminal gives its child a tty; QProcess does not.
    if [ "$(field raw stdout_tty)" = "0" ]; then
        ok "execute() gave it NO terminal — the defect, still present upstream"
    else
        bad "execute() gave it NO terminal — the defect, still present upstream"
        echo "        Quickshell now appears to honour Terminal= itself."
        echo "        The shell's routing would then nest a terminal in a terminal."
        echo "        Re-measure before changing anything: this is load-bearing."
    fi
    # Path= IS honoured by execute(), unlike Terminal=. Asserted rather than
    # believed, because believing a comment about execute() is what produced
    # this whole defect, and because the routed path below has to carry Path=
    # itself once it stops using execute().
    if [ "$(field raw pwd)" = "$CWD" ]; then
        ok "execute() DID honour Path= (so only Terminal= needs replacing)"
    else
        bad "execute() DID honour Path= (so only Terminal= needs replacing)"
        echo "        wanted $CWD, got $(field raw pwd)"
    fi
else
    bad "execute() did start the program (so the entry itself is fine)"
fi

echo
echo "── what the shell's own launch path does ──"

if [ "$route" != "shell" ]; then
    echo "  (this tree has no DesktopExec singleton yet — routing not measured)"
else
    if [ -f "$SENT/termed" ]; then
        ok "the shell's path started the Terminal=true program"
        if [ "$(field termed stdout_tty)" = "1" ]; then
            ok "and it got a terminal"
        else
            bad "and it got a terminal"
        fi
        # Routing away from execute() means Path= stops being handled for free.
        if [ "$(field termed pwd)" = "$CWD" ]; then
            ok "and Path= survived the detour through the terminal"
        else
            bad "and Path= survived the detour through the terminal"
            echo "        wanted $CWD, got $(field termed pwd)"
        fi
    else
        bad "the shell's path started the Terminal=true program"
    fi

    if [ -s "$SENT/helper.argv" ]; then
        ok "it went through xdg-terminal-exec"
        if grep -qx 'apex-probe-record' "$SENT/helper.argv"; then
            ok "the helper was handed the program as argv, not a shell string"
        else
            bad "the helper was handed the program as argv, not a shell string"
            sed 's/^/        argv: /' "$SENT/helper.argv"
        fi
        # An unfilled field code reaching the program as a literal "%F" is a
        # filename the user never typed. Whoever expands Exec must drop it.
        if grep -qx '%F' "$SENT/helper.argv"; then
            bad "the unexpanded field code %F was not passed through to the program"
        else
            ok "the unexpanded field code %F was not passed through to the program"
        fi
    else
        bad "it went through xdg-terminal-exec"
    fi

    if [ -f "$SENT/plain" ]; then
        ok "a Terminal=false entry still launches"
        if [ "$(field plain stdout_tty)" = "0" ]; then
            ok "and it was NOT wrapped in a terminal"
        else
            bad "and it was NOT wrapped in a terminal"
        fi
    else
        bad "a Terminal=false entry still launches"
    fi

    if [ "$(grep -c . "$SENT/helper.count" 2>/dev/null || echo 0)" = "1" ]; then
        ok "the terminal was asked for exactly once, by the entry that needed it"
    else
        bad "the terminal was asked for exactly once, by the entry that needed it"
    fi
fi

echo
echo "── the sentinels, as written ──"
for f in "$SENT"/*; do
    [ -f "$f" ] || continue
    printf '  %s:\n' "${f##*/}"
    sed 's/^/    /' "$f"
done

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
