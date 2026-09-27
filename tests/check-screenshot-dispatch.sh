#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  src/scripts/screenshot.sh — which capture tool it reaches for, on which
#  compositor, and what it does with the result (roadmap §21, P1-038).
#
#  ── Why this is behavioural and not a grep ──────────────────────────────────
#  Screenshots were dead on labwc and niri for months and nothing said so. The
#  script called `grimblast` unconditionally; grimblast refuses to start without
#  HYPRLAND_INSTANCE_SIGNATURE, exits before writing a file, and the keybind
#  swallows its stderr. A grep for the word "grim" in the fixed script would
#  have passed on the broken one too — both contain it. So this runs the shipped
#  script against stub binaries that record their own argv, and grades which one
#  was actually invoked.
#
#  Nothing here needs a compositor, a display or a GPU: every external tool is a
#  stub on PATH, HOME is a temp directory, and the only thing under test is the
#  dispatch. It is therefore the one part of the Floating/labwc matrix that runs
#  on any CI runner.
#
#  ── The two failure modes it exists for ─────────────────────────────────────
#   1. A capture path that silently produces no file off Hyprland.
#   2. A foreground `wl-copy`. It has to stay resident to own the clipboard
#      selection until another client claims it, so it never returns — and
#      invoked from a keybind that leaves the compositor with a hung child for
#      every screenshot taken. Both halves are asserted: the script returns
#      promptly, and wl-copy lands in a process group of its own.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
script="$root/src/scripts/screenshot.sh"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

want "src/scripts/screenshot.sh exists and is non-empty" test -s "$script"
[ -s "$script" ] || { echo; echo "passed=$pass failed=$fail"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

# ── The stub machine ─────────────────────────────────────────────────────────
# Every external tool the script can reach becomes a shell stub that appends one
# TAB-separated line to $CALLS: its name, its process group, then its argv. The
# process group is what proves detachment — a stub run in the foreground shares
# the script's group, and one run under setsid does not.
#
# The sandbox PATH holds these stubs and NOTHING ELSE except the handful of
# coreutils the script and the stubs need by name. That is not tidiness: this
# machine has a real grim, a real slurp and a real wl-copy installed, so a PATH
# with /usr/bin on it makes every "the tool is missing" case run the real tool
# against no display — three assertions here passed for that reason before the
# PATH was closed, and the missing-grim mutant went undetected.
HOST_TOOLS=(bash timeout date mkdir ps tr sleep setsid dirname)
mkbin() {
    local dir="$1"
    mkdir -p "$dir"
    local t p
    for t in "${HOST_TOOLS[@]}"; do
        p="$(command -v "$t" 2>/dev/null)" || continue
        ln -sf "$p" "$dir/$t"
    done
}
mkstubs() {
    local dir="$1"; shift
    mkdir -p "$dir"
    local tool
    for tool in "$@"; do
        cat > "$dir/$tool" <<STUB
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$tool" "\$(ps -o pgid= -p \$\$ | tr -d ' ')" "\$*" >> "\$CALLS"
STUB
        cat >> "$dir/$tool" <<'STUB'
# Whether the freeze is still up when this tool runs: hyprpicker's stub leaves
# its pid beside the log, and a live pid means the screen is still frozen.
frozen() {
    local hp
    [ -f "$CALLS.hyprpicker.pid" ] || return 1
    read -r hp < "$CALLS.hyprpicker.pid"
    kill -0 "$hp" 2>/dev/null
}
case "$STUB_NAME" in
    grim)
        frozen && : > "$CALLS.frozen-during-grim"
        # grim writes the file the rest of the script then reads and reports.
        for a in "$@"; do :; done
        : > "$a"
        ;;
    hyprpicker)
        # The real one stays up until it is killed or a colour is picked. exec
        # keeps the pid the script was given, so killing that pid ends this.
        printf '%s\n' "$$" > "$CALLS.hyprpicker.pid"
        exec sleep "${STUB_HYPRPICKER_SLEEP:-20}"
        ;;
    notify-send)
        frozen && : > "$CALLS.frozen-during-notify"
        ;;
    slurp)
        [ "${STUB_SLURP_CANCEL:-0}" = "1" ] && exit 1
        printf '10,20 100x200\n'
        ;;
    grimblast)
        for a in "$@"; do :; done
        : > "$a"
        ;;
    wl-copy)
        sleep "${STUB_WLCOPY_SLEEP:-0}"
        ;;
