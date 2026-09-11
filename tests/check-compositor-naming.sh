#!/usr/bin/env bash
# What Settings calls the compositor, and what it is allowed to call it.
#
# ── Why this exists ──────────────────────────────────────────────────────────
# BASE-013's third criterion is that compositor names stay implementation
# details for normal users. Settings is a normal-user surface, and its
# compositor control failed the criterion twice over: it labelled its options
# with the raw ids "hyprland" and "niri" — a list of upstream project names in
# lower case — and its help text printed `Compositor.detected`, another raw id.
#
# It also had a second, unrelated defect that only shows up once you go looking
# at the same lines: labwc was missing from the option list entirely, while
# Compositor.isValidName() has always accepted it and CompositorService has
# always loaded LabwcBackend.qml. A Floating user could not pin their own
# compositor from Settings at all.
#
# ── The trap this file is built to avoid ─────────────────────────────────────
# There are now THREE names for a compositor in this shell, and the fix for the
# above is only correct if they stay separate:
#
#   the id           "hyprland" | "niri" | "labwc"  — stored, detected,
#                    branched on, written to config_Provider.json
#   displayName      the adapter's own name, forwarded from the backend — what
#                    the About panel writes down, pinned by
#                    check-compositor-backends.sh and compositor-facade-test.qml
#   presentedName()  the product name shown to users
#
# So this checker does not merely assert that the labels changed. It asserts
# that the VALUES did not, that displayName was left alone, and that the ids and
# the product names are disjoint sets — a "fix" that renamed displayName, or one
# that translated the values, would pass a naive label check and break the
# shell.
#
# Runs headless, greps only, starts nothing.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
STATE="$root/src/state/Compositor.qml"
MISC="$root/src/services/config_tab/pages/MiscPage.qml"
CDIR="$root/src/services/compositor"

pass=0
fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1${2:+  — $2}"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
is()   { local desc="$1" want="$2" got="$3"
         if [ "$got" = "$want" ]; then ok "$desc"
         else bad "$desc" "want [$want] got [$got]"; fi; }

IDS=(hyprland niri labwc)

# ── The map exists and is the single source of the product names ─────────────
want "Compositor.qml exists and is non-empty" test -s "$STATE"
want "MiscPage.qml exists and is non-empty"   test -s "$MISC"
want "Compositor declares presentedName()" \
     grep -q 'function presentedName(' "$STATE"
want "…and a modeName property built from it" \
     grep -qE 'property string modeName:.*presentedName' "$STATE"

# Every id this shell accepts must have a product name. An id that
# isValidName() takes but presentedName() does not answer for is a user staring
# at a blank label — which is exactly the state labwc was in in the option list.
for id in "${IDS[@]}"; do
    want "isValidName() accepts \"$id\"" \
         grep -qE "n === \"$id\"" "$STATE"
    if grep -A6 'function presentedName(' "$STATE" | grep -q "\"$id\""; then
        ok "…and presentedName() has a word for it"
    else
        bad "…and presentedName() has a word for it" "no branch for $id"
    fi
done

# An unknown compositor must get "" and not a guess. The shell runs under sway,
# river and KDE too, and inventing a mode name for one of those would be a
# worse answer than none.
if grep -A8 'function presentedName(' "$STATE" | grep -qE '^\s*:\s*"" *$'; then
    ok "an unsupported compositor gets no invented name"
else
    bad "an unsupported compositor gets no invented name" \
        "presentedName has no empty default branch"
fi

# ── The three names stay three names ─────────────────────────────────────────
# The product names, read out of the map rather than typed here, so this file
# cannot drift from it.
mapfile -t PRESENTED < <(
    sed -n '/function presentedName(/,/^    }/p' "$STATE" |
    grep -oE '\? "[A-Za-z]+"' | grep -oE '"[A-Za-z]+"' | tr -d '"'
)
is "presentedName() answers for exactly the three supported ids" "3" "${#PRESENTED[@]}"

for word in "${PRESENTED[@]}"; do
    low="$(printf '%s' "$word" | tr 'A-Z' 'a-z')"
    clash=""
    for id in "${IDS[@]}"; do [ "$low" = "$id" ] && clash="$id"; done
    if [ -z "$clash" ]; then
        ok "the product name \"$word\" is not one of the ids"
    else
        bad "the product name \"$word\" is not one of the ids" "it is the id $clash"
    fi
done

