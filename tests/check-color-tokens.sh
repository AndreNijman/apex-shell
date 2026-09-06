#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-color-tokens.sh — colours come from the theme, or from this allowlist.
#
#  ── Why this check exists ───────────────────────────────────────────────────
#  Outside src/theme/ the tree carried 66 lines of hardcoded hex, 71
#  occurrences. Counting only the ones that meant "something is wrong", there
#  were SEVEN different reds:
#
#      #f87171  12 sites   destructive controls, conflicts, offline
#      #f38ba8   4 sites   disk >=90%, update failed, urgency high
#      #ff4444   4 sites   battery <=5%, clear-bind hover, record dot
#      #e06c75   2 sites   notification critical
#      #ff5555   2 sites   timer urgent
#      #ff5c5c   2 sites   lockscreen auth error
#      #ff6b6b   2 sites   power menu danger
#
#  Nothing distinguished them. The same class of event rendered in a different
#  red depending on which file happened to draw it, and two surfaces reporting
#  the SAME event disagreed: a notification's accent bar changed colour as the
#  toast expired into the list, because the toast said #ABB2BF for normal
#  urgency and the list said Theme.active.
#
#  Every test passed throughout. A hex literal is valid QML; no check looked.
#  This is the colour half of the problem tests/check-scale-tokens.sh describes
#  for geometry, and it has the same shape — a local idiom that reproduces
#  itself, because the next person to add a red copies the red next to them.
#
#  ── Why an allowlist rather than a ban ──────────────────────────────────────
#  Some literals are correct and must survive. A modal scrim has to darken any
#  wallpaper, so it must NOT follow the palette. A swatch component's default
#  is a sentinel: a visible black chip means a caller forgot to pass a colour,
#  and a token there would hide the bug. Those are listed below WITH THE REASON,
#  which is the part that stops the next reader "fixing" them.
#
#  The count is asserted EXACTLY, and the allowlist is a set of (file, colour)
#  pairs rather than a per-file tally. Per-file tallies pass when someone swaps
#  #f87171 for #ff0000 in the same file, and this repository has shipped a
#  `-ge 30` assertion that stayed green while 20 of 68 items were dropped.
#  So: a NEW literal fails, a REMOVED one fails until it leaves the list, and a
#  SUBSTITUTED one fails. All three, or the list rots.
#
#  ── What it does NOT do ─────────────────────────────────────────────────────
#  It bounds hex literals ("#rgb" .. "#aarrggbb") and the CSS colour NAMES in
#  the list below, in code position. It also bounds one specific disguise: a
#  colour written as Qt.rgba(248/255, 113/255, 113/255, a), which is a hex
#  literal in component fractions and drifts away from the token it duplicates
#  invisibly — exactly what happened to #f87171 at alpha 0.75 and 0.50.
#
#  That disguise was worth 45 occurrences of the Qt.rgba(n/255, n/255, n/255)
#  pattern, of which 43 became tokens and 2 are allowlisted below. (Counting is
#  by OCCURRENCE throughout this file. The hex layer was 66 lines / 71
#  occurrences / 75 once named colours are included — quote the basis, because
#  three different numbers are all correct for the same tree.)
#
#  It does NOT bound Qt.rgba() with plain decimals, e.g. Qt.rgba(0.9,0.2,0.2,1).
#  Those exist (CenterContent's recording fills) and are deliberately out of
#  scope; say so rather than let the header imply coverage it lacks.
#
#  Colours are extracted with a comment- and string-aware scanner, not a line
#  grep, so a hex named in a `//` or `/* */` comment can neither satisfy nor
#  trip this check. Five checks in this project have been satisfied by their
#  own prose; this one is self-tested against that in both directions.
#
#  PASS = the set of colour literals in code equals the allowlist, exactly.
#
#  Run from anywhere: ./tests/check-color-tokens.sh
#  Point it at another tree with APEX_COLOR_SRC=/path/to/src (used to prove it
#  fails on the code as it was before the tokens existed).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
set +e
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

SRC="${APEX_COLOR_SRC:-src}"
[ -d "$SRC" ] || { echo "FATAL: no $SRC directory" >&2; exit 2; }