esac
exit 0
STUB
        # STUB_NAME has to be the tool's own name inside the case above, and the
        # heredoc that carries the case is deliberately unexpanded.
        sed -i "2i STUB_NAME=$tool" "$dir/$tool"
        chmod +x "$dir/$tool"
    done
}

# shot <sandbox-name> <tools...> -- <env assignments...> -- <script args...>
#
# Runs the shipped script with only the named tools on PATH, in a private HOME,
# under its own process group so the detachment assertion has a group to compare
# against. Leaves $CALLS, $OUT and $RC in the caller's scope.
CALLS=""; OUT=""; RC=0; ELAPSED=0
shot() {
    local name="$1"; shift
    local tools=() envs=() args=()
    local phase=tools a
    for a in "$@"; do
        case "$a" in
            --) case "$phase" in tools) phase=envs ;; envs) phase=args ;; esac; continue ;;
        esac
        case "$phase" in
            tools) tools+=("$a") ;;
            envs)  envs+=("$a")  ;;
            args)  args+=("$a")  ;;
        esac
    done

    local sb="$work/$name"
    rm -rf "$sb"; mkdir -p "$sb/bin" "$sb/home"
    mkbin "$sb/bin"
    mkstubs "$sb/bin" "${tools[@]}"
    CALLS="$sb/calls"; : > "$CALLS"

    local started ended
    started="$(date +%s%N)"
    # env -i: nothing of the developer's session leaks in, so a compositor is
    # named only where a case names it. The stubs report their own process
    # group, so a tool run in the script's foreground and one detached from it
    # are told apart by comparing two lines of the same log.
    OUT="$(env -i \
        PATH="$sb/bin" \
        HOME="$sb/home" \
        CALLS="$CALLS" \
        "${envs[@]}" \
        timeout 30 bash "$script" "${args[@]}" 2>&1)"
    RC=$?
    ended="$(date +%s%N)"
    ELAPSED=$(( (ended - started) / 1000000 ))
    return 0
}

called()     { grep -q "^$1	" "$CALLS"; }
not_called() { ! grep -q "^$1	" "$CALLS"; }
argv_of()    { grep -m1 "^$1	" "$CALLS" | cut -f3-; }
pgid_of()    { grep -m1 "^$1	" "$CALLS" | cut -f2; }
line_of()    { grep -n -m1 "^$1	" "$CALLS" | cut -d: -f1; }

# The freeze's pid, and whether it outlived the script. A stub left running is
# the test's to reap, so each check that finds one kills it.
freeze_pid_of() { [ -f "$CALLS.hyprpicker.pid" ] && read -r p < "$CALLS.hyprpicker.pid" && echo "$p"; }
freeze_released() {
    local p
    p="$(freeze_pid_of)" || return 1
    if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; return 1; fi
    return 0
}

echo "── Hyprland: grimblast, frozen ──────────────────────────────────────────"

# grimblast still handles clipboard and notification itself, so nothing else
# may run — and it is asked to freeze the screen while an area is picked.
shot hypr grimblast grim slurp wl-copy notify-send hyprctl hyprpicker \
     -- HYPRLAND_INSTANCE_SIGNATURE=sig123 XDG_CURRENT_DESKTOP=Hyprland \
     -- output
want "on Hyprland the script succeeds"            test "$RC" -eq 0
want "on Hyprland grimblast is what runs"         called grimblast
want "on Hyprland grim is not reached"            not_called grim
want "on Hyprland wl-copy is grimblast's job"     not_called wl-copy
want "on Hyprland the freeze is grimblast's job"  not_called hyprpicker
if [[ "$(argv_of grimblast)" == "-n --freeze copysave output "*"/Pictures/Screenshots/Screenshot_"*.png ]]; then
    ok "grimblast is called -n --freeze copysave <target> <path>"
else
    bad "grimblast's invocation changed: $(argv_of grimblast)"
fi
want "a capture that is instant pushes no layer rule" not_called hyprctl

