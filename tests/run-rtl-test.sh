#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-rtl-test.sh — right-to-left layout, measured (roadmap P2-004, "RTL").
#
#  ── The row this closes, and the claim it replaces ──────────────────────────
#
#  The ledger carried "RTL: fonts present, the image cannot render it" from
#  round 1 to round 19. Round 20 ran it and it is FALSE: through the real
#  engine, Arabic ا falls out of the hardcoded JetBrains Mono to DejaVu Sans
#  Mono, Hebrew א to DejaVu Sans, Thai ก to Droid Sans Thai and Devanagari अ to
#  Droid Sans Devanagari — four image-owned rpms. The image renders all of them.
#
#  What was actually missing is LAYOUT. Before this suite there were zero
#  `LayoutMirroring` and zero `layoutDirection` in the whole of src/, so a
#  reader of any of those scripts got a settings row whose label sat on the
#  opposite side from the side they read from. That is the whole of the row and
#  it is what is measured here.
#
#  ── Three questions, and only one of them is about the shell ────────────────
#
#  1. Does Qt's layout direction follow the locale ON THIS IMAGE? The image
#     installs `glibc-langpack-en` only, so the answer was not obvious and is
#     not assumed: the same fixture is run twice, once with the locale scrubbed
#     and once under LANG=ar_EG.UTF-8, and the two are required to DISAGREE.
#     A single run that says "RightToLeft" proves nothing — it could say that
#     whatever the environment is.
#  2. Does the ENGINE mirror? The control for question 3: a bare Item with a
#     left-anchored child must move when mirrored, or the runner's Qt does not
#     implement this and every verdict is about the toolkit.
#  3. Does the SHIPPED settings row mirror? Instantiated, mirrored, and the
#     positions read off the live objects.
#
#  ── What this deliberately does NOT claim ───────────────────────────────────
#
#  Mirroring acts on anchors and positioners. It cannot touch an explicit `x:`,
#  and it does not reach anything the shell paints inside a PanelWindow, because
#  those roots do not declare it yet. Both are PINNED here, exactly and in both
#  directions, so the remaining half is a number somebody can watch rather than
#  a sentence somebody can forget. A suite that reported "RTL: done" over a
#  mirrored settings page and an unmirrored bar would be worse than no suite.
#
#  ── Four outcomes, not three (round 32) ────────────────────────────────────
#
#  PASS / FAIL / SKIP / CANTRUN. The last one is new and it is the reason this
#  suite stopped being permanently red on the Arch CI runner without anything
#  being swept under a skip. SKIP means the machine is simply not the thing
#  (not a booted APEX host, so a documented default is probed instead).
#  CANTRUN means a NAMED, MEASURED precondition came back false and the reason
#  is printed on the line. Section 1's three direction rows are the only ones
#  gated that way, the gate is switched off entirely on a booted APEX host, and
#  it cannot engage on a machine where the direction flipped anyway — so an
#  excuse whose own reason has stopped being true goes red instead of quiet.
#
#  Section 2's right-to-left pass names the ROUTE that supplied its direction
#  in every line it prints: "theme" (what APEX ships) or "preload" (a machine
#  that had to be handed libKF6I18n, which the CI runner does). They are
#  different claims and the suite must never print the same green for both.
#
#  Headless: -platform offscreen, WAYLAND_DISPLAY removed from the environment.
#
#  Run from anywhere: ./tests/run-rtl-test.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

pass=0; fail=0; skip=0; cantrun=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s%s\n' "$1" "${2:+  — $2}"; fail=$((fail + 1)); }
skp() { printf 'SKIP  %s%s\n' "$1" "${2:+  — $2}"; skip=$((skip + 1)); }

# A FOURTH outcome, and it is not decoration. This program's rule is that
# refusal, absence and could-not-run are three different answers and a gate
# that collapses them is the dominant defect family here — and until round 32
# this suite collapsed two of them into `skp`: "this is not a booted APEX host"
# (absence: the machine simply is not the thing, and the run continues against
# a documented default) read exactly like "the probe printed no APEXDIR line"
# (could-not-run: the measurement was attempted and produced nothing).
#
# `cant` is the second of those. It means: the measurement WAS attempted, a
# NAMED and MEASURED precondition came back false, and the reason is printed on
# the line. It is not a pass, it does not fail the suite, and it is counted
# separately in the totals so a machine that could not run half of section 1
# cannot read as a machine that ran it.
cant() { printf 'CANTRUN  %s%s\n' "$1" "${2:+  — $2}"; cantrun=$((cantrun + 1)); }
section() { printf '\n── %s ──\n' "$1"; }
finish() {
    printf '\nrun-rtl-test: %d passed, %d failed, %d skipped, %d could-not-run\n' \
           "$pass" "$fail" "$skip" "$cantrun"
    [ "$fail" -eq 0 ]
}

# Fedora suffixes it, Arch does not and keeps it off PATH. Both spellings, or
# this skips on the distribution the shell is actually developed on.
runner=""
for c in qmltestrunner-qt6 qmltestrunner \
         /usr/lib64/qt6/bin/qmltestrunner /usr/lib/qt6/bin/qmltestrunner; do
    if command -v "$c" >/dev/null 2>&1; then runner="$c"; break; fi
done
if [[ -z "$runner" ]]; then
    echo "SKIP: qmltestrunner not installed (qt6-qtdeclarative-devel)."
    echo "      This is a COULD-NOT-RUN. No assertion below was evaluated."
    exit 0
fi

# ── 1. what actually drives Qt's layout direction ────────────────────────────
section "1. the layout direction comes from a translation catalogue, not from the locale"

probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT INT TERM
cat > "$probe/tst_dir.qml" <<'QMLEOF'
import QtQuick
import QtTest
TestCase {
    name: "dir"
    function test_000_report() {
        console.log("APEXDIR=" + Qt.application.layoutDirection
                    + " APEXTEXTDIR=" + Qt.locale().textDirection
                    + " APEXLOCALE=" + Qt.locale().name)
        verify(true)
    }
}
QMLEOF