# ── The allowlist ───────────────────────────────────────────────────────────
# file | colour | why it is right, and why not to tokenise it
ALLOW_RAW="
src/components/config/CfgSwatch.qml|#000000|unset-property sentinel — a visible black chip means a caller forgot to pass a colour; a token would hide that
src/modules/Center/DashStats.qml|#cba6f7|RAM gauge series colour — three gauges in one row must be told apart; the shell has no series palette to move it to
src/modules/Center/DashStats.qml|#89dceb|iGPU gauge series colour — same row, same reason
src/modules/Center/CenterContent.qml|#ff4444|recording tally light, matching the Qt.rgba(0.9,0.2,0.2) fills around it — not a danger state
src/modules/Center/CenterContent.qml|#ff9999|a LIGHT red reading on the dark red fill above it — fixed contrast, not the danger accent
src/services/PowerMenu.qml|#4d2020|full-width danger row TINT, deliberately far dimmer than Theme.dangerFill, which is a button fill
src/windows/ConfirmDialog.qml|#99000000|modal scrim — has to darken every wallpaper, so it must not follow the palette
src/windows/DisplayConfirm.qml|#99000000|modal scrim over a layout the user may not be able to read — same reason as ConfirmDialog's, and it must not follow a palette generated from the wallpaper behind it
src/windows/Lockscreen.qml|black|opaque lock base, so there is never a transparent flash before the wallpaper paints
src/nexus/Nexus.qml|black|desktop dim behind the settings window; the opacity does the work, the colour must not move
"

# Colours written as Qt.rgba component fractions. Same rule, separate list,
# because the pattern differs.
# One row per (file, colour), never one per occurrence: two identical rows
# distinguished only by a comment saying "second occurrence" cannot tell you
# which to delete when one of them goes away, which is list rot in the check
# whose job is preventing list rot. Membership is asserted from these rows and
# the OCCURRENCE count is asserted separately, below.
ALLOW_FRAC_RAW="
src/components/TimeInput.qml|235/255, 240/255, 255/255|x2 — a blue-tinted near-white, NOT Theme.fixedLight; mapping it onto that token would be a similar-looking token rather than a correct one, which is worse than the literal because the mistake becomes invisible
"

EXPECT_TOTAL=10
EXPECT_FRAC=2

# ── The Agent Center's own rule (roadmap P0-021) ────────────────────────────
# The colour half of this file's problem had a second shape in src/services/
# agents/, and no literal was involved, so nothing above could see it. Both
# session rows decided a state's colour inline:
#
#     color: needsYou ? Theme.active
#          : state === "failed" ? Theme.wsUrgent
#          : live ? Theme.text : Theme.subtext
#
# Every colour there is a token, so the check passed. It is still wrong twice
# over. Seven runtime states collapse onto three values, two of which are the
# palette's FOREGROUND — on a matugen dark scheme `text` is #e3e2e5 — so
# starting, working, complete and exited all render near-white, which is
# precisely the bug a user reported as "APEX agents display only in white".
# And `wsUrgent` is a Workspace Visuals token: a fixed pink borrowed from the
# workspace strip, so the agent list's red moved whenever the workspace strip's
# did, for no reason either file stated.
#
# Both rows carried their own copy, and the copies had already begun to differ.
# So the rule is structural rather than about colour values: an agent row does
# not decide what a state looks like. src/services/agentstate.js does, once,
# and tests/agent-state-test.js measures the result.
#
# Two literals survive, and neither is a mapping — they are listed WITH THE
# REASON for the same purpose as the colour allowlist above.
ALLOW_STATE_RAW="
src/services/agents/StateBadge.qml|working|the pulse, and only the pulse — motion in a status list has to mean 'this is changing', so exactly one state animates
src/services/agents/RequestRow.qml|permission_request|the card IS a blocked request; it names the state it draws rather than testing one
"

# Membership is asserted from the rows above; the OCCURRENCE count separately,
# for the reason the fraction list gives — StateBadge names "working" twice (the
# animation's `running`, and the guard that resets opacity when it stops), and a
# set alone cannot notice one of the two going away.
EXPECT_STATES=3

# Workspace Visuals are fixed white-family colours for the workspace strip.
# They are correct there and wrong everywhere else, and an agent state was the
# place they leaked to.
WS_FORBIDDEN_DIR="services/agents"

# ── The extractor ───────────────────────────────────────────────────────────
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/extract.py" <<'PY'
"""Emit `relpath|colour` for every colour literal in CODE position.

Comments are removed with a scanner that tracks string state, so a hex inside
a // or /* */ comment is invisible here, and a // inside a string literal does
not start a comment. Newlines are preserved so reported line numbers are real.
"""
import re, sys, pathlib

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "literal"