# grimblast's own `keyword layerrule noanim,selection` is refused by a Lua
# config, so the still and slurp's overlay fade: the rule has to come from here,
# through eval, naming both layers, guarded so it is pushed once per load.
shot hypr_area grimblast grim slurp wl-copy notify-send hyprctl hyprpicker \
     -- HYPRLAND_INSTANCE_SIGNATURE=sig123 XDG_CURRENT_DESKTOP=Hyprland \
     -- area
want "a Hyprland area capture succeeds"           test "$RC" -eq 0
case "$(argv_of hyprctl)" in
    "eval if not APEX_SCREENSHOT_NO_ANIM then hl.layer_rule("*'namespace = "^(hyprpicker|selection)$"'*"no_anim = true"*"APEX_SCREENSHOT_NO_ANIM = true end")
        ok "the freeze and selection layers are exempted from animation, once per load" ;;
    *)  bad "no guarded no_anim rule for hyprpicker|selection: $(argv_of hyprctl)" ;;
esac
if [ -n "$(line_of hyprctl)" ] && [ "$(line_of hyprctl)" -lt "$(line_of grimblast)" ]; then
    ok "the rule is in place before grimblast maps a layer"
else
    bad "the layer rule is pushed after grimblast has run, or not at all"
fi

# A copy of the script with no compositor.sh beside it (a user's ~/.local/bin,
# say) still captures and still freezes; it goes without the exemption only.
mkdir -p "$work/standalone"
cp "$script" "$work/standalone/screenshot.sh"
keep="$script"; script="$work/standalone/screenshot.sh"
shot hypr_standalone grimblast grim slurp wl-copy notify-send hyprctl hyprpicker \
     -- HYPRLAND_INSTANCE_SIGNATURE=sig123 XDG_CURRENT_DESKTOP=Hyprland \
     -- area
script="$keep"
want "a copy without the adapter still captures" test "$RC" -eq 0
if [[ "$(argv_of grimblast)" == "-n --freeze copysave area "* ]]; then
    ok "...frozen"
else
    bad "a copy without the adapter lost the freeze: $(argv_of grimblast)"
fi

# A Hyprland session without grimblast installed must not silently do nothing:
# it falls through to grim like any other compositor.
shot hypr_nogrimblast grim slurp wl-copy notify-send \
     -- HYPRLAND_INSTANCE_SIGNATURE=sig123 XDG_CURRENT_DESKTOP=Hyprland \
     -- output
want "Hyprland without grimblast falls through to grim" called grim

echo
echo "── labwc and niri capture, rather than exiting ──────────────────────────"

for desktop in labwc:wlroots niri; do
    tag="${desktop%%:*}"
    shot "off_$tag" grimblast grim slurp wl-copy notify-send hyprctl hyprpicker \
         -- XDG_CURRENT_DESKTOP="$desktop" \
         -- output
    want "on $tag the script succeeds"        test "$RC" -eq 0
    want "on $tag grim is what runs"          called grim
    want "on $tag grimblast is not reached"   not_called grimblast
    want "on $tag hyprctl is not reached"     not_called hyprctl
    want "on $tag an instant capture does not freeze" not_called hyprpicker
    shot_file="$(argv_of grim)"
    if [[ "$shot_file" == *"/Pictures/Screenshots/Screenshot_"*.png ]]; then
        ok "on $tag a file is written under Pictures/Screenshots"
    else
        bad "on $tag grim was given no output path: $shot_file"
    fi
    want "on $tag the capture is announced"   called notify-send
done

echo
echo "── Region capture, and a cancelled region ───────────────────────────────"

shot area grim slurp wl-copy notify-send hyprpicker -- XDG_CURRENT_DESKTOP=labwc:wlroots -- area
want "area capture asks slurp for a region"   called slurp
if [[ "$(argv_of grim)" == "-g 10,20 100x200 "* ]]; then
    ok "the region slurp returned is passed to grim"
else
    bad "grim did not receive slurp's region: $(argv_of grim)"
fi