# QT_LOGGING_RULES, because console.log from QML is a qt.qml category message
# and the runner's default rules drop it. A probe whose output is filtered away
# reads exactly like a probe that measured nothing.
#
# The platform theme is passed IN rather than inherited, and that is the whole
# point of this section. Round 22's version inherited QT_QPA_PLATFORMTHEME from
# whoever ran it, which is why it was green on a developer's desktop and red the
# first time the mutation harness ran it under `env -i`.
probe_raw() {   # probe_raw <locale or empty> <platform theme or empty>
    local l="$1" t="$2"
    env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        -u LANG -u LC_ALL -u LANGUAGE -u QT_QPA_PLATFORMTHEME \
        ${l:+LANG="$l"} ${l:+LC_ALL="$l"} ${t:+QT_QPA_PLATFORMTHEME="$t"} \
        QT_LOGGING_RULES='*.debug=true;qt.*=false' QT_QPA_PLATFORM=offscreen \
        timeout 60 "$runner" -platform offscreen -input "$probe/tst_dir.qml" 2>&1 \
        | sed -n 's/.*APEXDIR=\([0-9]*\) APEXTEXTDIR=\([0-9]*\) .*/\1 \2/p' | head -1
}
app_dir()  { probe_raw "$1" "$2" | cut -d' ' -f1; }   # Qt.application.layoutDirection
text_dir() { probe_raw "$1" "$2" | cut -d' ' -f2; }   # QLocale's own opinion

# Which platform theme to ask about. On a booted APEX this is read out of the
# image's own /etc/environment, so the row below is about what this system
# actually ships rather than about a name typed into a test; anywhere else it is
# the documented default and the suite says which it used.
THEME="qt6ct"; theme_src="the documented APEX default (this is not a booted APEX host)"
if [ -e /run/ostree-booted ] && [ -r /etc/environment ]; then
    from_env="$(sed -n 's/^QT_QPA_PLATFORMTHEME=//p' /etc/environment | tail -1)"
    if [ -n "$from_env" ]; then
        THEME="$from_env"; theme_src="/etc/environment on this booted image"
        ok "the image sets QT_QPA_PLATFORMTHEME=$THEME — the thing the direction turns out to depend on (source: $theme_src)"
    else
        bad "the image sets QT_QPA_PLATFORMTHEME" \
            "/etc/environment on this booted host names no platform theme, so nothing here will mirror"
    fi
else
    skp "the image sets QT_QPA_PLATFORMTHEME" \
        "not a booted APEX host — probing with $THEME, $theme_src"
fi

L_RTL="ar_EG.UTF-8"; L_RTL2="he_IL.UTF-8"; L_NOCAT="ur_PK.UTF-8"

# QLocale's own opinion FIRST, and separately, because the finding this section
# exists to record is that the two disagree. If QLocale could not even parse the
# locale name there is nothing to measure and everything below would be noise.
td_rtl="$(text_dir "$L_RTL" "$THEME")"
if [ -z "$td_rtl" ]; then
    cant "Qt can be asked for a layout direction at all" \
         "the probe printed no APEXDIR line — nothing below was evaluated"
    cant "the application direction follows the locale when a catalogue exists" "same"
    cant "with no platform theme nothing flips" "same"
    cant "an RTL language Qt has no catalogue for does not flip" "same"
