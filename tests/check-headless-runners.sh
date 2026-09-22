#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-headless-runners.sh — no suite in here may open a window on the
#  display it inherited.
#
#  ── Why this check exists ───────────────────────────────────────────────────
#  Twelve runners in tests/ started quickshell, a compositor, or the whole shell
#  on whatever WAYLAND_DISPLAY they inherited. On a build box that is nothing.
#  On the machine somebody is working at, it is a window — or twenty windows, or
#  a second compositor — landing on top of them, and run-nested-labwc.sh said so
#  in its own first line: "nested inside the current Wayland session".
#
#  The repair was tests/lib/headless.sh. This file is the part that keeps the
#  repair. A runner that CAN reach the ambient display eventually does: someone
#  adds a suite by copying the one next to it, and if the one next to it fell
#  back to the inherited display on a machine with no compositor, so does the
#  copy. The fallback is the bug. Nothing here is advisory.
#
#  ── It checks the invariant, not the library ────────────────────────────────
#  "Did you source lib/headless.sh" would be the easy check and the wrong one.
#  Eight suites — run-nav-geometry-test.sh, run-settings-pages-test.sh,
#  run-settings-staged-test.sh, run-agent-settings-test.sh,
#  run-agent-state-render-test.sh, run-input-settings-test.sh,
#  run-display-unplug-test.sh and run-display-transaction-test.sh — were
#  already correct before the library existed and bring their own headless
#  compositor inline. They pass here on their own merits, and a future runner
#  that does something smarter than the library must be able to as well. Each
#  is named in its own assertion below, so a rule that came to recognise only
#  lib/headless.sh could not quietly stop checking them.
#
#  ── The four rules ──────────────────────────────────────────────────────────
#  Applied to comment-, quote- and heredoc-stripped source, in file order,
#  because order is the whole point: a neutralisation after the launch it was
#  meant to protect is decoration.
#
#    A. Every launch of a graphical client is covered one of two ways. Either
#       the script has already unset WAYLAND_DISPLAY out of its own environment
#       (a bare `unset`, or `headless_begin`, or the
#       `headless_require_nested_optin` gate, which exits instead), or the
#       launch itself carries the neutralisation — `env -u WAYLAND_DISPLAY …`,
#       or a `WAYLAND_DISPLAY=…` prefix naming a socket the script made.
#
#    B. Nothing reads $WAYLAND_DISPLAY before neutralising it. Before the unset
#       that variable IS the ambient session, so reading it is reaching for the
#       desk even when the value is only used to decide whether to skip. This
#       is the rule that catches the old
#       `[[ -z "${WAYLAND_DISPLAY:-}" ]] && SKIP` opening, which is how a
#       runner concludes it may use somebody's session.
#
#    C. Outside tests/lib/, nothing names HEADLESS_AMBIENT_DISPLAY,
#       HEADLESS_AMBIENT_RUNTIME or HEADLESS_AMBIENT_SIG. The library records
#       those so it can REFUSE; a runner reading one is asking for the value the
#       refusal exists to keep away from it.
#
#    D. Nothing supplies a fallback for WAYLAND_DISPLAY, or writes a display
#       name into it. `${WAYLAND_DISPLAY:-wayland-1}` after the unset satisfies
#       A, B and C — the launch is covered, the read is not early, no ambient
#       variable is named — and still lands the run on wayland-1, which on this
#       machine is somebody's session. Rule D was added because that exact
#       mutation was written by hand against run-popup-smoke.sh and the first
#       three rules passed it. Suites behind `headless_require_nested_optin`
#       are exempt: consulting the session they nest in is the whole of what
#       the gate asks permission for.
#
#  Rule A is why the scan has to be quote- and heredoc-aware rather than a
#  grep. tests/check-compositor-backends.sh contains the line
#  `COMPOSITORS=(hyprland niri labwc)` and check-keybind-lua.sh the string
#  "the Hyprland artifact is …". Neither launches anything. A grep for the word
#  flags both, and a check with two standing false positives is one somebody
#  turns off.
#
#  ── What it does NOT do ─────────────────────────────────────────────────────
#  It reads the source; it does not run it. A script that computes a compositor
#  name at runtime and execs it through a variable is invisible here, and so is
#  one that reaches the session through a helper this repository does not own.
#  The rules bound the mistake this tree has made twelve times — a client
#  started on an inherited WAYLAND_DISPLAY — and claiming more than that would
#  be the same overreach the header of check-color-tokens.sh warns about.
#
#  Run from the repository root.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