# The freeze, off Hyprland: up before the selection starts, still up when grim
# reads the screen (grim then captures the still, not whatever moved since),
# and gone before the "saved" toast — by pid, so nothing else is killed.
if [ "$(argv_of hyprpicker)" = "-rz" ]; then
    ok "the screen is frozen with hyprpicker -rz (no lens, no colour readout)"
else
    bad "no freeze, or not -rz: '$(argv_of hyprpicker)'"
fi
if [ -n "$(line_of hyprpicker)" ] && [ "$(line_of hyprpicker)" -lt "$(line_of slurp)" ]; then
    ok "the freeze is up before the selection starts"
else
    bad "slurp ran over the live screen: the freeze came after it, or never"
fi
want "grim captures while the screen is frozen"  test -f "$CALLS.frozen-during-grim"
want "the freeze is released before the toast"   test ! -f "$CALLS.frozen-during-notify"
want "the freeze does not outlive the script"    freeze_released

shot area_nopicker grim slurp wl-copy notify-send -- XDG_CURRENT_DESKTOP=labwc:wlroots -- area
want "without hyprpicker an area capture still works" test "$RC" -eq 0
want "...and still captures the region"          called grim

# Escape during a selection is a choice, not a failure. It must not capture the
# whole screen instead, and it must not report an error the user just made.
shot area_cancel grim slurp wl-copy notify-send hyprpicker \
     -- XDG_CURRENT_DESKTOP=labwc:wlroots STUB_SLURP_CANCEL=1 \
     -- area
want "a cancelled selection exits zero"       test "$RC" -eq 0
want "a cancelled selection captures nothing" not_called grim
want "a cancelled selection notifies nothing" not_called notify-send
# The case the EXIT trap exists for: without it the script leaves by `exit 0`
# with the still up, and the screen looks hung until something is clicked.
want "a cancelled selection unfreezes the screen" freeze_released

echo
echo "── 'active' is honest about what it captured ────────────────────────────"

# labwc publishes no IPC and wlr-foreign-toplevel reports titles but not
# geometry, so the focused window's rectangle is not obtainable. Capturing the
# whole output is the right answer; doing it silently is not.
shot active grim slurp wl-copy notify-send -- XDG_CURRENT_DESKTOP=labwc:wlroots -- active
want "active capture off Hyprland still produces a file" called grim
if [[ "$(argv_of grim)" == "-g "* ]]; then
    bad "active capture off Hyprland invented a window rectangle"
else
    ok "active capture off Hyprland takes the whole output"
fi
if grep -q "^notify-send	.*whole screen" "$CALLS"; then
    ok "active capture off Hyprland says it took the whole screen"
else
    bad "active capture off Hyprland substituted the output silently"
fi

echo
echo "── The clipboard copy must not hang the compositor ──────────────────────"

# wl-copy owns the selection until another client claims it, so it never
# returns. Two independent properties: the script does not wait for it, and it
# is not left in the script's process group where the compositor inherits it.
shot clip grim slurp wl-copy notify-send \
     -- XDG_CURRENT_DESKTOP=labwc:wlroots STUB_WLCOPY_SLEEP=20 \
     -- output
want "the image is put on the clipboard"      called wl-copy
want "the script does not wait for wl-copy"   test "$ELAPSED" -lt 10000
echo "        returned in ${ELAPSED}ms with a wl-copy that stays up for 20s"
if [ -n "$(pgid_of wl-copy)" ] && [ "$(pgid_of wl-copy)" != "$(pgid_of grim)" ]; then
    ok "wl-copy is detached into its own process group"
else
    bad "wl-copy shares the script's process group ($(pgid_of grim)); a keybind leaves it hung"
fi

echo
echo "── Missing tools fail loudly instead of quietly ─────────────────────────"

shot no_grim slurp wl-copy notify-send -- XDG_CURRENT_DESKTOP=labwc:wlroots -- output
want "without grim the script fails"          test "$RC" -ne 0
want "without grim the user is told"          called notify-send

shot no_slurp grim wl-copy notify-send -- XDG_CURRENT_DESKTOP=labwc:wlroots -- area
want "without slurp an area capture fails"    test "$RC" -ne 0
want "without slurp the user is told"         called notify-send
want "without slurp nothing is captured"      not_called grim