else
    [ "$td_rtl" = "1" ] \
        && ok "QLocale calls $L_RTL right-to-left, on an image that installs glibc-langpack-en only" \
        || bad "QLocale calls $L_RTL right-to-left" "textDirection=$td_rtl"

    with_theme_rtl="$(app_dir "$L_RTL"   "$THEME")"
    with_theme_heb="$(app_dir "$L_RTL2"  "$THEME")"
    with_theme_ltr="$(app_dir ""         "$THEME")"
    no_theme_rtl="$(app_dir  "$L_RTL"    "")"
    no_theme_ltr="$(app_dir  ""          "")"
    nocat_app="$(app_dir     "$L_NOCAT"  "$THEME")"
    nocat_text="$(text_dir   "$L_NOCAT"  "$THEME")"

    qt_cats="$(ls /usr/share/qt6/translations/qt_*.qm 2>/dev/null | wc -l)"

    # ── THE PRECONDITION. Measured round 31, made load-bearing round 32. ─────
    #
    # This block sits ABOVE the three rows it gates, and that is the whole
    # point of round 32. Those three rows require a right-to-left APPLICATION
    # direction, and whether a machine can produce one at all is a property of
    # its qt6ct build, not of APEX. Measuring that first is the difference
    # between "APEX's right-to-left layout is broken" and "this machine has no
    # process that loads the Qt catalogue" — two claims the suite used to print
    # with the same three red lines.
    #
    # This suite has said since round 23 that "the platform theme supplies the
    # right-to-left direction", and the pair above does isolate the theme —
    # but only as a CARRIER. The theme's plugin does not load a catalogue at
    # all. Four runs, one process each, `strace -e openat` naming every
    # `qt_*.qm` opened, on Qt 6.10.3 with LANG=LC_ALL=ar_EG.UTF-8:
    #
    #   QT_QPA_PLATFORMTHEME=qt6ct  -> RTL, opened qt_ar.qm and qt_en.qm
    #   a bogus theme name          -> LTR, opened none
    #   no platform theme           -> LTR, opened none
    #   no theme + LD_PRELOAD of
    #     libKF6I18n.so.6           -> RTL, opened qt_ar.qm and qt_en.qm
    #
    # The last one settles it: with NO platform theme, merely loading KF6's
    # i18n library into the process installs the Qt catalogue and flips the
    # direction. `nm -DC` and `strings` on Fedora's libqt6ct.so find no
    # QTranslator code in the plugin itself; `ldd` finds eight KF6 libraries
    # behind it, because Fedora ships a post-release git snapshot
    # (qt6ct-0.11-13.20250907git23a985f) built with the KDE integration.
    #
    # That is also why this section was RED on the GitHub Arch runner from the
    # day it landed until round 32. Arch ships upstream release qt6ct 0.11-8,
    # read out of run 35384106245's own log; the runner has 64 qt_*.qm
    # including qt_ar.qm and `QLocale calls ar_EG right-to-left` PASSES there.
    # Nothing is missing except a process that loads the catalogue.
    #
    # Round 32 did two separate things about that, and they answer two
    # different questions. The GATE below turns those three reds into named
    # could-not-runs on a machine whose theme measurably carries no loader —
    # that is about the RUNNER. And ci.yml now installs `ki18n` there, which
    # lets the suite take the "preload" route in section 2 — that is about
    # APEX, and it is the half worth having: the shipped row is now measured
    # under a real right-to-left direction on Arch and Qt 6.11.2 as well as on
    # Fedora and Qt 6.10.3. Do not let the two collapse into one sentence.
    #
    # So the row below is an IF AND ONLY IF, and it is the assertion that tells
    # the two machines apart instead of leaving one of them unexplained. It can
    # fail in both directions, and the self-test under it proves the predicate
    # is capable of answering NO.
    qtool=""; themedir=""
    for q in qmake6 qmake-qt6 qmake; do
        command -v "$q" >/dev/null 2>&1 || continue
        d="$("$q" -query QT_INSTALL_PLUGINS 2>/dev/null)"
        [ -n "$d" ] && [ -d "$d/platformthemes" ] && { themedir="$d/platformthemes"; qtool="$q -query"; break; }
    done
    if [ -z "$themedir" ]; then
        # FOUND 19's shape: the directory differs by distribution and a
        # hardcoded one reports "absent" on a machine that has it. Both known
        # spellings are tried and the one used is printed.
        for d in /usr/lib64/qt6/plugins/platformthemes /usr/lib/qt6/plugins/platformthemes; do
            [ -d "$d" ] && { themedir="$d"; qtool="a hardcoded fallback"; break; }
        done
    fi
    plugin=""
    for cand in "$themedir/libq$THEME.so" "$themedir/lib$THEME.so"; do
        [ -n "$themedir" ] && [ -e "$cand" ] && { plugin="$cand"; break; }
    done
    echo "      note: platform theme plugins at ${themedir:-<not found>} (via ${qtool:-nothing}); $THEME plugin: ${plugin:-<absent>}"

    # Captured into a variable and matched with a case, NEVER `ldd | grep -q`:
    # under `set -o pipefail` a grep -q that MATCHES closes the pipe, ldd dies
    # with SIGPIPE and the pipeline's status is 141, so the check would answer
    # "no" precisely when the answer is yes.
    #
    # THREE-VALUED, not two, and that is round 32's correction. Until now an
    # `ldd` that FAILED — unreadable file, not an ELF, a linker that refused —
    # fell into the same `*)` arm as an ELF that genuinely links no KF6I18n and
    # printed `0`. That was harmless while nothing depended on it; it is not
    # harmless now that three assertions are gated on the answer, because a
    # broken instrument would excuse exactly the reds it exists to explain.
    # "Permission denied is not absence" is the same defect this tree has met
    # about fourteen times. `err` is a fourth answer and it goes RED.
    #
    # `ldd` and not `readelf -d`: the claim is "the library ends up in the
    # process", which is TRANSITIVE. Fedora's qt6ct may reach libKF6I18n
    # through another KF6 library, and DT_NEEDED is direct-only.
    i18n_of() {   # <elf> -> prints 1 | 0 | err
        local out st
        out="$(ldd "$1" 2>&1)"; st=$?
        if [ "$st" -ne 0 ]; then printf 'err'; return; fi
        case "$out" in *libKF6I18n*) printf '1' ;; *) printf '0' ;; esac
    }

    # 1 = the theme's plugin carries a Qt translation loader
    # 0 = it measurably does not
    # none = there is no plugin file for $THEME on this machine
    # err  = the question could not be answered; NOTHING may be excused on it
    THEME_I18N="none"
    if [ -z "$plugin" ]; then
        cant "the direction flips if and only if the theme's plugin drags in a Qt translation loader" \
             "no plugin file for $THEME under ${themedir:-<no plugin dir>} — so nothing was concluded about why"
    else
        i18n_linked="$(i18n_of "$plugin")"
        THEME_I18N="$i18n_linked"
        if [ "$i18n_linked" = "err" ]; then
            bad "the direction flips if and only if the theme's plugin drags in a Qt translation loader" \
                "ldd could not read $plugin, so the precondition below is UNMEASURED — this is a broken instrument, not a machine without KF6I18n, and nothing is excused on it"
        fi
        if [ "$i18n_linked" = "err" ]; then
            :   # already reported RED above; do not print a second verdict
        elif [ "$with_theme_rtl" = "1" ] && [ "$i18n_linked" = "1" ]; then
            ok "the direction flips if and only if the theme's plugin drags in a Qt translation loader — it flipped, and $plugin links libKF6I18n"
        elif [ "$with_theme_rtl" = "0" ] && [ "$i18n_linked" = "0" ]; then
            ok "the direction flips if and only if the theme's plugin drags in a Qt translation loader — it did NOT flip, and $plugin links no libKF6I18n, so this machine's red above is that build of $THEME and not APEX"
        elif [ "$with_theme_rtl" = "1" ]; then
            bad "the direction flips if and only if the theme's plugin drags in a Qt translation loader" \
                "it flipped while $plugin links no libKF6I18n — something ELSE in this process loads qt_*.qm and round 31's mechanism is incomplete"
        else
            bad "the direction flips if and only if the theme's plugin drags in a Qt translation loader" \
                "$plugin links libKF6I18n and the direction still did not flip — the carrier is present and the catalogue is not being loaded; look at qt_*.qm ($qt_cats installed) and at the Qt version"
        fi

        # The predicate must be able to answer NO, or the row above is a
        # constant dressed as a measurement. Qt's own core library is the
        # control: nothing in qtbase links KF6, so an affirmative here would
        # mean `i18n_of` says yes to everything.
        ctl_lib=""
        for l in $(ldd "$plugin" 2>/dev/null | awk '/libQt6Core\.so/ {print $3}'); do
            [ -e "$l" ] && { ctl_lib="$l"; break; }
        done
        if [ -z "$ctl_lib" ]; then
            cant "…and the predicate can answer NO" \
                 "could not resolve libQt6Core.so.6 from $plugin to use as the control"
        elif [ "$(i18n_of "$ctl_lib")" = "0" ]; then
            ok "…and the predicate can answer NO — the same question about $ctl_lib, which links no KF6, comes back negative"
        else
            bad "…and the predicate can answer NO" \
                "$ctl_lib reported as linking libKF6I18n; the predicate says yes to everything and the row above proves nothing"
        fi

        # …and it must be able to answer the THIRD thing, because round 32
        # gates three assertions on this predicate and the whole reason for
        # making it three-valued is that a FAILED ldd used to be indis-
        # tinguishable from an ELF that links no KF6I18n. A predicate whose
        # error arm has never been shown to fire is a two-valued predicate with
        # a comment. `ldd` on a non-ELF exits non-zero on both machines this
        # suite runs on, so the control costs one process and no assumptions.
        notelf="$probe/not-an-elf"
        printf 'this is not an ELF\n' > "$notelf"
        if [ "$(i18n_of "$notelf")" = "err" ]; then
            ok "…and the predicate can answer ERR — asked about a file that is not an ELF it reports the question as unanswerable, rather than as a negative"
        else
            bad "…and the predicate can answer ERR" \
                "a non-ELF came back as $(i18n_of "$notelf") — a failed ldd is being read as 'links no KF6I18n', which is the exact confusion the gate below must never make"
        fi
    fi

    # ── THE GATE, and the two things it is NOT allowed to be ────────────────
    #
    # The three rows below all require a right-to-left APPLICATION direction.
    # Whether a machine can produce one is the precondition just measured, so
    # when it measurably cannot, those rows report a NAMED could-not-run that
    # carries the reason instead of three red lines that read like an APEX
    # defect. That is the round-32 decision, and it comes with two hard limits.
    #
    # ONE: it can never engage on a booted APEX host. On the machine this
    # product actually ships to, a theme that cannot supply the direction IS
    # the defect, and there is nothing to excuse. So `/run/ostree-booted`
    # switches the gate off entirely — which is also why every mutant in
    # tests/mutate-rtl.sh that breaks one of these rows still goes red here:
    # the development machine is a booted APEX host and never reaches the gate.
    #
    # TWO: it can never engage when the direction DID flip. If a machine whose
    # $THEME carries no translation loader produces a right-to-left direction
    # anyway, the stated reason has stopped being the true one — the rows run,
    # they pass, and the iff above goes RED saying round 31's mechanism is
    # incomplete. An excuse that survives its own reason being false is not a
    # precondition, it is a mask.
    #
    # `err` is deliberately absent from the case below: an unmeasurable
    # precondition excuses nothing and has already gone red.
    GATE_REASON=""
    if [ ! -e /run/ostree-booted ] && [ "$with_theme_rtl" != "1" ]; then
        case "$THEME_I18N" in
            0)    GATE_REASON="MEASURED: $plugin links no libKF6I18n, which is the library that loads the Qt catalogue and flips the direction (FOUND 26). This machine's $THEME build carries no route to one, so it cannot produce a right-to-left application direction at all — nothing here is a statement about APEX" ;;
            none) GATE_REASON="MEASURED: there is no $THEME plugin on this machine at all (looked under ${themedir:-<no plugin dir>}), so no platform theme can supply a Qt catalogue here" ;;
        esac
    fi

    if [ -n "$GATE_REASON" ]; then
        cant "with $THEME loaded the direction follows the locale" "$GATE_REASON"
        cant "under $L_RTL2 it is RightToLeft" "$GATE_REASON"
        cant "it is the platform theme that supplies the right-to-left direction" "$GATE_REASON"
    else
        # The load-bearing pair. Neither half means anything alone: a run that
        # answers RightToLeft could answer that whatever the environment is, and a
        # run that answers LeftToRight could be a probe that measured nothing.
        if [ "$with_theme_rtl" = "1" ] && [ "$with_theme_ltr" = "0" ]; then
            ok "with $THEME loaded the direction follows the locale — $L_RTL gives RightToLeft, scrubbed gives LeftToRight"
        elif [ "$with_theme_rtl" = "$with_theme_ltr" ]; then
            bad "with $THEME loaded the direction follows the locale" \
                "both runs answered $with_theme_rtl — this machine cannot produce a right-to-left application direction, so CfgRow's switch can never fire here"
        else
            bad "with $THEME loaded the direction follows the locale" \
                "$L_RTL gave $with_theme_rtl and the scrubbed run gave $with_theme_ltr"
        fi

        [ "$with_theme_heb" = "1" ] \
            && ok "and under $L_RTL2 it is RightToLeft too — a second RTL locale, so this is not one lucky name" \
            || bad "under $L_RTL2 it is RightToLeft" "got $with_theme_heb"

        # THE MECHANISM, and the reason this section was rewritten. Qt decides the
        # application direction by translating the string QT_LAYOUT_DIRECTION and
        # comparing the answer to "RTL" -- so it needs a LOADED CATALOGUE, and
        # quickshell installs no QTranslator of its own. What supplies one on a
        # shipped APEX desktop is the qt6ct platform theme, which is configured for
        # a dark palette (files/system/qt6ct/qt6ct.conf) and has no idea it is
        # holding up right-to-left layout. Drop it and every mirrored surface
        # silently stops mirroring with nothing red anywhere.
        #
        # Round 31 narrowed that: qt6ct is the CARRIER, not the mechanism. Fedora's
        # build links libKF6I18n, and it is KF6I18n's startup that installs the Qt
        # catalogue — see the block after the ur_PK control, which measures it with
        # the theme removed entirely.
        if [ "$no_theme_rtl" = "0" ] && [ "$with_theme_rtl" = "1" ]; then
            ok "it is the platform theme that supplies the right-to-left direction — the same $L_RTL run with no platform theme gives LeftToRight"
        elif [ "$no_theme_rtl" = "1" ]; then
            ok "the direction no longer needs a platform theme — $L_RTL is RightToLeft without one (the dependency this suite pins has been removed; say so in the ledger)"
        else
            bad "it is the platform theme that supplies the right-to-left direction" \
                "with theme=$with_theme_rtl, without=$no_theme_rtl — the pair does not isolate the theme"
        fi
    fi

    [ "$no_theme_ltr" = "0" ] \
        && ok "with neither a locale nor a theme it is LeftToRight, which is the floor everything above is measured from" \
        || bad "with neither a locale nor a theme it is LeftToRight" "got $no_theme_ltr"

    # THE CEILING. Urdu is right-to-left and Qt's own QLocale says so in the
    # same run; Qt ships no qt_ur.qm, so the application direction stays
    # LeftToRight. Every RTL language without a Qt catalogue is in this bucket
    # -- Pashto, Sindhi, Divehi, Yiddish -- and no amount of QML reaches them.
    # This is pinned rather than fixed, the way check-reduce-motion.sh pins the
    # int literals no switch can touch.
    if [ "$nocat_text" = "1" ] && [ "$nocat_app" = "0" ]; then
        ok "an RTL language Qt has no catalogue for does NOT flip — $L_NOCAT is right-to-left to QLocale and LeftToRight to the application ($qt_cats qt_*.qm installed, none of them ur)"
    elif [ "$nocat_text" != "1" ]; then
        skp "an RTL language Qt has no catalogue for does NOT flip" \
            "QLocale does not call $L_NOCAT right-to-left here (textDirection=$nocat_text) — COULD-NOT-RUN"
    else
        bad "an RTL language Qt has no catalogue for does NOT flip" \
            "$L_NOCAT gave application direction $nocat_app — if a qt_ur.qm has appeared, move this pin deliberately"
    fi


    # The mechanism, pinned directly rather than through its carrier: no
    # platform theme at all, one extra library in the process, and the
    # direction flips. The day KF6I18n stops installing the Qt catalogue on
    # startup this goes RED and says that the thing APEX's mirroring actually
    # rests on has moved.
    kf6lib=""
    for l in $(ldconfig -p 2>/dev/null | awk '/libKF6I18n\.so/ {print $NF}'); do
        [ -e "$l" ] && { kf6lib="$l"; break; }
    done
    preload_probe() {   # preload_probe <locale or empty> -> application direction
        env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
            -u LANG -u LC_ALL -u LANGUAGE -u QT_QPA_PLATFORMTHEME \
            ${1:+LANG="$1"} ${1:+LC_ALL="$1"} LD_PRELOAD="$kf6lib" \
            QT_LOGGING_RULES='*.debug=true;qt.*=false' QT_QPA_PLATFORM=offscreen \
            timeout 60 "$runner" -platform offscreen -input "$probe/tst_dir.qml" 2>&1 \
            | sed -n 's/.*APEXDIR=\([0-9]*\) .*/\1/p' | head -1
    }
    if [ -z "$kf6lib" ]; then
        cant "a Qt translation loader ALONE flips the direction, with no platform theme" \
             "no libKF6I18n.so on this machine — on a machine without it nothing can load qt_ar.qm by itself, and the supplied-loader route below is unavailable"
        cant "…and the supplied loader does not flip the direction BY ITSELF" "same"
    else
        preload_rtl="$(preload_probe "$L_RTL")"
        preload_ltr="$(preload_probe "")"
        if [ "$preload_rtl" = "1" ] && [ "$no_theme_rtl" = "0" ]; then
            ok "a Qt translation loader ALONE flips the direction, with no platform theme — $kf6lib preloaded gives RightToLeft where the same run without it gives LeftToRight"
        elif [ -z "$preload_rtl" ]; then
            cant "a Qt translation loader ALONE flips the direction, with no platform theme" \
                 "the preloaded probe printed no APEXDIR line — not a pass"
        else
            bad "a Qt translation loader ALONE flips the direction, with no platform theme" \
                "preloaded=$preload_rtl, plain=$no_theme_rtl — if both are 1 the theme was never needed; if the preloaded run is 0 then KF6I18n no longer installs the Qt catalogue and APEX's mirroring rests on something else again"
        fi

        # THE CONTROL THAT MAKES THE ROUTE USABLE, and section 2 is why it
        # exists. On a machine whose own platform theme carries no translation
        # loader, section 2's right-to-left pass is run with this library
        # preloaded — so the two fixture passes differ in the LIBRARY as well
        # as in the locale, and without this row "the row mirrored under
        # ar_EG" could equally be "the row mirrored when KF6I18n was loaded".
        # The library must move the direction ONLY through the locale.
        if [ -z "$preload_ltr" ]; then
            cant "…and the supplied loader does not flip the direction BY ITSELF" \
                 "the scrubbed preloaded probe printed no APEXDIR line"
        elif [ "$preload_ltr" = "0" ]; then
            ok "…and the supplied loader does not flip the direction BY ITSELF — scrubbed, with $kf6lib preloaded, it is still LeftToRight, so what moves it is the locale and not the library"
        else
            bad "…and the supplied loader does not flip the direction BY ITSELF" \
                "scrubbed + preload gives $preload_ltr — the library sets the direction on its own, so a mirrored fixture run under it would prove nothing about the locale and the route must not be used"
        fi
    fi
