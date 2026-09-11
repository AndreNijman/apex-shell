#!/usr/bin/env bash
# Whether the power menu offers Gaming Mode, decided the way the greeter decides.
#
# ── The defect this exists for ───────────────────────────────────────────────
# gamescope and Steam are ON-DEMAND packages in APEX, not image content. So
# /usr/share/wayland-sessions/apex-gaming.desktop ships on every machine while
# /usr/bin/gamescope does not, and the entry itself says so: it carries
# `TryExec=/usr/bin/gamescope`, which is the desktop-entry spec's own mechanism
# for "do not offer this unless the program exists". apex-greet's enumeration
# honours it, and Containerfile.apex has a build gate asserting the greeter
# hides the entry while gamescope is absent.
#
# PowerMenu.qml's probe tested the helper and the session FILE and nothing else.
# So on any APEX install without gamescope the two surfaces disagreed: the menu
# offered "Gaming Mode", taking it logged the user out, and the greeter then HID
# the session they had just chosen — landing them back on the desktop with
# `last-session=apex-gaming` written. On the old greeter that then selected by
# sort order at the next login, which is the lockout fixed in apex-os by the
# companion commit to this one.
#
# The build asserted the greeter's half. Nothing asserted the menu agreed, and
# this is that assertion.
#
# ── Why it extracts and runs rather than greps ───────────────────────────────
# A grep for "TryExec" in PowerMenu.qml would pass on a probe that read the key
# and ignored it, and would pass on one whose shell quoting was broken so that
# every branch exited 0 — which is the failure that matters here, because this
# gate FAILS CLOSED only if it actually runs. So the probe's own `sh -c` script
# is lifted out of the QML and executed against fixtures, exactly as apex-os's
# tests/test-apex-greet-sessions.sh lifts and runs the greeter's enumeration.
#
# The probe reads APEX_SESSION_HELPER and APEX_SESSION_DIR when they are set —
# the same pair PowerControl.sh honours — so the fixtures need no path rewriting
# and nothing here touches /usr.
#
# Runs headless, starts no compositor, opens nothing.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
MENU="$root/src/services/PowerMenu.qml"

pass=0
fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1${2:+  — $2}"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
is()   { local desc="$1" w="$2" g="$3"
         if [ "$g" = "$w" ]; then ok "$desc"; else bad "$desc" "want [$w] got [$g]"; fi; }

want "PowerMenu.qml exists and is non-empty" test -s "$MENU"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Lift the probe out of the QML ────────────────────────────────────────────
PROBE="$WORK/gating-probe.sh"
python3 - "$MENU" "$PROBE" <<'PY'
import json, re, sys

src = open(sys.argv[1], encoding="utf-8").read()

# Anchored on the Process's id, so this cannot pick up the windows probe that
# sits a few lines above and has the same shape.
anchor = src.find("id: gamingProbe")
if anchor < 0:
    sys.exit("no gamingProbe Process in PowerMenu.qml")
cmd = src.find("command: [", anchor)
if cmd < 0:
    sys.exit("gamingProbe has no command array")

# Consume quoted literals; a "]" seen OUTSIDE a literal ends the array. The
# script itself contains "[ -z ... ]", so searching for the next "]" would stop
# inside a string — the same trap the greeter extractor documents.
LIT = re.compile(r'"(?:[^"\\]|\\.)*"')
parts, i, n = [], cmd + len("command: ["), len(src)
while i < n:
    c = src[i]
    if c == '"':
        m = LIT.match(src, i)
        if not m:
            sys.exit("unterminated string literal in the probe")
        parts.append(json.loads(m.group(0)))
        i = m.end()
        continue
    if c == "]":
        break
    if c not in " \t\r\n+,":
        sys.exit("unexpected %r between the probe's literals" % c)
    i += 1
else:
    sys.exit("the probe's command array is not terminated")

# ["sh", "-c", <script>] — drop the interpreter and its flag.
if len(parts) < 3 or parts[0] != "sh" or parts[1] != "-c":
    sys.exit("the probe is not an sh -c invocation: %r" % (parts[:2],))
open(sys.argv[2], "w", encoding="utf-8").write("".join(parts[2:]))
PY
is "the gating probe is extractable from the shipped PowerMenu.qml" "0" "$?"

probe_src="$(cat "$PROBE" 2>/dev/null)"
# Plausibility. Without these the extraction could yield "" and every assertion
# below would pass by running an empty script that exits 0.
if [ "${#probe_src}" -ge 120 ]; then
    ok "…and is a whole script rather than a fragment (${#probe_src} chars)"
else
    bad "…and is a whole script rather than a fragment" "got ${#probe_src} chars"