shot bad_target grim slurp wl-copy notify-send -- XDG_CURRENT_DESKTOP=labwc:wlroots -- sideways
want "an unknown target is a usage error"     test "$RC" -eq 2
want "an unknown target captures nothing"     not_called grim
case "$OUT" in
    usage:*) ok "an unknown target prints the usage line" ;;
    *)       bad "an unknown target printed no usage line: $OUT" ;;
esac

# ── self-test: can these checks fail? ────────────────────────────────────────
# Three checks in this repo have shipped green over the case they existed for.
# So each invariant above is re-run against a copy of the script with that
# invariant deliberately broken, and has to come back red.
echo
echo "── self-test: can these checks fail? ────────────────────────────────────"

mutants=0
mutate() {
    local name="$1" ; shift
    local dst="$work/mutant-$name.sh"
    cp "$script" "$dst"
    # The adapter it sources on Hyprland, beside the copy as it is in the tree.
    cp "$(dirname "$script")/compositor.sh" "$work/compositor.sh"
    "$@" "$dst" || return 1
    ! cmp -s "$script" "$dst" || return 1
    printf '%s' "$dst"
}

run_mutant() {
    local m="$1"; shift
    local keep="$script"
    script="$m"
    shot "mutant" "$@"
    script="$keep"
}

# Mutant 1: the compositor branch goes away and grimblast runs everywhere —
# exactly the shipped bug.
drop_hyprland_branch() {
    sed -i 's/^if \[\[ -n "\${HYPRLAND_INSTANCE_SIGNATURE:-}" \]\].*$/if command -v grimblast >\/dev\/null 2>\&1; then/' "$1"
}
if m="$(mutate always-grimblast drop_hyprland_branch)"; then
    mutants=$((mutants + 1))
    run_mutant "$m" grimblast grim slurp wl-copy notify-send \
        -- XDG_CURRENT_DESKTOP=labwc:wlroots -- output
    want "self-test grimblast called on labwc: caught" called grimblast
    want "self-test ...and grim never runs: caught"     not_called grim
else
    bad "self-test could not build the always-grimblast mutant"
fi

# Mutant 2: setsid dropped, so wl-copy inherits the script's process group and
# the compositor inherits wl-copy.
drop_setsid() { sed -i 's/^    setsid wl-copy /    wl-copy /' "$1"; }
if m="$(mutate foreground-wl-copy drop_setsid)"; then
    mutants=$((mutants + 1))
    run_mutant "$m" grim slurp wl-copy notify-send \
        -- XDG_CURRENT_DESKTOP=labwc:wlroots STUB_WLCOPY_SLEEP=2 -- output
    if [ -n "$(pgid_of wl-copy)" ] && [ "$(pgid_of wl-copy)" = "$(pgid_of grim)" ]; then
        ok "self-test wl-copy left in the script's process group: caught"
    else
        bad "self-test the detachment check cannot see an attached wl-copy"
    fi
else
    bad "self-test could not build the foreground-wl-copy mutant"
fi

# Mutant 3: the backgrounding dropped, so the script waits for a client that by
# design never returns.
drop_background() { sed -i 's|^\( *setsid wl-copy .*\) &$|\1|' "$1"; }
if m="$(mutate blocking-wl-copy drop_background)"; then
    mutants=$((mutants + 1))
    run_mutant "$m" grim slurp wl-copy notify-send \
        -- XDG_CURRENT_DESKTOP=labwc:wlroots STUB_WLCOPY_SLEEP=20 -- output
    want "self-test the script waiting on wl-copy: caught" test "$ELAPSED" -ge 10000
else
    bad "self-test could not build the blocking-wl-copy mutant"
fi

# Mutant 4: the missing-grim guard reports success, which is the shape of the
# original bug — a key that does nothing and says nothing.
soften_missing_grim() {
    sed -i "/grim is required off Hyprland/{n;s/^    exit 1\$/    exit 0/}" "$1"
}
if m="$(mutate silent-missing-grim soften_missing_grim)"; then
    mutants=$((mutants + 1))
    run_mutant "$m" slurp wl-copy notify-send \
        -- XDG_CURRENT_DESKTOP=labwc:wlroots -- output
    want "self-test a missing grim reported as success: caught" test "$RC" -eq 0