fi

# The RTL half of section 2 needs an application direction that is actually
# right-to-left. Whether this machine can produce one was just measured, so the
# answer is carried forward rather than assumed a second time.
#
# TWO routes, and the suite says WHICH one it used in every line it prints —
# because "APEX's shipped row mirrors" and "the row mirrors once somebody hands
# this machine a library it does not ship" are different claims, and a suite
# that produced the same green for both would be worth nothing.
#
#   theme    the platform theme APEX ships carries the translation loader
#            itself. This is what a booted APEX host uses, and it is the only
#            route that is a statement about the product.
#   preload  the platform theme on THIS machine carries none, but the machine
#            has libKF6I18n and the two rows above measured that supplying it
#            (a) flips the direction under an RTL locale and (b) does NOT flip
#            it on its own. Used by the Arch CI runner, whose upstream
#            qt6ct 0.11-8 links no KF6 at all. It exercises APEX's mirroring on
#            a second distribution and a second Qt minor; it does not say
#            anything about how that machine would behave unaided.
RTL_AVAILABLE=0; RTL_ROUTE=""; RTL_PRELOAD=""
if [ "${with_theme_rtl:-}" = "1" ]; then
    RTL_AVAILABLE=1; RTL_ROUTE="theme"
elif [ "${preload_rtl:-}" = "1" ] && [ "${preload_ltr:-}" = "0" ]; then
    RTL_AVAILABLE=1; RTL_ROUTE="preload"; RTL_PRELOAD="$kf6lib"
