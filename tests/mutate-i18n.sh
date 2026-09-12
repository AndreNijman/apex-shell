#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-i18n.sh — prove run-i18n-test.sh's newer assertions can go red.
#
#  Sections 4 and 5 of that suite measure things no earlier round measured: what
#  the HOST the shell runs in does about translation, and whether the hardcoded
#  font really renders non-Latin text. Both are shaped like the assertions this
#  unit has been caught by three times — a claim about an absence, which is
#  green whether the absence is real or the probe is broken.
#
#  So each mutant changes ONE arm and a NAMED assertion must go red. Restores
#  are `git checkout --`: authoritative about content, and a fresh mtime, which
#  is why `cp -p` and `mv` are banned here. The tree is compared against HEAD
#  after every mutate AND every restore.
#
#  Expected strings include the assertion's SUBJECT. `FAIL is drawn by a font
#  that covers it` matches nothing, because the suite prints
#  `FAIL CJK is drawn by a font that covers it` — the label is part of the
#  sentence. Three mutants here were first reported SURVIVED for exactly that
#  reason, as I2 was in round 2 and B2 in round 18b. The expectation gets
#  corrected, never the mutant.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

F="tests/run-i18n-test.sh"
SUITE="./tests/run-i18n-test.sh"
applied=0; noapply=0; caught=0; survived=0

tree_clean() { [ -z "$(git diff --name-only -- "$F" 2>/dev/null)" ]; }

restore() {
    git checkout -- "$F" 2>/dev/null
    if ! tree_clean; then
        echo "ABORT: tree still dirty after restore; verdicts would be meaningless" >&2
        exit 3
    fi
}

mutate() {   # mutate <id> <expected FAIL substring> <sed expression>
    local id="$1" want="$2" expr="$3" before out
    if ! tree_clean; then
        echo "ABORT: tree dirty before $id" >&2
        exit 3
    fi
    before="$(md5sum "$F")"
    sed -i "$expr" "$F"
    if [ "$before" = "$(md5sum "$F")" ]; then
        printf '%-4s NO-APPLY  the edit changed nothing, so its verdict would be meaningless\n' "$id"
        noapply=$((noapply + 1)); restore; return
    fi
    applied=$((applied + 1))
    out="$($SUITE 2>&1)"
    if printf '%s' "$out" | grep -q "FAIL $want"; then
        printf '%-4s CAUGHT    %s\n' "$id" "$want"
        caught=$((caught + 1))
    else
        printf '%-4s SURVIVED  wanted a FAIL naming: %s\n' "$id" "$want"
        printf '%s\n' "$out" | grep -E 'FAIL|^run-i18n' | sed 's/^/       /'
        survived=$((survived + 1))
    fi
    restore
}

echo "── baseline: green, or nothing below means anything ──"
base="$($SUITE 2>&1)"
printf '%s\n' "$base" | grep -E '^run-i18n'
if ! printf '%s' "$base" | grep -qE '^run-i18n-test: passed=[0-9]+ failed=0'; then
    echo "ABORT: the suite is not green to begin with" >&2
    printf '%s\n' "$base" | grep -E 'FAIL' >&2
    exit 3
fi

echo
echo "── section 4: the host probe ──"

# T1 — the control is pointed at the host that does NOT translate, so the probe
#      can no longer show itself capable of seeing a translator call.
mutate T1 "the probe finds a translator call in the host that DID translate" \
  's|CTRL="\$(ldd "\$(command -v "\$RUNNER")"|CTRL="$QS_BIN" \&\& false \&\& CTRL="$(ldd "$(command -v "$RUNNER")"|'

# T2 — the shipped-host probe is pointed at the host that DOES translate.
mutate T2 "quickshell calls no QTranslator and no installTranslator" \
  's|n_qs="\$(refs "\$QS_REAL" |n_qs="$(refs "$CTRL" |'

# T3 — the automatic-route control looks for a symbol libQt6Qml does not define,
#      so "Qt has a route quickshell does not take" loses its first half.
mutate T3 "Qt has an automatic route in libQt6Qml" \
  "s|grep -c 'loadTranslations'|grep -c 'loadTranslationsNoSuchSymbol'|"

# T4 — the engine-constructor floor. With the regex matching nothing, "never a
#      QQmlApplicationEngine" would be true of a probe that saw no engine at all.
mutate T4 "quickshell constructs a bare QQmlEngine and never a QQmlApplicationEngine" \
  "s|'QQmlEngineC\[12\]E'|'QQmlEngineNoSuchCtor'|"

echo
echo "── section 5: non-Latin rendering ──"

# F1 — the control's second family becomes the shell's own, so 'A' measures the
#      same under both and every comparison below is a tautology.
mutate F1 "the family property is honoured at all" \
  's|id: ctrlA; font.family: "%s"|id: ctrlA; font.family: "JetBrains Mono"|'

# F2 — the monospace premise the whole width argument rests on.
mutate F2 "JetBrains Mono is monospaced here" \
  's|id: mW; font.family: "%s"; font.pixelSize: 32; text: "W"|id: mW; font.family: "DejaVu Sans"; font.pixelSize: 32; text: "W"|'

# F3 — the measured advance is replaced by the shell family's own, which is
#      exactly what a .notdef box measures.
mutate F3 "CJK is drawn by a font that covers it" \
  's|adv="\$(ffield "s_\$key")"|adv="$f_a"|'

# F4 — the covering-family query returns nothing: the vacuity floor.
mutate F4 "CJK can be rendered at all" \
  's|fc-list ":charset=\$1" family 2>/dev/null|fc-list ":charset=zzz$1" family 2>/dev/null|'

# F5 — fontconfig is made to claim the shell family covers every script. That
#      arm used to pass on fontconfig's word alone, which would have turned the
#      whole section green over nothing.
mutate F5 "CJK is covered by JetBrains Mono itself" \
  's|fc-list -q ":family=\$SHELL_FAM:charset=\$cp" 2>/dev/null \&\& self=1|self=1|'

echo
printf 'mutants applied=%d, failed-to-apply=%d, caught=%d, SURVIVED=%d\n' \
    "$applied" "$noapply" "$caught" "$survived"
tree_clean || { echo "ABORT: tree dirty at end of run" >&2; exit 3; }
echo "the tree matches HEAD"
[ "$survived" -eq 0 ] && [ "$noapply" -eq 0 ]