pass=0
fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

scanner="$(mktemp)"
fix="$(mktemp -d)"
trap 'rm -f "$scanner"; rm -rf "$fix"' EXIT INT TERM

cat > "$scanner" <<'PYEOF'
#!/usr/bin/env python3
"""Report every way a shell script under tests/ can reach the ambient display.

Prints one violation per line as "<file>:<line>: <rule>: <detail>", and exits 1
if there was any. Given no arguments it says nothing and exits 0.
"""
import os
import re
import sys

# Things that put a window on a display. `qs` is quickshell's own short name.
CLIENTS = ("quickshell", "qs", "labwc", "sway", "Hyprland", "niri")

# Command words that stand in front of the real command without being it.
WRAPPERS = ("env", "exec", "command", "nohup", "sudo", "setsid", "stdbuf")

# Words that take a command NAME and look it up instead of running it. Every
# runner in here opens with `command -v quickshell || SKIP`, which is a
# question, not a launch.
PROBES = ("type", "hash", "whence")

# First arguments that turn a compositor into a question. `sway --version` and
# `niri validate` print and exit; neither opens anything, and three runners
# report which compositor they got by asking it.
QUERIES = ("--version", "-V", "--help", "-h", "validate", "--validate")

ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
WORD = re.compile(r"[^\s;|&()<>]+")


def blank(text, start, end):
    """Replace a span with spaces, keeping newlines so offsets and line
    numbers survive. Every stripping pass below works this way: the string
    never changes length, so a position in the stripped text is a position in
    the original file."""
    return text[:start] + "".join(
        "\n" if c == "\n" else " " for c in text[start:end]
    ) + text[end:]


def strip(src):
    """Return (code, expand, bare) — the same text three times, with more of it
    blanked out each time and every offset preserved.

    code   — comments and heredoc bodies blanked. Quotes intact.
    expand — plus single-quoted contents blanked. This is the text the shell
             would perform expansions on, so it is what rules B and C read:
             "$WAYLAND_DISPLAY" reaches the ambient session and
             '$WAYLAND_DISPLAY' is nine characters. That distinction is what
             lets this file quote the patterns it bans without banning itself.
    bare   — plus double-quoted contents blanked. Only command words survive,
             so a compositor named inside a string is not read as one being
             started.

    The scanner carries a stack rather than searching for the next matching
    quote, because `"$( … "$x" … )"` is not one quoted run: a command
    substitution opens a fresh context, and the words inside it are code. The
    naive version blanked `timeout 120 quickshell` out of
    `out="$(QT_LOGGING_RULES="qml=true" timeout 120 quickshell -p "$f")"` —
    it saw the quote before `qml` as the closing one — and so reported the
    launch it exists to find as no launch at all.
    """
    n = len(src)
    code = list(src)
    sq, dq = [], []
    pending = []               # heredoc terminators awaiting their line
    # frame: [mode, span_start, paren_depth, is_substitution]
    stack = [["code", None, 0, False]]
    i = 0

    def heredocs(i):
        while pending:
            term, dash = pending.pop(0)
            start = i
            while i < n:
                eol = src.find("\n", i)
                eol = n if eol < 0 else eol
                line = src[i:eol]
                if (line.strip() if dash else line).rstrip() == term:
                    i = eol + 1 if eol < n else n
                    break
                i = eol + 1 if eol < n else n
            for j in range(start, min(i, n)):
                if code[j] != "\n":
                    code[j] = " "
        return i

    while i < n:
        f = stack[-1]
        c = src[i]

        if c == "\\":
            i += 2
            continue

        if f[0] == "dq":
            if c == '"':
                dq.append((f[1], i))
                stack.pop()
                i += 1
                continue
            if src.startswith("$(", i):
                dq.append((f[1], i))
                stack.append(["code", None, 0, True])
                i += 2
                continue
            i += 1
            continue

        # code context
        if c == "\n":
            i = heredocs(i + 1)
            continue

        if c == "'":
            j = src.find("'", i + 1)
            j = n if j < 0 else j
            sq.append((i + 1, j))
            i = j + 1
            continue

        if c == '"':
            stack.append(["dq", i + 1, 0, False])
            i += 1
            continue

        if c == "#" and (i == 0 or src[i - 1] in " \t\n;&|("):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                code[k] = " "
            i = j
            continue

        if src.startswith("$(", i):
            stack.append(["code", None, 0, True])
            i += 2
            continue

        if src.startswith("<<", i) and not src.startswith("<<<", i):
            j = i + 2
            dash = False
            if j < n and src[j] == "-":
                dash = True
                j += 1
            while j < n and src[j] in " \t":
                j += 1
            m = re.match(r"""['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?""", src[j:])
            if m:
                pending.append((m.group(1), dash))
                i = j + m.end()
                continue
            i += 2
            continue

        if c == "(":
            f[2] += 1
            i += 1
            continue

        if c == ")":
            if f[2] > 0:
                f[2] -= 1
            elif f[3] and len(stack) > 1:
                stack.pop()
                # A substitution that opened inside double quotes hands the
                # rest of the line back to those quotes.
                if stack[-1][0] == "dq":
                    stack[-1][1] = i + 1
            i += 1
            continue

        i += 1

    code = "".join(code)
    expand = code
    for a, b in sq:
        expand = blank(expand, a, b)
    bare = expand
    for a, b in dq:
        bare = blank(bare, a, b)
    return code, expand, bare