fi

# ── 2. the shipped row, instantiated and mirrored ────────────────────────────
section "2. the shipped settings row mirrors"

stage="$(mktemp -d)"
trap 'rm -rf "$probe" "$stage"' EXIT INT TERM

cp -r "$root/src/components/config" "$stage/components-config-tmp"
mkdir -p "$stage/components"
mv "$stage/components-config-tmp" "$stage/components/config"
# The controls the config components are built on (ApexPressable & co.,
# UI/UX roadmap Phase 3), at the same relative path.
cp -r "$root/src/components/controls" "$stage/components/controls"
cp "$root/src/components/SectionLabel.qml" "$stage/components/SectionLabel.qml"   # CfgSection's heading (UI/UX Phase 17)
cp "$here/rtl-test.qml" "$stage/rtl-test.qml"

# The staged tree must BE the shipped one. A copy that silently lost a file
# would make every assertion below a statement about something this repository
# does not ship.
if ! diff -r "$root/src/components/config" "$stage/components/config" >/dev/null 2>&1; then
    bad "the staged components are the shipped ones, byte for byte" "the copy differs"
    finish; exit 1
fi
ok "the staged components are the shipped ones, byte for byte"

cat > "$stage/qmldir" <<'QMLDIR'
singleton Theme Theme.qml
QMLDIR

cat > "$stage/Theme.qml" <<'THEME'
pragma Singleton
import QtQuick

QtObject {
    property color active:     "#7aa2f7"
    property color background: "#1a1b26"
    property color text:       "#c0caf5"
    property color danger:     "#f7768e"
    property color warning:    "#e0af68"
    property color info:       "#7dcfff"
    property color attention:  "#ff9e64"
    property color subtext:    "#9aa5ce"
    property color fixedLight: "#eceff4"

    function fs(v) { return Math.max(7, Math.round(v)) }
    function px(v) { return Math.round(v) }
    function factorForHeight(h)      { return 1.0 }
    function factorForScreen(screen) { return 1.0 }
}
THEME

. "$here/lib/theme-stub.sh"
stage_theme_set "$stage" "$root" "$stage/components" || {
    bad "the staged token set could be built" ""; finish; exit 1; }
# The motion system the staged controls take their timing from (Phase 1 of the
# UI/UX roadmap): copied from src/theme at the shipped defaults.
stage_motion "$stage" "$root" || {
    echo "RESULT: the staged motion system could not be built"; exit 1; }