else
    bad "self-test could not build the silent-missing-grim mutant"
fi

# Mutant 5: grimblast loses --freeze, so an area is picked over the live screen.
drop_freeze_flag() { sed -i 's/grimblast -n --freeze copysave/grimblast -n copysave/' "$1"; }
if m="$(mutate no-freeze-flag drop_freeze_flag)"; then
    mutants=$((mutants + 1))
    run_mutant "$m" grimblast grim slurp wl-copy notify-send hyprctl hyprpicker \
        -- HYPRLAND_INSTANCE_SIGNATURE=sig123 XDG_CURRENT_DESKTOP=Hyprland -- area
    if [[ "$(argv_of grimblast)" != "-n --freeze copysave "* ]]; then
        ok "self-test grimblast without --freeze: caught"
    else
        bad "self-test the argv check cannot see a missing --freeze"
    fi
else
    bad "self-test could not build the no-freeze-flag mutant"
fi

# Mutant 6: the layer rule is not pushed, so on a Lua config the still fades
# in and slurp's border is captured on its way out.
drop_layer_rule() {
    sed -i 's/&& apex_screenshot_layers_command hyprland; then/\&\& false; then/' "$1"
}
if m="$(mutate no-layer-rule drop_layer_rule)"; then
    mutants=$((mutants + 1))
    run_mutant "$m" grimblast grim slurp wl-copy notify-send hyprctl hyprpicker \
        -- HYPRLAND_INSTANCE_SIGNATURE=sig123 XDG_CURRENT_DESKTOP=Hyprland -- area
    # grimblast must still have run: a mutant that merely broke the script
    # would pass the hyprctl half for the wrong reason.
    want "self-test an area capture with no layer rule: caught" not_called hyprctl
    want "self-test ...on a script that still captured"          called grimblast
else
    bad "self-test could not build the no-layer-rule mutant"
fi

# Mutant 7: no EXIT trap, so a cancelled selection leaves the screen frozen.
drop_trap() { sed -i '/^trap unfreeze EXIT$/d' "$1"; }
if m="$(mutate no-unfreeze-trap drop_trap)"; then
    mutants=$((mutants + 1))
    run_mutant "$m" grim slurp wl-copy notify-send hyprpicker \
        -- XDG_CURRENT_DESKTOP=labwc:wlroots STUB_SLURP_CANCEL=1 -- area
    if freeze_released; then
        bad "self-test the release check cannot see a freeze left up"
    else
        ok "self-test a cancelled selection left frozen: caught"
    fi
else
    bad "self-test could not build the no-unfreeze-trap mutant"
fi

# Mutant 8: no release after the capture; the trap still ends the freeze, but
# only once the toast and the clipboard hand-off are done with.
drop_early_release() { sed -i '/^unfreeze$/d' "$1"; }
if m="$(mutate late-release drop_early_release)"; then
    mutants=$((mutants + 1))
    run_mutant "$m" grim slurp wl-copy notify-send hyprpicker \
        -- XDG_CURRENT_DESKTOP=labwc:wlroots -- area
    want "self-test the screen still frozen at the toast: caught" test -f "$CALLS.frozen-during-notify"
    freeze_released || :
else
    bad "self-test could not build the late-release mutant"
fi

# ...and the control, or the verdicts above would hold with the harness broken
# outright: the unmutated script, copied, still reaches grim on labwc, and
# still freezes for the capture and releases before the toast.
cp "$script" "$work/control.sh"
run_mutant "$work/control.sh" grim slurp wl-copy notify-send \
    -- XDG_CURRENT_DESKTOP=labwc:wlroots -- output
want "the same harness still passes on an unmutated copy" called grim
run_mutant "$work/control.sh" grim slurp wl-copy notify-send hyprpicker \
    -- XDG_CURRENT_DESKTOP=labwc:wlroots -- area
want "...and still sees the freeze held for the capture" test -f "$CALLS.frozen-during-grim"
want "...and released before the toast"                  test ! -f "$CALLS.frozen-during-notify"
want "...and not left behind"                            freeze_released

echo
echo "self-test: mutants applied=$mutants"
echo "check-screenshot-dispatch: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