def segments(bare):
    """Split into command segments, yielding (offset, text, terminator). A
    segment begins at the start of the file or just after a shell operator,
    which is where a command word can appear.

    A newline preceded by a backslash does NOT end a segment. That continuation
    is the difference between seeing

        env -u WAYLAND_DISPLAY \\
            sway -c "$cfg"

    as one protected command and seeing it as an `env` and then a bare `sway`
    on the desk. Four launches in this tree are written that way.
    """
    out = []
    start = 0
    i, n = 0, len(bare)
    while i < n:
        if bare[i] == "\n" and i > 0 and bare[i - 1] == "\\":
            i += 1
            continue
        if bare[i] in ";\n&|(){}`":
            out.append((start, bare[start:i], bare[i]))
            i += 1
            start = i
            continue
        if bare.startswith("$(", i):
            out.append((start, bare[start:i], "$"))
            i += 2
            start = i
            continue
        i += 1
    out.append((start, bare[start:], ""))
    return out


def head(seg):
    """The command word of a segment and where it starts, or (None, None).

    Skips leading NAME=value pairs and wrapper commands with their flags, which
    is how `env -u FOO BAR=1 timeout 30 quickshell` resolves to quickshell. A
    lookup — `command -v quickshell`, `type niri` — resolves to nothing, because
    asking whether a compositor is installed is not starting one.
    """
    pos = 0
    saw_command = False
    while True:
        m = WORD.search(seg, pos)
        if not m:
            return None, None
        word = m.group(0)
        pos = m.end()
        # Blanking a quote's CONTENTS leaves its delimiters behind, so
        # `VAR="…" cmd` still offers the closing `"` as a word. Without this
        # the lone quote was accepted as the command name and the real one —
        # `out="$(QT_LOGGING_RULES="…" timeout 120 quickshell …)"` — was never
        # reached.
        word = word.strip("\"'")
        if not word:
            continue
        if ASSIGN.match(word):
            continue
        if word == "-u":
            # `env -u NAME`: the name belongs to the flag, not to the command.
            m2 = WORD.search(seg, pos)
            if m2:
                pos = m2.end()
            continue
        if word.startswith("-"):
            # -v and -V print a path; -p RUNS the command with the default
            # PATH, so `command -p quickshell` is a launch like any other.
            if saw_command and word in ("-v", "-V"):
                return None, None
            continue
        if word in PROBES:
            return None, None
        if word in WRAPPERS:
            saw_command = word == "command"
            continue
        if word == "timeout":
            m2 = WORD.search(seg, pos)
            if m2 and re.fullmatch(r"[0-9.]+[smhd]?", m2.group(0)):
                pos = m2.end()
            continue
        return word, m.start()


def lineno(text, off):
    return text.count("\n", 0, off) + 1


