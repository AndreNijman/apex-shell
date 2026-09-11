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

# The recorder is what a "terminal application" is reduced to here: it answers
# the one question that separates a terminal launch from a pipe, and it answers
# it about its own file descriptors rather than about who its parent is.
# Parentage is not usable — both paths detach, and a detached child is reparented
# to init in both cases.
cat > "$HEADLESS_W/bin/apex-probe-record" <<'REC'
#!/usr/bin/env bash
tag="$1"; shift
out="$SENTDIR/$tag"
{
    printf 'ran=1\n'
    if [ -t 0 ]; then printf 'stdin_tty=1\n'; else printf 'stdin_tty=0\n'; fi
    if [ -t 1 ]; then printf 'stdout_tty=1\n'; else printf 'stdout_tty=0\n'; fi
    printf 'term_env=%s\n' "${TERM:-}"
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
cat > "$apps/apex-probe-term.desktop" <<FIXTURE
[Desktop Entry]
Type=Application
Name=APEX terminal probe
Exec=apex-probe-record term %F
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

want_found="$(probed 'term.found')"
if [ "$want_found" = "1" ]; then ok "the Terminal=true fixture was seen by DesktopEntries"
else bad "the Terminal=true fixture was seen by DesktopEntries"; fi

if [ "$(probed 'term.runInTerminal')" = "1" ]; then
    ok "Quickshell parsed Terminal=true into runInTerminal"
else
    bad "Quickshell parsed Terminal=true into runInTerminal"
fi

if [ -f "$SENT/term" ]; then
    ok "execute() did start the program (so the entry itself is fine)"
    # THE measurement. A terminal gives its child a tty; QProcess does not.
    if [ "$(field term stdout_tty)" = "0" ]; then
        ok "execute() gave it NO terminal — the defect, still present upstream"
    else
        bad "execute() gave it NO terminal — the defect, still present upstream"
        echo "        Quickshell now appears to honour Terminal= itself."
        echo "        The shell's routing would then nest a terminal in a terminal."
        echo "        Re-measure before changing anything: this is load-bearing."
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
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