fi
case "$probe_src" in
    *TryExec*) ok "…and it is the code that reads TryExec out of the entry" ;;
    *) bad "…and it is the code that reads TryExec out of the entry" "no TryExec in the extract" ;;
esac
case "$probe_src" in
    *apex-gaming.desktop*) ok "…and it still names the gaming session entry" ;;
    *) bad "…and it still names the gaming session entry" "entry name missing" ;;
esac

# ── The fixtures ─────────────────────────────────────────────────────────────
mkdir -p "$WORK/sessions" "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/helper"; chmod +x "$WORK/helper"
# The entry as APEX ships it: TryExec names the on-demand binary.
printf '[Desktop Entry]\nName=APEX Gaming Mode\nExec=/usr/libexec/apex-gaming-session\nTryExec=%s/bin/gamescope\nType=Application\n' \
    "$WORK" > "$WORK/sessions/apex-gaming.desktop"

# The probe needs sed and head; it must NOT be able to find a gamescope that
# happens to be installed on the machine running this file, or the fixture's
# answer would be the developer's.
for u in sed head; do
    up="$(command -v "$u" 2>/dev/null)" && ln -sf "$up" "$WORK/bin/$u"
done
SH="$(command -v sh)"
# By absolute path, and this is not a stylistic choice: `env -i` resolves the
# program it runs against the PATH it has just set, and that PATH is a directory
# holding sed, head and (sometimes) gamescope. Naming `sh` bare here made every
# case exit 127 — a "refusal" that would have made the defect assertion pass for
# entirely the wrong reason, and the positive control is what caught it.
gate() {
    local helper="$1" dir="$2"
    env -i PATH="$WORK/bin" APEX_SESSION_HELPER="$helper" APEX_SESSION_DIR="$dir" \
        "$SH" "$PROBE" >/dev/null 2>&1
    echo "$?"
}

install_gamescope()   { printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/gamescope"; chmod +x "$WORK/bin/gamescope"; }
uninstall_gamescope() { rm -f "$WORK/bin/gamescope"; }

# THE DEFECT. Helper present, entry present, binary absent — which is every APEX
# install that has not run `apex install gamescope steam`.
uninstall_gamescope
is "the row is refused when gamescope is not installed" "1" \
   "$(gate "$WORK/helper" "$WORK/sessions")"

# The positive control. Without it the assertion above would be satisfied by a
# probe that refuses unconditionally, which is a different bug with the same
# green tick.
install_gamescope
is "the row is offered once gamescope is installed" "0" \
   "$(gate "$WORK/helper" "$WORK/sessions")"

# Fails closed on each half independently, both with the binary PRESENT so the
# refusal is attributable to the thing being removed.
is "the row is refused with no session helper" "1" \
   "$(gate "$WORK/absent-helper" "$WORK/sessions")"
is "the row is refused with no session entry" "1" \
   "$(gate "$WORK/helper" "$WORK/absent-sessions")"

# An entry with no TryExec at all is offered: the spec says an absent TryExec is
# not a refusal, and reading one as "hide it" would make the gate depend on a
# key the entry is not required to carry.
printf '[Desktop Entry]\nName=APEX Gaming Mode\nExec=/usr/libexec/apex-gaming-session\nType=Application\n' \
    > "$WORK/sessions/apex-gaming.desktop"
uninstall_gamescope
is "an entry with no TryExec is not refused for lacking one" "0" \
   "$(gate "$WORK/helper" "$WORK/sessions")"

# ── The menu must actually consult the probe ─────────────────────────────────
# The probe being right is worth nothing if the row is not filtered on it.
#
# THIS ASSERTION WAS WRITTEN TOO WEAKLY THE FIRST TIME AND THE MUTATION CAUGHT
# IT. It was `grep -q 'a.action !== "gamingmode"' && grep -q 'showGaming'` —
# two independent searches of the whole file. Rewriting the clause to
# `(a.action !== "gamingmode")`, which drops the row unconditionally and is a
# real bug, left both greps satisfied and the suite green at 12/0. Proven, not
# reasoned: that mutation was applied and the suite passed.
#
# So the two halves must now appear in the SAME clause, which is the thing that
# actually ties the row to the probe.
if grep -qE 'a\.action !== "gamingmode".*showGaming' "$MENU"; then
    ok "the gamingmode row is filtered on the probe's result"
else
    bad "the gamingmode row is filtered on the probe's result" \
        "no clause gates the gamingmode row on gamingModeAvailable"
fi
want "gamingModeAvailable starts false, so the row is absent until proven" \
     grep -q 'property bool gamingModeAvailable: false' "$MENU"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