# The fixture is run TWICE — scrubbed, and under the RTL locale with the image's
# platform theme. Round 22 ran it once, in whatever direction the operator's
# shell happened to be in, and every geometric assertion in it forced mirroring
# on by hand. A row hardcoded `LayoutMirroring.enabled: false` passed all of it.
run_fixture() {   # run_fixture <locale or empty> <theme or empty> [preload]
    local l="$1" t="$2" p="${3:-}"
    env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        -u LANG -u LC_ALL -u LANGUAGE -u QT_QPA_PLATFORMTHEME \
        ${l:+LANG="$l"} ${l:+LC_ALL="$l"} ${t:+QT_QPA_PLATFORMTHEME="$t"} \
        ${p:+LD_PRELOAD="$p"} \
        QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES="qt.qml.binding.removal.info=false" \
        timeout 120 "$runner" -platform offscreen -input "$stage/rtl-test.qml" 2>&1
}

# initTestCase + seven test functions + cleanupTestCase. An exact count, not a
# floor: a dropped test function would otherwise hide behind an added one, which
# is how a suite quietly stops measuring the thing it was written for — the same
# reason check-color-tokens.sh pins EXPECT_WHITE_FG.
EXPECT_TESTS=9

# Each QtTest function reported on its own line, rather than one verdict for the
# whole fixture. The mutants in tests/mutate-rtl.sh break different arms of this,
# and a single collapsed "2 of 7 assertions failed" would name the same
# assertion for all of them — which is a mutation set that cannot tell its own
# mutants apart.
qt_case() {   # qt_case <pass label> <function name> <sentence>
    if printf '%s\n' "$out" | grep -q "^PASS   : qmltestrunner::rtl::$2"; then
        ok "[$1] $3"
    elif printf '%s\n' "$out" | grep -q "qmltestrunner::rtl::$2"; then
        bad "[$1] $3" "$(printf '%s\n' "$out" | grep -m1 -A1 "FAIL!.*::$2" | tail -1 | sed 's/^ *//')"
    else
        bad "[$1] $3" "the fixture never ran $2"
    fi
}

evaluate_pass() {   # evaluate_pass <label>
    local label="$1"

    if grep -qE "is not a type|module .* is not installed|Cannot assign" <<<"$out"; then
        printf '%s\n' "$out" | tail -20
        bad "[$label] the staged test tree loads" "a type failed to resolve"
        return 1
    fi

    local totals n_pass n_fail n_ran
    totals="$(printf '%s\n' "$out" | grep -m1 '^Totals:')"
    if [ -z "$totals" ]; then
        printf '%s\n' "$out" | tail -20
        bad "[$label] the mirroring fixture runs to completion" "no Totals line"
        return 1
    fi
    n_pass="$(sed -E 's/.*Totals: ([0-9]+) passed.*/\1/' <<<"$totals")"
    n_fail="$(sed -E 's/.*, ([0-9]+) failed.*/\1/' <<<"$totals")"
    n_ran=$(( n_pass + n_fail ))
    if [ "$n_ran" -ne "$EXPECT_TESTS" ]; then
        printf '%s\n' "$out" | grep -E '^(PASS|FAIL!)' | sed 's/^/      /'
        bad "[$label] the fixture ran all $EXPECT_TESTS of its test functions" "$n_ran ran"
    else
        ok "[$label] the fixture ran all $EXPECT_TESTS of its test functions"
    fi

    qt_case "$label" test_000_the_engine_mirrors_a_plain_anchor \
            "the engine mirrors a plain left anchor, and puts it back"
    qt_case "$label" test_010_the_row_binds_mirroring_to_the_application_direction \
            "CfgRow mirrors exactly when the application does — read off the live attached object"
    qt_case "$label" test_020_the_row_passes_mirroring_down \
            "CfgRow passes mirroring down to the control it holds"
    qt_case "$label" test_030_a_real_row_swaps_its_label_and_its_control \
            "forced both ways, the label and the control swap sides"
    qt_case "$label" test_040_the_row_mirrors_without_being_told_to \
            "and with NOTHING set by hand the row matches the application's direction"
    qt_case "$label" test_050_the_banner_inset_follows_the_reading_direction \
            "CfgScroll's lifecycle banner keeps its 2px inset on the side the reader starts from"
    qt_case "$label" test_060_the_scroll_container_mirrors_without_being_told_to \
            "and an untouched CfgScroll mirrors on its shipped declaration alone"

    # A runner that exits non-zero while reporting no failed function has
    # crashed or lost a test rather than failed an assertion, and the two must
    # not read alike.
    [ "$status" -eq 0 ] \
        && ok "[$label] qmltestrunner exited cleanly, so the counts above are its own verdict" \
        || bad "[$label] qmltestrunner exited cleanly" "it exited $status"
}

out="$(run_fixture "" "")"; status=$?
evaluate_pass "LTR" || { finish; exit 1; }

# The pass that carries the whole row. Without it every assertion above is
# "the row mirrors when told to", and a row that never mirrors on its own
# satisfies all of them.
if [ "$RTL_AVAILABLE" -eq 1 ]; then
    echo "      note: the right-to-left direction for this pass comes from the \"$RTL_ROUTE\" route${RTL_PRELOAD:+ ($RTL_PRELOAD)}"
    out="$(run_fixture "$L_RTL" "$THEME" "$RTL_PRELOAD")"; status=$?
    evaluate_pass "RTL/$RTL_ROUTE"
else
    cant "the shipped row is measured under a right-to-left application direction" \
         "neither route produced one here — the theme gave ${with_theme_rtl:-<unmeasured>} and no usable Qt translation loader was found, so the binding CfgRow actually ships is unmeasured on this machine"
fi

# ── 3. how far this reaches, pinned exactly ─────────────────────────────────
section "3. what mirroring does NOT reach, pinned in both directions"

# Windows first. Every surface the shell paints is rooted in a PanelWindow, and
# none of them declares mirroring yet — so the settings page mirrors and the bar
# above it does not. That is the honest state of the row and it is a number, not
# a sentence: if somebody mirrors a window root the count moves and this says so.
win_total="$(grep -rlE '^\s*PanelWindow\b|^\s*FloatingWindow\b' "$root/src" 2>/dev/null | wc -l)"
win_mirrored="$(grep -rlE '^\s*PanelWindow\b|^\s*FloatingWindow\b' "$root/src" 2>/dev/null \
                 | xargs -r grep -l 'LayoutMirroring' | wc -l)"
# 16 since UI/UX Phase 9b and 17 since Phase 10: QuickControl and ArchMenu
# became PanelWindows spanning their strips (both were PopupWindows placed by
# an anchor rectangle).
WIN_TOTAL_EXPECT=17
WIN_MIRRORED_EXPECT=0
[ "$win_total" -eq "$WIN_TOTAL_EXPECT" ] \
    && ok "the shell paints from $WIN_TOTAL_EXPECT window roots — counted $win_total" \
    || bad "the shell paints from $WIN_TOTAL_EXPECT window roots" "counted $win_total — update the pin deliberately"