# The suite that tests the library's own refusals, which cannot be written
# without naming the things the refusals are about.
#
# tests/test-headless-lib.sh calls headless_assert_private directly against
# filesystems it builds itself, so it ASSIGNS HEADLESS_AMBIENT_DISPLAY and
# HEADLESS_AMBIENT_RUNTIME to fixture paths (rule C) and writes literal socket
# names like wayland-1 (rule D) — the collision between a private socket's
# number and the desk's is the defect it exists to catch, and it cannot be
# reproduced without spelling the number out.
#
# The exemption is C and D ONLY, and that is the whole reason it is a separate
# flag rather than reusing in_lib, which returns early and drops A and B with
# it. A and B are the rules that actually keep a window off somebody's desktop,
# and this file is held to both: the mutant below proves it.
LIB_TESTS = {"test-headless-lib.sh"}


def scan(path, src, in_lib, lib_test=False):
    code, expand, bare = strip(src)
    out = []

    # Rule C — the ambient values the library keeps in order to refuse.
    if not in_lib and not lib_test:
        for m in re.finditer(r"HEADLESS_AMBIENT_(DISPLAY|RUNTIME|SIG)\b", expand):
            out.append((lineno(expand, m.start()), "C",
                        "reads HEADLESS_AMBIENT_%s, which the library records "
                        "only so it can refuse" % m.group(1)))
    if in_lib:
        return out

    # Where the script drops the inherited display for good. `headless_begin`
    # unsets it; the opt-in gate exits before anything is started.
    neutral = len(src) + 1
    for pat in (r"\bunset\b[^\n;|&]*\bWAYLAND_DISPLAY\b",
                r"\bheadless_begin\b",
                r"\bheadless_require_nested_optin\b"):
        for m in re.finditer(pat, bare):
            # A bare `unset`, not `env -u`: `env` neutralises one command only.
            seg_text = bare[max(0, m.start() - 200):m.start()]
            if pat.startswith(r"\bunset") and re.search(r"\benv\b[^\n;|&]*$", seg_text):
                continue
            neutral = min(neutral, m.start())

    # A suite behind the opt-in gate is allowed to look at the session it nests
    # in: refusing unless APEX_TEST_ALLOW_NESTED_ON_DESK=1 is the sanctioned
    # way to touch the desk, and measure-idle-inhibit.sh has no other option.
    gated = re.search(r"\bheadless_require_nested_optin\b", bare) is not None

    # Rule D — putting the display back after the unset, by guessing at it.
    # `WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"` placed AFTER
    # headless_begin passes rules A, B and C: the launch is covered, the read is
    # not before the unset, and no ambient variable is named. It is still a
    # runner reaching for somebody's session — the unset leaves the variable
    # empty, so the fallback is the only value that survives, and it is a guess
    # at the socket name the desk is using. A literal `wayland-0` is the same
    # move with the guess written out.
    if not gated and not lib_test:
        for m in re.finditer(r"\$\{WAYLAND_DISPLAY(?::[-=+?]|[-=+?])", expand):
            out.append((lineno(expand, m.start()), "D",
                        "supplies a fallback for WAYLAND_DISPLAY; after the "
                        "unset the fallback is the only value left, and it is "
                        "a guess at the session's socket"))
        for m in re.finditer(r"""WAYLAND_DISPLAY=["']?wayland-""", expand):
            out.append((lineno(expand, m.start()), "D",
                        "names a display socket literally instead of using one "
                        "this run created"))

    # Rule B — reading the ambient display before dropping it.
    for m in re.finditer(r"\$\{?WAYLAND_DISPLAY\b", expand):
        if m.start() < neutral:
            out.append((lineno(expand, m.start()), "B",
                        "reads $WAYLAND_DISPLAY before unsetting it, so the "
                        "value is the ambient session's"))

    # An env prefix kept in an array counts, provided the array is defined in
    # this file and sets WAYLAND_DISPLAY. run-display-unplug-test.sh starts the
    # shell three times through one ENVV=(env -u … WAYLAND_DISPLAY="$nested" …),
    # which is better practice than repeating the prefix, and a checker that
    # cannot see it would push people back to repeating it.
    arrays = []
    for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)=\(", expand):
        depth, j = 1, m.end()
        while j < len(expand) and depth:
            depth += (expand[j] == "(") - (expand[j] == ")")
            j += 1
        if re.search(r"(^|\s)WAYLAND_DISPLAY=", expand[m.end():j]):
            arrays.append(m.group(1))

    # `case` labels look exactly like commands: `niri)` is a pattern, not a
    # compositor. check-compositor-backends.sh dispatches on three of them.
    cases = []
    opens = [m.start() for m in re.finditer(r"\bcase\b", bare)]
    closes = [m.start() for m in re.finditer(r"\besac\b", bare)]
    for o in opens:
        later = [c for c in closes if c > o]
        if later:
            cases.append((o, later[0]))

    def in_case(pos):
        return any(a < pos < b for a, b in cases)

    # Rule A — every launch covered.
    for off, seg, term in segments(bare):
        word, at = head(seg)
        if word not in CLIENTS:
            continue
        start = off + at
        if start > neutral:
            continue
        rest = WORD.search(seg, at + len(word))
        if rest and rest.group(0) in QUERIES:
            continue
        # `niri)` — the word is flush against the paren that ended the segment,
        # and there is nothing after it. That is a pattern being matched.
        if term == ")" and not seg[at + len(word):].strip() and in_case(start):
            continue
        # Read the prefix from the expansion text, not `bare`: "${ENVV[@]}" is
        # blanked in `bare` by construction, and it is the thing being looked for.
        pre = expand[off:start]
        if re.search(r"(^|\s)-u\s+WAYLAND_DISPLAY(\s|$)", pre):
            continue
        if re.search(r"(^|\s|\")WAYLAND_DISPLAY=", pre):
            continue
        if any(re.search(r"\$\{%s\[[@*]\]\}" % a, pre) for a in arrays):
            continue
        out.append((lineno(bare, start), "A",
                    "starts %s on the inherited display: no unset before it, "
                    "and nothing on the command itself replaces it" % word))
    return out


def main(argv):
    bad = 0
    for path in argv:
        try:
            src = open(path, encoding="utf-8", errors="replace").read()
        except OSError as e:
            print("%s: cannot read: %s" % (path, e))
            bad += 1
            continue
        in_lib = "/lib/" in path
        lib_test = os.path.basename(path) in LIB_TESTS
        for line, rule, detail in sorted(scan(path, src, in_lib, lib_test)):
            print("%s:%d: %s: %s" % (path, line, rule, detail))
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF

scan() { python3 "$scanner" "$@"; }

# ── The tree is clean ────────────────────────────────────────────────────────
mapfile -t scripts < <(find "$root/tests" -name '*.sh' -type f | sort)
want "there are runners to check" test "${#scripts[@]}" -gt 20

violations="$(scan "${scripts[@]}")"
if [ -z "$violations" ]; then
    ok "no script under tests/ can reach the ambient display"
else
    bad "$(grep -c . <<< "$violations") script(s) under tests/ can reach the ambient display"
    sed "s|^$root/||; s/^/          /" <<< "$violations"
fi

# ── The eight that never used the library still pass ─────────────────────────
# Named one by one rather than counted. If one of them is rewritten to source
# the library that is fine, but it must not be able to go the other way — a
# rule that only recognises lib/headless.sh would quietly stop checking these.
for f in run-nav-geometry-test.sh run-settings-pages-test.sh \
         run-settings-staged-test.sh run-agent-settings-test.sh \
         run-agent-state-render-test.sh run-input-settings-test.sh \
         run-display-unplug-test.sh run-display-transaction-test.sh; do
    if [ -f "$root/tests/$f" ]; then
        want "$f is clean without sourcing the library" scan "$root/tests/$f"
    fi
done

# ── The library's own test suite, exempt from C and D and from nothing else ──
# tests/test-headless-lib.sh drives headless_assert_private against filesystems
# it builds itself, so it assigns the HEADLESS_AMBIENT_* variables and writes
# literal socket names. Both are the subject of the test rather than a reach for
# the desk. The exemption is narrow and it is checked in both directions: the
# file as it stands must pass, and a copy of it that starts a client on the
# inherited display must still fail on rule A.
if [ -f "$root/tests/test-headless-lib.sh" ]; then
    want "test-headless-lib.sh is clean under the rules it is still held to" \
        scan "$root/tests/test-headless-lib.sh"

    # The mutant keeps the name, because the exemption is keyed on the basename
    # — a copy called anything else would be refused for the wrong reason and
    # prove nothing about the exemption.
    mkdir -p "$fix/libtest"
    {
        head -2 "$root/tests/test-headless-lib.sh"
        echo 'quickshell -p /dev/null &'
        tail -n +3 "$root/tests/test-headless-lib.sh"
    } > "$fix/libtest/test-headless-lib.sh"
    mutant_e() { ! scan "$fix/libtest/test-headless-lib.sh" > "$fix/e.out"; }
    want "an exempt lib test that starts a client on the inherited display fails" \
        mutant_e
    want "  ...and it is rule A that says so, so C and D are the only exemption" \
        grep -q ': A:' "$fix/e.out"
fi

# ── Prose and data cannot trip it ────────────────────────────────────────────
# check-compositor-backends.sh holds `COMPOSITORS=(hyprland niri labwc)` and
# check-keybind-lua.sh the string "the Hyprland artifact is …". A word-grep
# calls both of those a launch, and a check with two standing false positives
# gets switched off within a month.
for f in check-compositor-backends.sh check-keybind-lua.sh; do
    want "$f is not mistaken for a launcher" scan "$root/tests/$f"
done

# ── The mutants ──────────────────────────────────────────────────────────────
# One per rule, because a guard that has never failed is a guard nobody has
# tested. Each mutant is the real runner with one edit, and the edit is the
# regression it is meant to catch.
victim="$root/tests/run-service-tier-test.sh"
mkdir -p "$fix"

# A — the sandbox call goes away and quickshell inherits the desk. This is the
#     shape every one of the twelve had.
grep -v '^headless_begin$' "$victim" > "$fix/mutant-a.sh"
mutant_a() { ! scan "$fix/mutant-a.sh" > "$fix/a.out"; }
want "a runner that starts quickshell with no unset in front of it fails" mutant_a
want "  ...and it is rule A that says so" grep -q ': A:' "$fix/a.out"

# B — the pre-headless opening: consult the ambient display, skip if absent.
#     Reading it to decide whether to skip is how a runner concludes it may use
#     somebody's session.
{
    head -20 "$victim"
    echo 'if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then echo "SKIP"; exit 0; fi'
    tail -n +21 "$victim"
} > "$fix/mutant-b.sh"
mutant_b() { ! scan "$fix/mutant-b.sh" > "$fix/b.out"; }
want "a runner that consults the inherited display before unsetting it fails" mutant_b
want "  ...and it is rule B that says so" grep -q ': B:' "$fix/b.out"

# C — the sandbox stays, and the display is put back from the value the library
#     saved in order to refuse it. Rules A and B both pass on this one, which is
#     why C exists.
sed 's|^headless_begin$|headless_begin\nexport WAYLAND_DISPLAY="$HEADLESS_AMBIENT_DISPLAY"|' \
    "$victim" > "$fix/mutant-c.sh"
mutant_c() { ! scan "$fix/mutant-c.sh" > "$fix/c.out"; }
want "a runner that restores the display from the saved ambient value fails" mutant_c
want "  ...and it is rule C that says so" grep -q ': C:' "$fix/c.out"

# D — the display put back after the sandbox, from a default. This one was
#     written as a hand mutation against run-popup-smoke.sh and the check passed
#     it: A, B and C are all satisfied, and the runner still ends up on
#     wayland-1. Rule D exists because of it, and it stays here so it cannot be
#     lost again.
sed 's|^headless_begin$|headless_begin\nexport WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"|' \
    "$victim" > "$fix/mutant-d.sh"
mutant_d() { ! scan "$fix/mutant-d.sh" > "$fix/d.out"; }
want "a runner that defaults WAYLAND_DISPLAY back to a guess fails" mutant_d
want "  ...and it is rule D that says so" grep -q ': D:' "$fix/d.out"

# The control. Without it every assertion above would also hold if `scan` were
# broken outright and failed on everything it was handed.
cp "$victim" "$fix/control.sh"
want "the same scanner still passes on an unmutated copy" scan "$fix/control.sh"

# And the mutants must be reachable edits, not typos: each has to differ from
# the original by exactly the line it claims to change.
want "mutant A differs from the original" \
    test "$(diff "$victim" "$fix/mutant-a.sh" | grep -c '^<')" -eq 1
want "mutant B differs from the original" \
    test "$(diff "$victim" "$fix/mutant-b.sh" | grep -c '^>')" -eq 1
want "mutant C differs from the original" \
    test "$(diff "$victim" "$fix/mutant-c.sh" | grep -c '^>')" -eq 1
want "mutant D differs from the original" \
    test "$(diff "$victim" "$fix/mutant-d.sh" | grep -c '^>')" -eq 1

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