NAMED = "white|black|red|green|blue|yellow|orange|gray|grey|magenta|cyan"

def strip_comments(t):
    out = []
    i, n, quote = 0, len(t), None
    while i < n:
        c = t[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(t[i + 1]); i += 2; continue
            if c == quote:
                quote = None
            i += 1; continue
        if c in "\"'`":
            quote = c; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and t[i + 1] == "/":
            while i < n and t[i] != "\n":
                i += 1
            continue                      # leave the newline in place
        if c == "/" and i + 1 < n and t[i + 1] == "*":
            i += 2
            while i + 1 < n and not (t[i] == "*" and t[i + 1] == "/"):
                if t[i] == "\n":
                    out.append("\n")      # keep line numbers honest
                i += 1
            i += 2; continue
        out.append(c); i += 1
    return "".join(out)

STATES = ("starting", "working", "waiting_for_user", "permission_request",
          "complete", "failed", "exited")

rows = []
for p in sorted(root.rglob("*.qml")):
    rel = p.relative_to(root.parent) if root.name == "src" else p
    rel = str(rel)

    if mode in ("states", "ws"):
        # Agent rows only. Matched on the directory names rather than on a
        # string prefix, so pointing APEX_COLOR_SRC at another tree still works.
        if not (p.parent.name == "agents" and p.parent.parent.name == "services"):
            continue
        code = strip_comments(p.read_text(errors="replace"))
        if mode == "ws":
            for m in re.finditer(r"\bTheme\.(ws[A-Z]\w*)", code):
                line = code[:m.start()].count("\n") + 1
                rows.append(f"{rel}|{m.group(1)}|{line}")
            continue
        for m in re.finditer(r'"(%s)"' % "|".join(STATES), code):
            line = code[:m.start()].count("\n") + 1
            rows.append(f"{rel}|{m.group(1)}|{line}")
        continue

    if rel.startswith("src/theme/"):
        continue                          # the theme is where colours live
    code = strip_comments(p.read_text(errors="replace"))

    if mode == "frac":
        # A hex colour disguised as Qt.rgba component fractions.
        for m in re.finditer(r"Qt\.rgba\(\s*(\d{1,3}/255\s*,\s*\d{1,3}/255\s*,\s*\d{1,3}/255)", code):
            line = code[:m.start()].count("\n") + 1
            rows.append(f"{rel}|{re.sub(r'\s+', ' ', m.group(1))}|{line}")
        continue

    for m in re.finditer(r'"(#[0-9a-fA-F]{3,8})"', code):
        line = code[:m.start()].count("\n") + 1
        rows.append(f"{rel}|{m.group(1).lower()}|{line}")

    # Named colours count only where they are assigned to a colour property,
    # so a label that happens to read "red" is not a false positive.
    for ln, text in enumerate(code.split("\n"), start=1):
        if not re.search(r"[Cc]olor\w*\s*:", text):
            continue
        for m in re.finditer(r'"(%s)"' % NAMED, text):
            rows.append(f"{rel}|{m.group(1)}|{ln}")

for r in rows:
    print(r)
PY

# normalise an allowlist blob to `file|colour` lines, sorted
norm_allow() { printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | cut -d'|' -f1,2 | sort; }

# normalise extractor output (drops the line number) , sorted
norm_found() { cut -d'|' -f1,2 | sort; }

run_extract() { python3 "$TMP/extract.py" "$1" "${2:-literal}" 2>/dev/null; }

# ── 1. no literal outside the allowlist ─────────────────────────────────────
found=$(run_extract "$SRC")
allow=$(norm_allow "$ALLOW_RAW")
unexpected=$(printf '%s\n' "$found" | norm_found | comm -23 - <(printf '%s\n' "$allow"))
if [ -z "$unexpected" ]; then
    ok "every colour literal in code is on the allowlist"
else
    printf '%s\n' "$unexpected" | sed 's/^/       unexpected: /' | head -20
    bad "every colour literal in code is on the allowlist"
fi

# ── 2. no stale allowlist entry ─────────────────────────────────────────────
# A removed literal must force an edit to the list, or the list drifts into
# describing a tree that no longer exists.
stale=$(printf '%s\n' "$allow" | comm -13 <(printf '%s\n' "$found" | norm_found) -)
if [ -z "$stale" ]; then
    ok "no allowlist entry describes a literal that is already gone"
else
    printf '%s\n' "$stale" | sed 's/^/       stale: /' | head -20
    bad "no allowlist entry describes a literal that is already gone"
fi

# ── 3. the exact count, never -ge ───────────────────────────────────────────
n_found=$(printf '%s\n' "$found" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [ "$n_found" -eq "$EXPECT_TOTAL" ]; then
    ok "exactly $EXPECT_TOTAL colour literals remain in code (asserted exactly, not >=)"
else
    bad "expected exactly $EXPECT_TOTAL colour literals in code, found $n_found"
fi

# ── 4. every allowlist entry carries a reason ───────────────────────────────
# The reason is the whole value of the list. An entry without one is a literal
# somebody waved through.
missing_reason=$(printf '%s\n' "$ALLOW_RAW" | sed '/^[[:space:]]*$/d' \
                 | awk -F'|' 'NF < 3 || length($3) < 20 {print $1 "|" $2}')
if [ -z "$missing_reason" ]; then
    ok "every allowlisted literal states why it is not a token"
else
    printf '%s\n' "$missing_reason" | sed 's/^/       no reason: /'
    bad "every allowlisted literal states why it is not a token"
fi

# ── 5. the fraction disguise ────────────────────────────────────────────────
frac=$(run_extract "$SRC" frac)
frac_allow=$(norm_allow "$ALLOW_FRAC_RAW" | uniq)
frac_unexpected=$(printf '%s\n' "$frac" | norm_found | uniq | comm -23 - <(printf '%s\n' "$frac_allow"))
n_frac=$(printf '%s\n' "$frac" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [ -z "$frac_unexpected" ] && [ "$n_frac" -eq "$EXPECT_FRAC" ]; then
    ok "exactly $EXPECT_FRAC Qt.rgba(n/255,...) colours remain, all allowlisted"
else
    printf '%s\n' "$frac_unexpected" | sed 's/^/       unexpected: /' | head -10
    bad "Qt.rgba(n/255,...) colours: expected $EXPECT_FRAC allowlisted, found $n_frac"
fi

# ── 6. the tokens this check drove the tree onto still exist ────────────────
# Without them the check is theatre: it would be enforcing "no literals" on a
# tree with nowhere for a colour to come from.
missing_tok=""
for tok in danger warning success info attention fixedLight fixedDark dangerFill dangerFillHover; do
    grep -qE "^[[:space:]]*property color[[:space:]]+${tok}:" "$SRC/theme/Colors.qml" 2>/dev/null \
        || missing_tok="$missing_tok $tok"
done
if [ -z "$missing_tok" ]; then
    ok "Colors.qml still defines every status and fixed-contrast token"
else
    bad "Colors.qml is missing:$missing_tok"
fi

# ── 7. and are reachable the way call sites read them ──────────────────────
# Every call site in the tree says Theme.*; a token on Colors alone would send
# readers to two different singletons for their colours.
missing_mirror=""
for tok in danger warning success info attention fixedLight fixedDark dangerFill dangerFillHover; do
    grep -qE "^[[:space:]]*property color[[:space:]]+${tok}:[[:space:]]*Colors\.${tok}" \
        "$SRC/theme/Theme.qml" 2>/dev/null || missing_mirror="$missing_mirror $tok"
done
if [ -z "$missing_mirror" ]; then
    ok "Theme.qml mirrors every one of them, so call sites read one singleton"
else
    bad "Theme.qml does not mirror:$missing_mirror"
fi

# ── 8. no Workspace Visuals token in the Agent Center ───────────────────────
ws_found=$(run_extract "$SRC" ws)
if [ -z "$(printf '%s' "$ws_found" | tr -d '[:space:]')" ]; then
    ok "no Workspace Visuals token leaks into $WS_FORBIDDEN_DIR"
else
    printf '%s\n' "$ws_found" | sed 's/^/       ws token: /' | head -10
    bad "a Workspace Visuals token is being used for an agent state"
fi

# ── 9. an agent row does not decide what a state looks like ─────────────────
# Asserted as a (file, state) SET against the allowlist, and both directions,
# for the same reason the colour list is: a per-file tally passes when one
# mapping is swapped for another, and a stale entry lets the list rot.
states_found=$(run_extract "$SRC" states)
states_allow=$(norm_allow "$ALLOW_STATE_RAW")
states_unexpected=$(printf '%s\n' "$states_found" | norm_found | uniq \
                    | comm -23 - <(printf '%s\n' "$states_allow"))
states_stale=$(printf '%s\n' "$states_allow" \
               | comm -13 <(printf '%s\n' "$states_found" | norm_found | uniq) -)
n_states=$(printf '%s\n' "$states_found" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [ -z "$states_unexpected" ] && [ -z "$states_stale" ] \
   && [ "$n_states" -eq "$EXPECT_STATES" ]; then
    ok "no agent row maps a runtime state to a colour itself (agentstate.js does)"
else
    printf '%s\n' "$states_unexpected" | sed '/^$/d;s/^/       unexpected: /' | head -10
    printf '%s\n' "$states_stale"      | sed '/^$/d;s/^/       stale:      /' | head -10
    [ "$n_states" -eq "$EXPECT_STATES" ] \
        || printf '       expected exactly %s state literals, found %s\n' \
                  "$EXPECT_STATES" "$n_states"
    bad "no agent row maps a runtime state to a colour itself (agentstate.js does)"
fi

# ── 10. every allowlisted state literal carries a reason ────────────────────
missing_sreason=$(printf '%s\n' "$ALLOW_STATE_RAW" | sed '/^[[:space:]]*$/d' \
                  | awk -F'|' 'NF < 3 || length($3) < 20 {print $1 "|" $2}')
if [ -z "$missing_sreason" ]; then
    ok "every allowlisted state literal states why it is not a mapping"
else
    printf '%s\n' "$missing_sreason" | sed 's/^/       no reason: /'
    bad "every allowlisted state literal states why it is not a mapping"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  the self-test: prove each check can actually fail
#
#  Mutations are applied to a COPY and each is verified to have CHANGED the
#  file before its verdict is believed. A mutant that failed to apply must be
#  reported as such, never as caught — this repository has produced exactly
#  that false verdict before.
# ─────────────────────────────────────────────────────────────────────────────
printf '\n── self-test: can these checks fail? ──\n'
cp -r "$SRC" "$TMP/src" || exit 2
applied=0; noapply=0

# Re-run assertions 1-3 against the mutated copy and report whether it went red.
recheck_literals() {
    local f a u n
    f=$(run_extract "$TMP/src")
    a=$(norm_allow "$ALLOW_RAW")
    u=$(printf '%s\n' "$f" | norm_found | comm -23 - <(printf '%s\n' "$a"))
    local s
    s=$(printf '%s\n' "$a" | comm -13 <(printf '%s\n' "$f" | norm_found) -)
    n=$(printf '%s\n' "$f" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    [ -n "$u" ] || [ -n "$s" ] || [ "$n" -ne "$EXPECT_TOTAL" ]
}

mutate() {
    local label="$1" file="$2" from="$3" to="$4" verify="$5"
    local target="$TMP/$file" before after
    if [ ! -f "$target" ]; then
        bad "self-test $label: no such file $file"; return
    fi
    before=$(cat "$target")
    python3 - "$target" "$from" "$to" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t.replace(sys.argv[2], sys.argv[3], 1))
PY
    after=$(cat "$target")
    if [ "$before" = "$after" ]; then
        noapply=$((noapply+1))
        bad "self-test $label: the mutation did not apply, so its verdict is meaningless"
        return
    fi
    applied=$((applied+1))
    if "$verify"; then
        ok "self-test $label: caught"
    else
        bad "self-test $label: SURVIVED — the check does not detect it"
    fi
    printf '%s' "$before" > "$target"
}

# (a) a brand-new literal, in the idiom that produced all 66
mutate "a new hex literal in code" \
    "src/popups/WifiTab.qml" "color: Theme.danger" 'color: "#ff0000"' recheck_literals

# (b) an allowlisted literal removed — the list must be edited too
mutate "an allowlisted literal removed" \
    "src/windows/ConfirmDialog.qml" 'color: "#99000000"' "color: Theme.background" recheck_literals

# (c) an allowlisted literal SUBSTITUTED in place. A per-file count would pass
#     this. It is the reason the list is (file, colour) pairs.
mutate "an allowlisted literal swapped for a different one" \
    "src/services/PowerMenu.qml" '"#4d2020"' '"#5e2828"' recheck_literals

# (d) a named colour reintroduced on a colour property
mutate "a named colour on a colour property" \
    "src/windows/ConfirmDialog.qml" "color:          Theme.fixedLight" 'color:          "white"' \
    recheck_literals

# (e) the fraction disguise reintroduced
recheck_frac() {
    local f u n
    f=$(run_extract "$TMP/src" frac)
    u=$(printf '%s\n' "$f" | norm_found | uniq | comm -23 - <(norm_allow "$ALLOW_FRAC_RAW" | uniq))
    n=$(printf '%s\n' "$f" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    [ -n "$u" ] || [ "$n" -ne "$EXPECT_FRAC" ]
}
mutate "a colour rewritten as Qt.rgba component fractions" \
    "src/popups/HistoryTab.qml" \
    "Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.50)" \
    "Qt.rgba(248/255, 113/255, 113/255, 0.50)" recheck_frac

# (f) a token deleted from Colors.qml
recheck_token() {
    ! grep -qE "^[[:space:]]*property color[[:space:]]+danger:" "$TMP/src/theme/Colors.qml"
}
mutate "the danger token deleted from Colors.qml" \
    "src/theme/Colors.qml" "property color danger:" "property color dangerX:" recheck_token

# (g) the Workspace Visuals leak, put back exactly as it was
recheck_ws() {
    [ -n "$(printf '%s' "$(run_extract "$TMP/src" ws)" | tr -d '[:space:]')" ]
}
mutate "a workspace token used for an agent state" \
    "src/services/agents/SessionRow.qml" \
    "border.color: badge.toneColor" "border.color: Theme.wsUrgent" recheck_ws

# (h) a row deciding a state's colour again, in the idiom that caused P0-021
recheck_states() {
    local f u s n
    f=$(run_extract "$TMP/src" states)
    u=$(printf '%s\n' "$f" | norm_found | uniq \
        | comm -23 - <(norm_allow "$ALLOW_STATE_RAW"))
    s=$(norm_allow "$ALLOW_STATE_RAW" \
        | comm -13 <(printf '%s\n' "$f" | norm_found | uniq) -)
    n=$(printf '%s\n' "$f" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    [ -n "$u" ] || [ -n "$s" ] || [ "$n" -ne "$EXPECT_STATES" ]
}
mutate "a row deciding a state's colour inline" \
    "src/services/agents/SessionRow.qml" \
    "color: badge.toneColor" \
    'color: row.session.state === "failed" ? Theme.danger : Theme.text' \
    recheck_states

# (i) and the other direction — an allowlisted state literal removed. Without
#     this the list can describe a mapping that no longer exists, which is the
#     rot the colour list above is shaped to prevent.
mutate "an allowlisted state literal removed" \
    "src/services/agents/StateBadge.qml" \
    'running: badge.sessionState === "working"' "running: false" recheck_states

# ── the inverse mutants: prose must NOT trip any of this ────────────────────
# Without these, the check could be passing on comments rather than on code.
cat > "$TMP/src/InverseMutant.qml" <<'QML'
import QtQuick
// A comment naming color: "#ff0000" and color: "white" deliberately, plus a
// disguise: Qt.rgba(248/255, 113/255, 113/255, 0.5) — all in prose.
/* A block comment doing the same across lines:
       color: "#123456"
       color: "black"
       Qt.rgba(12/255, 34/255, 56/255, 1)
*/
Item {
    // color: "#abcdef"
    property string notAColour: "reddish"   // the word red must not match
    color: Theme.danger
}
QML
inv_lit=$(run_extract "$TMP/src" | grep 'InverseMutant')
inv_frac=$(run_extract "$TMP/src" frac | grep 'InverseMutant')
if [ -z "$inv_lit" ] && [ -z "$inv_frac" ]; then
    ok "self-test inverse: hex and named colours in // and /* */ comments are invisible"
else
    printf '%s\n%s\n' "$inv_lit" "$inv_frac" | sed 's/^/       tripped on: /' | head -10
    bad "self-test inverse: prose tripped the check"
fi

# And the other direction: a colour inside a STRING must still be seen, or the
# comment scanner could be swallowing code.
cat > "$TMP/src/InverseMutant.qml" <<'QML'
import QtQuick
Item {
    // The URL below contains // inside a string. If the scanner mishandles it,
    // everything after it on this line vanishes and the check goes quiet.
    property string url: "https://example.invalid/x"
    color: "#abcdef"
}
QML
inv2=$(run_extract "$TMP/src" | grep 'InverseMutant')
if [ -n "$inv2" ]; then
    ok "self-test inverse: a // inside a string does not blind the scanner to code after it"
else
    bad "self-test inverse: the scanner missed a real literal — comment stripping is too greedy"
fi
rm -f "$TMP/src/InverseMutant.qml"

printf '\nself-test: mutants applied=%d, failed-to-apply=%d\n' "$applied" "$noapply"
printf 'check-color-tokens: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