# ── AND THE PIN ABOVE USED TO BE A GATE THAT COULD CERTIFY A NO-OP ──────────
#
# The row below counts FILES CONTAINING THE STRING `LayoutMirroring`. Until
# round 32 that was the whole measurement, and the ledger read "0 of 14 window
# roots mirror" as a gap somebody had forgotten to close. It is not. Measured
# this round from Quickshell's OWN type registry and from the Qt engine:
#
#   PanelWindow -> PanelWindowInterface -> WindowInterface -> Reloadable
#                                                          -> QObject
#
# There is no Item and no Window anywhere in that chain, and FloatingWindow's
# is the same. Qt's LayoutMirroring attached property "only works with Items
# and Windows" — and when it does not, it DOES NOT FAIL. The object is still
# created, `errorString()` is EMPTY, and the only trace is one QWARN on
# stderr. So the two lines that work on CfgRow are, on any of these 14 roots,
# a SILENT NO-OP.
#
# Which means the obvious way to close this row would have moved the count
# from 0 to 14, turned this assertion green, and mirrored NOTHING — the suite
# certifying the remaining half as done on the strength of a string. The two
# rows after this one are what stop that: one asks whether the type can carry
# the property at all, the other asks the engine what happens when it cannot.
# Both are required to fail in both directions, so the day Quickshell gives
# its windows an Item or Window ancestor this goes RED and says the route has
# opened rather than staying quiet for another nineteen rounds.
[ "$win_mirrored" -eq "$WIN_MIRRORED_EXPECT" ] \
    && ok "$WIN_MIRRORED_EXPECT window roots declare mirroring — and that is NOT a forgotten edit: the two rows below measure that the declaration cannot work on these types at all" \
    || bad "$WIN_MIRRORED_EXPECT window roots declare mirroring" \
           "counted $win_mirrored — if one of them now carries LayoutMirroring, check FIRST that it is on an Item or a Window inside the root and not on the root itself, because on the root it is a silent no-op and this count cannot tell the difference"

# ── row 2: what the engine does when the target is not an Item or a Window ──
#
# The control for the row after it, and the reason "silent no-op" is a
# measurement rather than a reading of the Qt documentation. Needs no
# quickshell, so it runs on the Arch CI runner where nothing else about these
# window types can be asked.
cat > "$probe/tst_mirror_attach.qml" <<'MIRQML'
import QtQuick
import QtQuick.Window
import QtTest
TestCase {
    name: "attach"
    Component { id: nonItem; QtObject { LayoutMirroring.enabled: true } }
    Component { id: asWindow; Window { LayoutMirroring.enabled: true } }
    function test_000_report() {
        var a = nonItem.createObject(null)
        console.log("APEXATTACH nonitem=" + (a ? "created" : "null")
                    + " err=[" + nonItem.errorString().trim() + "]")
        var w = asWindow.createObject(null)
        console.log("APEXATTACH window=" + (w ? "created" : "null")
                    + " mirrored=" + (w ? w.LayoutMirroring.enabled : "n/a"))
        verify(true)
    }
}
MIRQML
attach_out="$(env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    -u LANG -u LC_ALL -u LANGUAGE -u QT_QPA_PLATFORMTHEME \
    QT_LOGGING_RULES='*.debug=true;qt.*=false' QT_QPA_PLATFORM=offscreen \
    timeout 60 "$runner" -platform offscreen -input "$probe/tst_mirror_attach.qml" 2>&1)"
attach_nonitem="$(printf '%s\n' "$attach_out" | sed -n 's/.*APEXATTACH nonitem=\([a-z]*\) err=\[\(.*\)\]$/\1|\2/p' | head -1)"
attach_window="$(printf '%s\n' "$attach_out"  | sed -n 's/.*APEXATTACH window=\([a-z]*\) mirrored=\([a-z/]*\).*/\1|\2/p' | head -1)"

if [ -z "$attach_nonitem" ] || [ -z "$attach_window" ]; then
    cant "attaching LayoutMirroring to a non-Item is a SILENT no-op, and to a Window it works" \
         "the attach probe printed no APEXATTACH line — not a pass"
elif [ "$attach_nonitem" = "created|" ] && [ "$attach_window" = "created|true" ]; then
    ok "attaching LayoutMirroring to a non-Item is a SILENT no-op — the object is still created and errorString() is EMPTY — while the same declaration on a Window reads back enabled"
elif [ "$attach_window" != "created|true" ]; then
    bad "attaching LayoutMirroring to a non-Item is a SILENT no-op, and to a Window it works" \
        "the Window control came back \"$attach_window\" — the probe cannot tell the two cases apart, so it proves nothing about the window roots"
else
    ok "attaching LayoutMirroring to a non-Item now REPORTS itself (\"$attach_nonitem\") instead of passing silently — Qt has changed; the no-op is no longer silent and the row above can be relaxed"
fi

# ── row 3: can the shell's window roots carry it at all? ────────────────────
#
# Read out of Quickshell's own .qmltypes, which is the registry the QML engine
# itself resolves these names through — not out of quickshell's source, not
# out of a version number, and not out of the documentation. FOUND 19's shape
# for the directory: two spellings tried, the one used is printed.
qsqml=""; qscore=""
for d in $("${qtool%% *}" -query QT_INSTALL_QML 2>/dev/null) \
         /usr/lib64/qt6/qml /usr/lib/qt6/qml; do
    [ -n "$d" ] && [ -e "$d/Quickshell/_Window/quickshell-window.qmltypes" ] || continue
    qsqml="$d/Quickshell/_Window/quickshell-window.qmltypes"
    # The window module names its prototypes but does not DEFINE all of them;
    # Reloadable lives in the core registry. Both are read so the chain
    # resolves to its real root instead of stopping at the first name this
    # file happens not to define — a chain that stops early cannot be told
    # from a chain that ends there, and the whole assertion is about what the
    # chain does NOT contain.
    [ -e "$d/Quickshell/quickshell-core.qmltypes" ] && qscore="$d/Quickshell/quickshell-core.qmltypes"
    break
done
if [ -z "$qsqml" ]; then
    cant "the shell's window roots are types LayoutMirroring cannot attach to" \
         "quickshell's window type registry is not installed on this machine (looked for Quickshell/_Window/quickshell-window.qmltypes under the Qt QML paths), so the prototype chain could not be read here"
elif ! command -v python3 >/dev/null 2>&1; then
    cant "the shell's window roots are types LayoutMirroring cannot attach to" \
         "no python3 to walk the prototype chain in $qsqml"
else
    chain="$(python3 - "$qsqml" $qscore <<'CHAINPY'