# displayName is the adapter's own name and is NOT the product name. If a
# backend ever declares one of the product words, the two contracts have been
# collapsed and the About panel starts lying about which compositor is running.
for b in HyprlandBackend NiriBackend LabwcBackend; do
    dn="$(grep -oE 'displayName: *"[^"]*"' "$CDIR/$b.qml" | head -n1 | cut -d'"' -f2)"
    if [ -z "$dn" ]; then
        bad "$b still declares a displayName" "none found"
        continue
    fi
    hit=""
    for word in "${PRESENTED[@]}"; do [ "$dn" = "$word" ] && hit="$word"; done
    if [ -z "$hit" ]; then
        ok "$b's displayName (\"$dn\") is still the adapter's own name"
    else
        bad "$b's displayName (\"$dn\") is still the adapter's own name" \
            "it has been replaced with the product name $hit"
    fi
done

# ── The Settings control ─────────────────────────────────────────────────────
OPTS="$(sed -n '/options: \[/,/\]/p' "$MISC")"
want "the compositor control still has an option list" test -n "$OPTS"

# VALUES are ids and go straight into config_Provider.json. Translating one
# would write a compositor name isValidName() rejects, and the override would be
# silently dropped on the next read.
for id in auto "${IDS[@]}"; do
    if printf '%s' "$OPTS" | grep -q "value: \"$id\""; then
        ok "the control offers the id \"$id\" as a value"
    else
        bad "the control offers the id \"$id\" as a value" "missing"
    fi
done

# LABELS are the product's words. No label may be an id.
mapfile -t LABELS < <(printf '%s' "$OPTS" | grep -oE 'label: *"[^"]*"' | cut -d'"' -f2)
is "every option carries a label" "4" "${#LABELS[@]}"
for l in "${LABELS[@]}"; do
    low="$(printf '%s' "$l" | tr 'A-Z' 'a-z')"
    clash=""
    for id in "${IDS[@]}"; do [ "$low" = "$id" ] && clash="$id"; done
    if [ -z "$clash" ]; then
        ok "the option labelled \"$l\" is not a compositor's name"
    else
        bad "the option labelled \"$l\" is not a compositor's name" "it is \"$clash\""
    fi
done

# …and each product name must actually appear as a label, or the map is
# decorative.
for word in "${PRESENTED[@]}"; do
    if printf '%s' "$OPTS" | grep -q "label: *\"$word\""; then
        ok "\"$word\" is offered in the control"
    else
        bad "\"$word\" is offered in the control" "not among the labels"
    fi
done

# ── The rest of the page says nothing raw ────────────────────────────────────
# Both the Active row and the help text printed ids before. `Compositor.name`
# and `Compositor.detected` are ids; interpolating either into a user-visible
# string is the defect, so their absence from this page is the assertion.
#
# THIS ASSERTION WAS WRITTEN WRONG THE FIRST TIME AND THE MUTATION CAUGHT IT.
# It read `grep "text:" MiscPage.qml | grep "$prop"`, i.e. it only looked at the
# single line the `text:` binding starts on. The Active row's binding is three
# lines long, so putting `Compositor.name` on its CONTINUATION line — the exact
# defect, rendered to the exact same user — left the checker green at 42/0.
# Proven, not reasoned: that mutation was applied and the suite passed.
#
# So the assertion is now over the whole file. These two properties are ids and
# this page has no non-display use for either; if one ever acquires a legitimate
# use here, this check has to become a QML-aware one rather than be widened.
# Comments are stripped first — this file's own commentary explains the defect
# by naming the properties, and a checker that cannot tell code from a comment
# would make that commentary unwritable.
CODE="$(sed 's|//.*$||' "$MISC")"
for prop in "Compositor.name" "Compositor.detected"; do
    hits="$(printf '%s\n' "$CODE" | grep -nF "$prop")"
    if [ -n "$hits" ]; then
        bad "the page never puts $prop in front of a user" \
            "$(printf '%s' "$hits" | head -n1)"
    else
        ok "the page never puts $prop in front of a user"
    fi
done

# The help text names features. Those names are only true as long as the
# backends declare what the sentence claims, so the claims are checked against
# the capability maps — this is the assertion that stops the prose rotting
# silently when a backend gains or loses a capability.
cap_true_in() {  # cap_true_in <capability> <Backend> -> prints true|false|?
    sed -n '/readonly property var capabilities/,/})/p' "$CDIR/$2.qml" |
        grep -oE "^\s*$1: *(true|false)" | grep -oE '(true|false)' | head -n1
}
hypr_only=(accentBorder gaps tilingLayout keyboardInterception screenShader specialWorkspace)
for cap in "${hypr_only[@]}"; do
    h="$(cap_true_in "$cap" HyprlandBackend)"
    n="$(cap_true_in "$cap" NiriBackend)"
    l="$(cap_true_in "$cap" LabwcBackend)"
    is "the page's claim holds: $cap is Tiling's alone" "true/false/false" "$h/$n/$l"
done
is "the page's claim holds: overview is Scrolling's alone" "false/true/false" \
   "$(cap_true_in overview HyprlandBackend)/$(cap_true_in overview NiriBackend)/$(cap_true_in overview LabwcBackend)"
is "the page's claim holds: only Floating cannot move a window" "true/true/false" \
   "$(cap_true_in windowMove HyprlandBackend)/$(cap_true_in windowMove NiriBackend)/$(cap_true_in windowMove LabwcBackend)"
# Night light is deliberately NOT in the sentence. If it ever stops being
# universal, the sentence has to grow a clause, and this is what will say so.
is "night light is on all three, so the page is right not to mention it" \
   "true/true/true" \
   "$(cap_true_in nightLight HyprlandBackend)/$(cap_true_in nightLight NiriBackend)/$(cap_true_in nightLight LabwcBackend)"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