import re, sys
proto = {}
for path in sys.argv[1:]:
    for blk in re.split(r'\n(?=    Component \{)', open(path, encoding="utf-8", errors="replace").read()):
        n = re.search(r'name: "([^"]+)"', blk)
        p = re.search(r'prototype: "([^"]+)"', blk)
        if n:
            proto.setdefault(n.group(1), p.group(1) if p else None)
out = []
for start in ("PanelWindowInterface", "FloatingWindowInterface"):
    cur, seen = start, []
    while cur and cur not in seen:
        seen.append(cur)
        cur = proto.get(cur)
    out.append("->".join(seen))
print(" ".join(out))
CHAINPY
)"
    # Matched LINK BY LINK and never with a substring test, because "Window"
    # appears INSIDE the interface names themselves — PanelWindowInterface,
    # WindowInterface — so `case "$chain" in *Window*)` would answer YES on
    # every chain including this one and the row would be a constant. And
    # never `grep -q` either: a matching grep -q under pipefail closes the
    # pipe on its writer and the pipeline reports 141, which is "no" exactly
    # when the answer is yes (the same trap i18n_of carries in section 1).
    has_item=0
    for link in $(printf '%s' "$chain" | tr '> ' '\n\n' | tr -d '-'); do
        [ "$link" = "Item" ] && has_item=1
        [ "$link" = "Window" ] && has_item=1
        [ "$link" = "QQuickItem" ] && has_item=1
        [ "$link" = "QQuickWindow" ] && has_item=1
    done
    if [ -z "$chain" ]; then
        cant "the shell's window roots are types LayoutMirroring cannot attach to" \
             "the prototype walk over $qsqml produced nothing"
    elif [ "$has_item" -eq 0 ]; then
        ok "the shell's window roots are types LayoutMirroring cannot attach to — $chain, with no Item and no Window anywhere, so the two lines that work on CfgRow would be a silent no-op on all $win_total of them"
    else
        bad "the shell's window roots are types LayoutMirroring cannot attach to" \
            "$chain now reaches an Item or a Window — THE ROUTE HAS OPENED. Standing-queue item 7 becomes doable: mirror the roots, move WIN_MIRRORED_EXPECT deliberately, and read the input-mask warning in this file before shipping it"
    fi
fi

# ── and the thing mirroring can NEVER do ────────────────────────────────────
#
# LayoutMirroring resolves anchors and reverses positioners. An explicit `x:` is
# a number and stays a number, so every one of these sites is outside its reach
# by construction — the same shape as check-reduce-motion.sh's "402 are bare int
# literals no switch can touch". Round 22 counted them and asserted
# `[ "$x_sites" -ge 0 ]`, which is true of every integer; that is the gate that
# inspects nothing, and this replaces it.
#
# The pin is the SET, not the count, because the count is what hides a swap: one
# site fixed and one added reads as no change. Each entry below was read and
# bucketed by hand, and the bucket is the reason it is allowed to stay:
#
#   NOT AN ITEM'S X AT ALL (4) — mirroring must not touch these and could not.
#     TopBar.qml            x2  `Region` entries in the input mask, not visuals
#     LabwcBackend.qml      x1  a JavaScript object literal, a geometry record
#     NiriService.qml       x1  the same literal, in the niri backend
#
#   WIDTH-COMPENSATED (9) — an arithmetic no-op, not luck. Mirrored, x becomes
#   `parent.width - x - width`; with `x: N, width: parent.width - 2N` that is N
#   again, and with `x: 0, width: root.width` it is 0. Identical geometry both
#   ways, so converting them to anchors would change nothing a reader sees.
#     AppearancePage.qml    x2  x:10 width: parent.width - 20 (scheme; light or dark)
#     DataPage.qml          x2  x:10 width: parent.width - 20
#     MiscPage.qml          x3  x:10 width: parent.width - 20
#     KeybindsPage.qml      x2  x:0  width: root.width  (full bleed)
#
#   GEOMETRY PLUMBING (0) — ArchMenu's mask proxy (`x: 0`) went with UI/UX
#   Phase 10: its input region is the spill body's bounds now.
#
# What is NOT on this list is the point: the three sites that were a bare left
# inset with an intrinsic or asymmetric width — CfgScroll's lifecycle banner
# (x:2 against a 12px right inset, inside the component that declares the
# mirroring), and MiscPage's About row and Update button — are now anchored, and
# a new one anywhere in src/ fails this.
x_expect="$(cat <<'XEOF'
1 src/services/compositor/LabwcBackend.qml x: 0, y: 0, width: 0, height: 0
2 src/services/config_tab/KeybindsPage.qml x: 0
2 src/services/config_tab/pages/AppearancePage.qml x: 10
2 src/services/config_tab/pages/DataPage.qml x: 10
3 src/services/config_tab/pages/MiscPage.qml x: 10
1 src/services/system/NiriService.qml x: 0, y: 0, width: 0, height: 0
2 src/windows/TopBar.qml x: 0; y: 0
XEOF
)"
x_now="$(cd "$root" && grep -rnE '^[[:space:]]*x:[[:space:]]*[0-9]' src 2>/dev/null \
         | sed -E 's/^([^:]+):[0-9]+:[[:space:]]*/\1\t/; s/[[:space:]]+/ /g' \
         | sort | uniq -c | sed 's/^ *//')"
x_sites="$(cd "$root" && grep -rhcE '^[[:space:]]*x:[[:space:]]*[0-9]' -r src 2>/dev/null | paste -sd+ | bc 2>/dev/null)"
[ -n "$x_sites" ] || x_sites="$(cd "$root" && grep -rE '^[[:space:]]*x:[[:space:]]*[0-9]' src 2>/dev/null | wc -l)"

if [ "$x_now" = "$x_expect" ]; then
    ok "the explicit numeric x: sites in src/ are exactly the bucketed ones ($x_sites sites, none of them a bare left inset)"
else
    bad "the explicit numeric x: sites in src/ are exactly the bucketed ones" \
        "the set moved; a new x: is a site mirroring cannot reach and needs a bucket or an anchor"
    diff <(printf '%s\n' "$x_expect") <(printf '%s\n' "$x_now") | sed 's/^/      /'
fi

# The two declarations this round added, asserted as an exact pair. A third
# appearing without the ledger moving is the drift this pin exists to catch.
cfg_mirrored="$(grep -rl 'LayoutMirroring' "$root/src/components/config" 2>/dev/null | wc -l)"
[ "$cfg_mirrored" -eq 2 ] \
    && ok "exactly 2 shared config components declare mirroring (CfgRow, CfgScroll)" \
    || bad "exactly 2 shared config components declare mirroring" "counted $cfg_mirrored"

finish
