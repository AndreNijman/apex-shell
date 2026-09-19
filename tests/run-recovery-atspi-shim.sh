#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-recovery-atspi-shim.sh — read the RECOVERY screen back over real AT-SPI,
#  and DRIVE it the way a screen reader would (roadmap P2-003).
#
#  ── What this answers that tests/check-recovery-a11y.sh cannot ──────────────
#
#  That suite reads the source and asks whether the two rules the markup has to
#  follow are still followed. This one asks whether the markup ARRIVES, and
#  then whether a reader can actually complete the most consequential flow on
#  the page using nothing but the accessibility bus.
#
#  It is the same instrument as tests/run-lockscreen-atspi-shim.sh: quickshell
#  destroys a QCoreApplication before constructing its QGuiApplication, which
#  clears Qt's accessibility factory list for the life of the process, so the
#  shell publishes exactly one node until tests/quickshell-a11y-shim.cpp puts
#  the factory back from inside. tests/check-quickshell-a11y-cause.sh is the
#  standalone proof of that cause and needs no compositor at all.
#
#  ── The control is INSIDE the run ───────────────────────────────────────────
#
#  §4 reads the tree back BEFORE the shim installs anything and requires
#  exactly one node: the defect, re-measured in this very run, on this very
#  compositor, with these very buses. Everything after it is therefore
#  attributable to the factory install and to nothing else.
#
#  ── The machine it interrogates is a stub, and the stub RECORDS ─────────────
#
#  `apex recover status --json`, `apex doctor --json` and the reset dry run are
#  answered from fixtures captured from a real `apex` (the same payloads
#  tests/recovery-test.js carries), so every string this suite asserts is one
#  it chose rather than whatever this machine happens to be today. The stub
#  also appends its argv to a log, and that log is what makes the destructive
#  half checkable in both directions:
#
#    * press the Erase button over the bus BEFORE the loss list exists and NO
#      `--commit` may appear;
#    * press it after, and the exact argv — including the confirm token the
#      plan printed — MUST appear.
#
#  The second is the load-bearing one. Until 2026-09-19 it was impossible: the
#  service acknowledged the loss list one line before the phase allowed it and
#  `commitReady` was false for ever, so the factory reset could not be
#  completed by anybody. That is what pressing this button over AT-SPI found.
#
#  ── What it does NOT claim ─────────────────────────────────────────────────
#
#  Not that the shell is accessible. It is not: the factory is put back by an
#  LD_PRELOAD that exists only in this test tree, and on a real machine a
#  screen reader still gets one node from the shell. What it claims is that the
#  markup on this page is correct all the way to the bus and that the flows are
#  completable through it, so the whole remaining defect is the upstream one.
#
#  Read the totals line, never the tick: this suite exits 0 on a skip.
#
#  Run from anywhere: ./tests/run-recovery-atspi-shim.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

pass=0; fail=0; skip=0
ok()   { echo "  ok   $1${2:+  — $2}"; pass=$((pass + 1)); }
bad()  { echo "  FAIL $1${2:+  — $2}"; fail=$((fail + 1)); }
nope() { echo "  SKIP $1${2:+  — $2}"; skip=$((skip + 1)); }
section() { printf '\n── %s ──\n' "$1"; }
totals() {
    printf '\nrecovery-atspi-shim: passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
}

# shellcheck source=tests/lib/headless.sh
. "$here/lib/headless.sh"
# shellcheck source=tests/lib/atspi.sh
. "$here/lib/atspi.sh"

WALK="$here/atspi-walk.py"
SHIM_SRC="$here/quickshell-a11y-shim.cpp"
PAGE="$root/src/services/config_tab/pages/RecoveryPage.qml"
for f in "$WALK" "$SHIM_SRC" "$PAGE" "$root/shell.qml"; do
    [ -f "$f" ] || { echo "FATAL: this tree has no ${f#"$root/"}" >&2; exit 2; }
done

# The fixture's own facts, spelled here so a change to either side is a visible
# disagreement rather than a silently weakened assertion.
FX_TOKEN="desktop:4:5d7f91ba"
FX_LOSSES=4
FX_CACHE=".cache/apex-shell"
FX_ATTENTION="Secure Boot"
FX_ROUTE_UNKNOWN="installer-media"
FX_DOCTOR_WARN="ACPI platform_profile present"

# ─────────────────────────────────────────────────────────────────────────────
section "§0 this suite calls each assertion by ONE name, whatever the outcome"
# ─────────────────────────────────────────────────────────────────────────────
#
# Deliberately ABOVE every skip-out, so it runs on machines that can host
# nothing else here — the Arch runner has no quickshell and would otherwise
# leave this unchecked for ever.
#
# The defect it gates was found by tests/mutate-recovery-atspi-shim.sh on
# 2026-09-19, and it is the assertion-level version of a shape this tree keeps
# meeting. The pre-plan Erase row used to say
#
#     ok   … the Erase button reports NO states at all — a reader is told it is unavailable
#     FAIL … the Erase button reports itself unavailable
#
# — one row with two names. Nothing about that is visible in a diff, and
# everything that keys on the assertion breaks: a mutation harness verifies a
# mutant's target against the `ok` wording and then looks for it in the `FAIL`
# wording, finds nothing, and scores MISSCORED — a real defect reported as a
# broken expectation. A human diffing two runs loses the row the same way.
#
# So: every `bad` title must be a substring of some `ok` or `nope` title. That
# is the exact property the harness depends on, stated once, checked here.
if ! command -v python3 >/dev/null 2>&1; then
    nope "every assertion is called by the same name whether it passes or fails" \
         "no python3, so this suite's own source could not be parsed"
else
    drift="$(python3 - "${BASH_SOURCE[0]}" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# The FIRST quoted argument of every ok/bad/nope call is the assertion's name;
# the optional second is the detail, which is free to differ and should.
calls = [(m.group(1), m.group(2))
         for m in re.finditer(r'\b(ok|bad|nope)\s+"((?:[^"\\]|\\.)*)"', src)]
titles = {k: [t for w, t in calls if w == k] for k in ("ok", "bad", "nope")}
# A negative control, so this check is never a gate that inspects nothing: the
# same matcher, run over a pair that HAS drifted, must find it.
control = [t for t in ["a row that reports NO states at all"]
           if not any(t in o for o in ["a row that reports itself unavailable"])]
if len(control) != 1:
    print("CONTROL-FAILED")
    sys.exit(0)
orphans = sorted({b for b in titles["bad"]
                  if not any(b in o for o in titles["ok"] + titles["nope"])})
print("%d %d %d" % (len(titles["ok"]), len(titles["bad"]), len(titles["nope"])))
for o in orphans:
    print("   ", o)
PY
)"
    if [ "$(printf '%s\n' "$drift" | head -1)" = "CONTROL-FAILED" ]; then
        bad "every assertion is called by the same name whether it passes or fails" \
            "the matcher did not flag a pair that HAS drifted, so it would not have flagged a real one either"
    elif [ "$(printf '%s\n' "$drift" | wc -l)" -eq 1 ]; then
        ok "every assertion is called by the same name whether it passes or fails" \
           "$(printf '%s\n' "$drift" | head -1 | awk '{print $1" ok / "$2" FAIL / "$3" SKIP titles"}')"
    else
        bad "every assertion is called by the same name whether it passes or fails" \
            "these FAIL titles appear under no ok/SKIP title, so a harness that verified the ok wording cannot match the FAIL wording"
        printf '%s\n' "$drift" | tail -n +2 | sed 's/^/      /'
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§1 what it takes to run at all — each missing piece named separately"
# ─────────────────────────────────────────────────────────────────────────────

if ! atspi_require; then
    echo "SKIP: no accessibility stack, so nothing here was measured."
    nope "the whole suite" "at-spi is not available"
    totals; exit 0
fi
if ! command -v quickshell >/dev/null 2>&1; then
    echo "SKIP: no quickshell, so nothing here was measured."
    nope "the whole suite" "quickshell is not installed (it is an AUR package on Arch)"
    totals; exit 0
fi
CXX=""
for c in g++ c++ clang++; do command -v "$c" >/dev/null 2>&1 && { CXX="$c"; break; }; done
if [ -z "$CXX" ]; then
    echo "SKIP: no C++ compiler, so the instrument cannot be built."
    nope "the whole suite" "no g++/c++/clang++ on PATH"
    totals; exit 0
fi
if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists Qt6Quick Qt6Gui Qt6Core; then
    echo "SKIP: no Qt 6 Quick development files, so the instrument cannot be built."
    nope "the whole suite" "pkg-config cannot find Qt6Quick/Qt6Gui/Qt6Core"
    totals; exit 0
fi

# Qt's PRIVATE headers. Discovered, never hardcoded: the version directory is
# part of the path and differs on every Qt release, and a hardcoded one reports
# "Qt is missing" on a machine that has it.
INCDIR="$(pkg-config --variable=includedir Qt6Core 2>/dev/null)"
PRIV_INC=()
PRIV_PROBE=""
if [ -n "$INCDIR" ]; then
    for mod in QtCore QtGui QtQml QtQuick; do
        d="$(ls -d "$INCDIR/$mod"/*/"$mod" 2>/dev/null | head -1)"
        [ -n "$d" ] && PRIV_INC+=(-I"${d%/"$mod"}" -I"$d")
    done
    PRIV_PROBE="$(ls "$INCDIR"/QtQuick/*/QtQuick/private/qaccessiblequickview_p.h 2>/dev/null | head -1)"
fi
if [ -z "$PRIV_PROBE" ]; then
    echo "SKIP: Qt 6 PRIVATE headers are not installed, so the instrument cannot"
    echo "      be built. On Fedora that is qt6-qtbase-private-devel plus"
    echo "      qt6-qtdeclarative-devel; the path looked for was"
    echo "      ${INCDIR:-<no includedir>}/QtQuick/<version>/QtQuick/private/qaccessiblequickview_p.h"
    nope "the whole suite" "no qaccessiblequickview_p.h under ${INCDIR:-<no includedir>}"
    totals; exit 0
fi
echo "  note: Qt $(pkg-config --modversion Qt6Core), $CXX, private headers at ${PRIV_PROBE%/qaccessiblequickview_p.h}"

# ─────────────────────────────────────────────────────────────────────────────
section "§2 the instrument builds, and it really does interpose"
# ─────────────────────────────────────────────────────────────────────────────

W="$(mktemp -d "${TMPDIR:-/tmp}/recovery-atspi-shim.XXXXXX")" || exit 2
SHIM="$W/shim.so"
TRIGGER="$W/install-now"

# A build failure HERE is a failure, not a skip: every prerequisite above was
# found, so the only remaining explanations are a broken instrument or a Qt
# whose private API moved, and both are things this suite should say.
# shellcheck disable=SC2046,SC2086
if ! $CXX -std=c++17 -fPIC -shared -o "$SHIM" "$SHIM_SRC" \
        $(pkg-config --cflags Qt6Quick Qt6Gui Qt6Core) "${PRIV_INC[@]}" \
        $(pkg-config --libs Qt6Quick Qt6Gui Qt6Core) -ldl >"$W/build.log" 2>&1; then
    bad "tests/quickshell-a11y-shim.cpp builds against this machine's Qt 6" \
        "every prerequisite was present, so this is the instrument or Qt's private API"
    sed 's/^/      /' "$W/build.log" | head -25
    totals; exit 1
fi
ok "tests/quickshell-a11y-shim.cpp builds against this machine's Qt 6"

# Captured into a variable and matched with a bash substring test, NOT
# `nm | grep -q`: under `set -o pipefail` a grep -q that MATCHES closes the
# pipe, nm dies with SIGPIPE, and the pipeline's status is 141 — so the
# assertion fails precisely when it should pass.
QS_BIN="$(command -v quickshell)"
QS_DYNSYMS="$(nm -D "$QS_BIN" 2>/dev/null || true)"
if [ -z "$QS_DYNSYMS" ]; then
    nope "quickshell calls QGuiApplication::exec() through the PLT" \
         "nm read no dynamic symbols from $QS_BIN, so this could not be checked"
elif [[ "$QS_DYNSYMS" == *"U _ZN15QGuiApplication4execEv"* ]]; then
    ok "quickshell calls QGuiApplication::exec() through the PLT, so LD_PRELOAD can take it"
else
    bad "quickshell calls QGuiApplication::exec() through the PLT, so LD_PRELOAD can take it" \
        "the symbol is not UNDEFINED in $QS_BIN; the preload cannot hook and nothing below would measure the shell"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§3 a private compositor, two private buses, and a RECORDING apex"
# ─────────────────────────────────────────────────────────────────────────────

app_pid=""
cleanup() {
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null
    sleep 0.3
    [ -n "$app_pid" ] && kill -9 "$app_pid" 2>/dev/null
    atspi_cleanup
    headless_cleanup
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

headless_begin

# rm -f FIRST. headless_begin makes bin/apex, bin/loginctl and bin/busctl
# SYMLINKS to one shared stub, so `cat > …/apex` writes THROUGH the link and
# turns every other stub into an apex. And busctl at all because headless_begin
# does not stub it, so the shell's PowerProfileService would otherwise reach
# the real system bus.
rm -f "$HEADLESS_W/bin/apex" "$HEADLESS_W/bin/loginctl" "$HEADLESS_W/bin/busctl"
APEX_ARGV="$HEADLESS_W/apex-argv.log"
: > "$APEX_ARGV"

# Captured payloads, not invented ones. These are the shapes apexd really
# produces — `action` null on most rows, `available` null (not false) on
# installer-media, the doctor's two-space continuation indent, and a plan that
# lists targets which do NOT exist alongside ones that do — trimmed from the
# fixtures in tests/recovery-test.js, whose header records how they were taken.
# The token's count is 4 because exactly four targets have exists:true, which is
# the same filter the loss list applies; that equality is what makes "the user
# saw what would be lost" a precondition the code can check.
python3 - "$HEADLESS_W" "$FX_TOKEN" <<'PY'
import json, sys
w, token = sys.argv[1], sys.argv[2]
H = "/var/home/andre"
rows = [
    {"action": None, "id": "current-deployment", "label": "Current deployment",
     "state": "verified", "detail": "ostree 96351335ae0b — APEX-OS 43 daily"},
    {"action": "sudo apex rollback", "id": "previous-deployment",
     "label": "Previous deployment", "state": "available",
     "detail": "2 deployments present, so there is one to go back to. Nothing has verified that it boots."},
    {"action": "sudo apex update", "id": "secure-boot", "label": "Secure Boot",
     "state": "attention", "detail": "firmware reports Secure Boot enabled"},
    {"action": None, "id": "filesystem", "label": "Filesystem",
     "state": "verified", "detail": "/usr is read-only on a overlay root, ostree-booted"},
    {"action": None, "id": "gpu-driver", "label": "GPU driver",
     "state": "verified", "detail": "1 — AMD via amdgpu"},
    {"action": None, "id": "apex-shell", "label": "APEX Shell",
     "state": "verified", "detail": "vendored in the image at /usr/share/apex-shell"},
    {"action": None, "id": "network", "label": "Network",
     "state": "available", "detail": "a default route exists. Nothing was contacted."},
    {"action": None, "id": "package-extensions", "label": "Package extensions",
     "state": "verified", "detail": "no user packages on this machine"},
]
status = {
    "bootloader": "grub", "needsAttention": 1, "rows": rows,
    "actions": [],
    "routes": [
        {"id": "previous-deployment", "available": True, "how": "`sudo apex rollback` then reboot."},
        {"id": "rescue-target", "available": True, "how": "at the grub menu, edit the entry."},
        {"id": "boot-counting", "available": False, "how": "not in effect: this machine boots through GRUB."},
        {"id": "disposable-environment", "available": False, "how": "`apex disposable run` gives you a throwaway userspace."},
        {"id": "recovery-boot-entry", "available": False, "how": "APEX ships no recovery boot entry."},
        {"id": "installer-media", "available": None, "how": "cannot be determined from a running system."},
    ],
    "resetScopes": [
        {"id": "desktop", "summary": "APEX Shell's settings, keybinds and caches for this account"},
        {"id": "user", "summary": "everything under `desktop`, PLUS your blueprint"},
    ],
}
doctor = {
    "checks": [
        {"check": "apexd running (owns org.apexos.Apexd1)", "ok": True},
        {"check": "cpufreq scaling driver present (amd-pstate-epp)", "ok": True},
        {"check": "touchpad: ELAN06DA:00 04F3:320B Touchpad", "ok": True},
        {"check": "  multitouch slots (ABS_MT_SLOT): present", "ok": True},
        {"check": "  button layout: clickpad (INPUT_PROP_BUTTONPAD)", "ok": True},
        {"check": "ACPI platform_profile present", "ok": False},
        {"check": "metrics endpoint reachable on 127.0.0.1:9723", "ok": True},
    ],
    "passed": 6, "warned": 1, "total": 7,
}
def t(rel, exists, backed, what, disp="delete", kind="file"):
    return {"path": H + "/" + rel, "relative": rel, "disposition": disp,
            "kind": kind, "exists": exists, "backedUp": backed, "what": what}
plan = {
    "committed": False, "confirmToken": token, "scope": "desktop",
    "summary": "APEX Shell's settings, keybinds and caches for this account",
    "provisioner": "/usr/libexec/apex-shell-firstrun", "reprovision": True,
    "preserved": [
        "every document, project, checkout and credential in your home directory",
        "~/.ssh, ~/.gnupg, ~/.aws and every browser profile",
    ],
    "preservedLandmarks": [".ssh", ".gnupg"],
    "targets": [
        t(".config/apex-shell/display.json", False, True, "saved monitor layout, scale and refresh rate"),
        t(".config/apex-shell/ApexShellKeybinds.conf", True, True, "the retired hyprlang keybind fragment"),
        t(".config/apex-shell/ApexShellKeybinds.kdl", True, True, "the generated niri keybinds"),
        t(".config/apex-shell/ApexShellKeybinds.lua", True, True, "the generated labwc keybinds"),
        t(".cache/apex-shell", True, False, "the shell's cache: generated colour scheme, thumbnails", kind="dir"),
        t(".config/hypr/apex/input.lua", False, True,
          "the generated Hyprland input overrides (emptied, not removed)", disp="truncate"),
    ],
}
for name, obj in (("status", status), ("doctor", doctor), ("plan-desktop", plan)):
    open("%s/%s.json" % (w, name), "w", encoding="utf-8").write(json.dumps(obj))
PY

cat > "$HEADLESS_W/bin/apex" <<FAKE
#!/usr/bin/env bash
printf 'apex %s\n' "\$*" >> "$APEX_ARGV"
case "\$*" in
    "recover status --json")             cat "$HEADLESS_W/status.json"; exit 0 ;;
    "doctor --json")                     cat "$HEADLESS_W/doctor.json"; exit 0 ;;
    *"recover reset"*"--commit"*)        echo "Reset complete."; exit 0 ;;
    *"recover reset"*"--scope desktop"*) cat "$HEADLESS_W/plan-desktop.json"; exit 0 ;;
    *--json*)                            echo "{}"; exit 0 ;;
esac
exit 0
FAKE
cat > "$HEADLESS_W/bin/loginctl" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat > "$HEADLESS_W/bin/busctl" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$HEADLESS_W/bin/apex" "$HEADLESS_W/bin/loginctl" "$HEADLESS_W/bin/busctl"

if ! headless_start; then
    echo "SKIP: no compositor, so nothing here was measured."
    nope "everything below §3" "no nested compositor"
    totals; exit 0
fi
COMP_RUNTIME="$XDG_RUNTIME_DIR"
COMP_SOCKET="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
if ! atspi_start; then
    echo "SKIP: the private accessibility bus did not come up."
    nope "everything below §3" "no private a11y bus; this is a could-not-run, not a pass"
    totals; exit 0
fi
export XDG_RUNTIME_DIR="$COMP_RUNTIME"

# This row STOPS the suite rather than counting a failure and carrying on, and
# the reason is not tidiness. §4 launches `quickshell -p` against whatever
# XDG_RUNTIME_DIR/WAYLAND_DISPLAY hold at that moment. If the a11y bus setup has
# moved either of them back to the LOGGED-IN session's, that launch puts the
# shell on the real desktop. Every other assertion here can afford to fail and
# let the rest of the run report; this one cannot, because the thing it guards
# happens after it.
if [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] &&
   [ "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" -ef "$COMP_SOCKET" ]; then
    ok "the compositor socket survived the bus setup and is still this run's own"
else
    bad "the compositor socket survived the bus setup and is still this run's own" \
        "WAYLAND_DISPLAY no longer names the socket headless_start brought up. REFUSING to go on: §4 would launch quickshell against this display, and if it is the logged-in session's then that is a window on somebody's desktop."
    totals; exit 1
fi

case "$ATSPI_STATUS" in
    *"'ScreenReaderEnabled': <true>"*)
        ok "org.a11y.Status.ScreenReaderEnabled is true, as a screen reader sets it" ;;
    *)  bad "org.a11y.Status.ScreenReaderEnabled is true, as a screen reader sets it" \
            "got ${ATSPI_STATUS:-<no answer>}; Qt's bridge publishes nothing with this false" ;;
esac
echo "  note: host $HEADLESS_COMP on $WAYLAND_DISPLAY at $HEADLESS_MODE"

# ─────────────────────────────────────────────────────────────────────────────
section "§4 the shell, the page, and THE CONTROL — the defect, re-measured here"
# ─────────────────────────────────────────────────────────────────────────────

shell_log="$W/shell.log"
QT_LOGGING_RULES="qml=true" atspi_run_app env \
    LD_PRELOAD="$SHIM" APEX_SHIM_TRIGGER="$TRIGGER" \
    quickshell -p "$root/shell.qml" >"$shell_log" 2>&1 &
app_pid=$!

for _ in $(seq 1 160); do grep -q "Configuration Loaded" "$shell_log" && break; sleep 0.25; done
if ! grep -q "Configuration Loaded" "$shell_log"; then
    bad "the shipped shell loads on the private compositor, under the preload" "it never loaded"
    tail -20 "$shell_log"
    totals; exit 1
fi
ok "the shipped shell loads on the private compositor, under the preload"

if grep -q 'APEXSHIM: interposed QGuiApplication::exec()' "$shell_log"; then
    ok "the preload really took QGuiApplication::exec() in THIS process"
else
    bad "the preload really took QGuiApplication::exec() in THIS process" \
        "the shim never announced itself; everything below would be about an unmodified shell"
fi

if quickshell -p "$root/shell.qml" ipc call nexus open recovery >"$W/ipc.txt" 2>&1; then
    ok "the shipped 'nexus open recovery' IPC handler accepts the call"
else
    bad "the shipped 'nexus open recovery' IPC handler accepts the call" \
        "the call failed: $(head -1 "$W/ipc.txt")"
fi

# The IPC handler answers "nexus open at recovery" whether or not any Nexus
# delegate matched the focused screen name, so the reply is NOT the evidence.
# This is: the page's ServiceRef only goes active when the page is genuinely on
# screen, and RecoveryService logs its sweep when it has one. A wait on a fact
# the shell produced, not a sleep.
for _ in $(seq 1 120); do
    grep -q 'RecoveryService: 8 component row(s)' "$shell_log" && break
    sleep 0.25
done
if grep -q 'RecoveryService: 8 component row(s) - 1 needing attention' "$shell_log"; then
    ok "the page came up and swept the (stubbed) machine — 8 rows, 1 needing attention"
else
    bad "the page came up and swept the (stubbed) machine" \
        "no sweep logged in 30s. The IPC reply is not evidence that a Nexus window matched the focused screen; without the sweep the page is not on screen and nothing below is about it. Log said: $(grep -c . "$shell_log") lines, last: $(tail -1 "$shell_log")"
fi

# The stub really is the machine this page read. Without this the page could
# have been answering from the real `apex` and every string below would be
# about this laptop.
if grep -q '^apex recover status --json$' "$APEX_ARGV" && grep -q '^apex doctor --json$' "$APEX_ARGV"; then
    ok "and it read the FIXTURE, not this machine — both polled verbs are in the argv log"
else
    bad "and it read the FIXTURE, not this machine" \
        "the stub recorded: $(tr '\n' ';' <"$APEX_ARGV")"
fi

# ── the control ─────────────────────────────────────────────────────────────
sleep 2
python3 "$WALK" --dump >"$W/tree-before.txt" 2>/dev/null
# `|| true`, never `|| echo 0`: on an EMPTY file grep -c prints "0" AND exits 1,
# so the fallback appends a second line and the variable becomes "0\n0" — which
# then makes the numeric comparison in §5 error out instead of reporting the
# zero case its own message describes. The empty-string case is set to 0 after.
before_nodes="$(grep -c . "$W/tree-before.txt" 2>/dev/null || true)"
[ -n "$before_nodes" ] || before_nodes=0
if [ "$before_nodes" = "1" ]; then
    ok "CONTROL: with the factory still cleared, the whole shell publishes ONE node"
else
    bad "CONTROL: with the factory still cleared, the whole shell publishes ONE node" \
        "$before_nodes nodes. If it is MORE, upstream has been fixed and this whole instrument is obsolete — delete it and write the read-back straight. If it is ZERO, the shell is not on the bus at all and everything below measures nothing."
    sed 's/^/      /' "$W/tree-before.txt" | head -10
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§5 the factory goes back, and the page arrives"
# ─────────────────────────────────────────────────────────────────────────────

: > "$TRIGGER"
for _ in $(seq 1 120); do grep -q 'APEXSHIM: DONE' "$shell_log" && break; sleep 0.25; done
if ! grep -q 'APEXSHIM: DONE' "$shell_log"; then
    bad "the shim installs the factory when asked" "it never finished; the trigger file was $TRIGGER"
    grep '^APEXSHIM' "$shell_log" | sed 's/^/      /'
    totals; exit 1
fi
ok "the shim installs the factory when asked"

sleep 3
python3 "$WALK" --dump >"$W/tree.txt" 2>/dev/null
nodes="$(grep -c . "$W/tree.txt" 2>/dev/null || true)"
[ -n "$nodes" ] || nodes=0
echo "  note: $before_nodes node(s) before the install, $nodes after"
if [ "$nodes" -gt "$before_nodes" ]; then
    ok "restoring the factory alone makes the shell publish a tree ($before_nodes → $nodes nodes)"
else
    bad "restoring the factory alone makes the shell publish a tree" \
        "$before_nodes → $nodes; the factory is not the whole cause and the standalone finding is incomplete"
fi

# ── the page is a named GROUP, and it is the one on screen ──────────────────
#
# Until CfgSection carried a role, the Nexus window published a FLAT run of
# controls at one depth with several pages' controls mixed together, and
# nothing said which page was open. The pair below is what separates "on
# another page" from "below the fold": `showing,visible` alone does not, because
# most of this page's own controls are below the fold in a 1280x720 window.
rec_panel="$(grep -E '^ +[0-9]+ \| role=panel \| name=Recovery \|' "$W/tree.txt" | head -1)"
oth_panel="$(grep -E '^ +[0-9]+ \| role=panel \| name=Palette \|' "$W/tree.txt" | head -1)"
if [ -z "$rec_panel" ]; then
    bad "the Recovery section reaches the bus as a named group" \
        "no node with role=panel and name=Recovery; CfgSection's Accessible.role is what creates it"
else
    ok "the Recovery section reaches the bus as a named group"
fi
states_of() { printf '%s\n' "$1" | sed -n 's/.*| states=\([^|]*\)|.*/\1/p'; }
if [ -z "$oth_panel" ]; then
    nope "…and it is the page ON SCREEN, where another page's section is not" \
         "no Palette section in the tree to contrast against — the Nexus window instantiated only one page, so this run cannot tell the two apart. A one-sided version of this row would pass on a window with nothing to distinguish."
elif [ -n "$rec_panel" ]; then
    rec_st="$(states_of "$rec_panel")"; oth_st="$(states_of "$oth_panel")"
    rec_on=0; oth_on=0
    case "$rec_st" in *showing*visible*) rec_on=1 ;; esac
    case "$oth_st" in *showing*) oth_on=1 ;; esac
    if [ "$rec_on" = "1" ] && [ "$oth_on" = "0" ]; then
        ok "…and it is the page ON SCREEN, where another page's section is not (Recovery:$rec_st vs Palette:$oth_st)"
    else
        bad "…and it is the page ON SCREEN, where another page's section is not" \
            "Recovery:$rec_st  Palette:$oth_st — asserted as a PAIR on purpose: showing alone does not separate 'on another page' from 'below the fold', because most of this page's own controls are below the fold at 1280x720"
    fi
fi

# ── the content, which published NOTHING before round 31 ────────────────────
want_row() {   # <role> <name substring> <what it is>
    local role="$1" want="$2" what="$3" line
    line="$(grep -F "role=$role | name=$want" "$W/tree.txt" | head -1)"
    if [ -n "$line" ]; then
        ok "$what"
    else
        bad "$what" "no node with role=$role and a name containing '$want'"
    fi
}

want_row "label"     "1 component needs attention" \
    "the page's headline fact reaches the bus, in words"
want_row "list item" "$FX_ATTENTION — Needs attention" \
    "a component row carries its STATE as a word, not as the glyph beside it"
want_row "list item" "$FX_ROUTE_UNKNOWN — cannot be determined from a running system" \
    "a tri-state route says 'cannot be determined' and not 'no' — the distinction the tick/cross/dash carries for the eye"
want_row "list item" "warning — $FX_DOCTOR_WARN" \
    "a doctor check that warns says 'warning', with the severity the payload really carries"

# a11yExtra. CfgRow adopts a child with no accessible name and gives it the
# ROW's label, so the command this row exists to hand over was replaced by the
# row's title and appeared nowhere in the tree.
rb="$(grep -F 'name=Boot the previous deployment' "$W/tree.txt" | head -1)"
case "$rb" in
    *"The command is: sudo apex rollback"*)
        ok "the rollback COMMAND reaches the bus — the one thing that row exists to hand over" ;;
    *)  bad "the rollback COMMAND reaches the bus" \
            "got: ${rb:-<no such node>}. Without a11yExtra the row is adopted and renamed to its own label, and the command is spoken nowhere." ;;
esac

# Private-use codepoints, over the WHOLE tree rather than the nodes above. The
# rule is about the class: a reader that reaches one says "private use
# character" out loud before the words it was supposed to read.
pua="$(python3 - "$W/tree.txt" <<'PY'
import re, sys
# All three ranges, written as escapes rather than as the characters
# themselves: a literal did not survive being written to a file the last two
# times this unit tried it, and an unprintable character in a source file is
# not reviewable.
pua = re.compile('[-\U000f0000-\U000ffffd\U00100000-\U0010fffd]')
hits = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    for field in ("name=", "desc="):
        i = line.find(field)
        if i < 0:
            continue
        v = line[i + len(field):].split(" | ")[0]
        if pua.search(v):
            hits.append(field + v)
print(len(hits))
for h in hits:
    print("   ", h)
PY
)"
if [ "$(printf '%s\n' "$pua" | head -1)" = "0" ]; then
    ok "not one of this page's twelve glyphs reaches the bus inside a name or a description"
else
    bad "not one of this page's twelve glyphs reaches the bus inside a name or a description" \
        "$(printf '%s\n' "$pua" | head -1) accessible string(s) carry one"
    printf '%s\n' "$pua" | tail -n +2 | sed 's/^/      /'
fi

# ─────────────────────────────────────────────────────────────────────────────
section "§6 the destructive flow, walked with nothing but the bus"
# ─────────────────────────────────────────────────────────────────────────────
#
# Four deliberate acts, and a reader must be able to make all four — or none of
# the safety this section is built around means anything to them. Before round
# 31 they could make three and then meet nothing at all.

# A name matched by --do-action must be UNIQUE, or the harness may press a
# different control with the same words. "Reset" already appears twice in this
# window.
unique_name() {   # <name> -> 0 if exactly one node has it
    local n; n="$(grep -cF "| name=$1 |" "$W/tree.txt")"
    [ "$n" = "1" ]
}

press() {   # <accessible name> -> the DoAction reply
    python3 "$WALK" --do-action "$1" 2>&1 | tail -1
}

if unique_name "Open"; then
    ok "the disclosure's button is uniquely named, so pressing it by name cannot hit something else"
else
    bad "the disclosure's button is uniquely named" \
        "$(grep -cF '| name=Open |' "$W/tree.txt") nodes are named 'Open'; --do-action takes the first and this suite would not know which"
fi

# ── act 1: open the disclosure ──────────────────────────────────────────────
open_reply="$(press "Open")"
sleep 2
python3 "$WALK" --dump >"$W/tree-open.txt" 2>/dev/null
if grep -qF '| name=Close |' "$W/tree-open.txt"; then
    ok "ACT 1: pressing 'Open' over the bus really opens the disclosure — the button now reads 'Close'"
else
    bad "ACT 1: pressing 'Open' over the bus really opens the disclosure" \
        "DoAction said '$open_reply' but no node is named 'Close'. Note that a True from DoAction means the action was DISPATCHED, never that it did anything."
fi

# ── the button, before there is anything to erase ───────────────────────────
#
# It IS on the bus — FOUND 16, an invisible Qt Quick item still publishes its
# whole subtree — so the question is not whether a reader can find it but what
# it tells them. With only `visible` gating it, the node arrived carrying
# `enabled,sensitive` and a Press action: a live-looking destructive button
# that refuses in silence.
pre="$(grep -E '^ +[0-9]+ \| role=push button \| name=Erase \|' "$W/tree-open.txt" | head -1)"
if [ -z "$pre" ]; then
    nope "before the plan exists the Erase button reports itself unavailable" \
         "there is no 'Erase' node before the plan — if Qt has stopped publishing invisible items, FOUND 16 has moved and this assertion needs rewriting rather than deleting"
else
    # The states field, taken out by name rather than matched inside the whole
    # line: `enabled` also appears in no other field here today, and a
    # substring test over the line would start lying the day a description
    # contains the word.
    pre_states="$(printf '%s\n' "$pre" | sed -n 's/.*| states=\([^|]*\)|.*/\1/p' | tr -d ' ')"
    if [ -z "$pre_states" ]; then
        ok "before the plan exists the Erase button reports itself unavailable" \
            "it carries no states at all, which is how a reader is told"
    else
        bad "before the plan exists the Erase button reports itself unavailable" \
            "it carries states=$pre_states. Binding \`enabled\` to RecoveryService.commitReady is what Qt maps to the enabled/sensitive states; without it a reader meets a live-looking destructive button and is refused in silence."
    fi
fi

# ── and pressing it there changes nothing on the machine ────────────────────
#
# Note what this can and cannot show. The refusal is defence in depth — press()
# checks commitReady, commitReset() checks the phase, and commitArgv() checks
# the token and the rendered count — so NO SINGLE mutant makes a `--commit`
# appear here, and this row cannot be shown to fail by one edit. It is a
# statement about the whole guard rather than about any one of its three parts.
# The row that carries weight in both directions is ACT 4 below.
press "Erase" >/dev/null 2>&1
sleep 2
if grep -q -- '--commit' "$APEX_ARGV"; then
    bad "pressing Erase before the loss list exists commits NOTHING" \
        "the argv log already contains: $(grep -- '--commit' "$APEX_ARGV" | head -1)"
else
    ok "pressing Erase before the loss list exists commits NOTHING — the argv log has no --commit"
fi

# ── act 2 and 3: choose the scope, run the dry run ──────────────────────────
if unique_name "Desktop settings"; then
    ok "ACT 2: the scope is a uniquely named radio button a reader can choose"
else
    bad "ACT 2: the scope is a uniquely named radio button a reader can choose" \
        "$(grep -cF '| name=Desktop settings |' "$W/tree-open.txt") nodes carry that name"
fi

press "Show what would be lost" >/dev/null 2>&1
for _ in $(seq 1 60); do
    grep -q -- 'recover reset --scope desktop --json' "$APEX_ARGV" && break
    sleep 0.25
done
if grep -q -- 'apex recover reset --scope desktop --json' "$APEX_ARGV"; then
    ok "ACT 3: pressing 'Show what would be lost' over the bus really runs the dry run, and only the dry run"
else
    bad "ACT 3: pressing 'Show what would be lost' over the bus really runs the dry run, and only the dry run" \
        "the stub recorded: $(tr '\n' ';' <"$APEX_ARGV")"
fi

sleep 3
python3 "$WALK" --dump >"$W/tree-plan.txt" 2>/dev/null

# THE row this whole suite was written for. Before round 31 the dry run ran and
# the tree came back byte-identical: no count, no rows, no flag, no button.
loss_rows="$(grep -cE '^ +[0-9]+ \| role=list item \| name=\.(config|cache)/' "$W/tree-plan.txt")"
if [ "$loss_rows" = "$FX_LOSSES" ]; then
    ok "the loss list reaches the bus — $FX_LOSSES rows, the number the confirm token covers"
else
    bad "the loss list reaches the bus — $FX_LOSSES rows, the number the confirm token covers" \
        "found $loss_rows. The token is $FX_TOKEN and its middle field IS the row count, so a mismatch here is also a commit that cannot be built."
fi

nb="$(grep -cF "name=$FX_CACHE — NOT backed up" "$W/tree-plan.txt")"
if [ "$nb" = "1" ]; then
    ok "and the one target that is NOT copied aside first says so in its NAME, where a reader cannot skim past it"
else
    bad "and the one target that is NOT copied aside first says so in its NAME" \
        "$nb node(s) named '$FX_CACHE — NOT backed up'. It is the only row in the fixture with backedUp:false."
fi

if grep -qF "name=$FX_LOSSES item(s) will be changed" "$W/tree-plan.txt"; then
    ok "…and the count is spoken as well as listed"
else
    bad "…and the count is spoken as well as listed" \
        "no node names the number of items that would change"
fi

# ── act 4: the commit ───────────────────────────────────────────────────────
post="$(grep -E "^ +[0-9]+ \| role=push button \| name=Erase $FX_LOSSES item\(s\) now \|" "$W/tree-plan.txt" | head -1)"
if [ -z "$post" ]; then
    bad "with the list rendered, the Erase button becomes available on the bus" \
        "no node named 'Erase $FX_LOSSES item(s) now'"
else
    miss=""
    for st in enabled sensitive focusable; do
        case "$post" in *"$st"*) : ;; *) miss="$miss $st" ;; esac
    done
    case "$post" in *"actions=Press"*) : ;; *) miss="$miss Press-action" ;; esac
    if [ -z "$miss" ]; then
        ok "with the list rendered, the Erase button becomes available on the bus" \
            "enabled, sensitive, focusable, pressable"
    else
        bad "with the list rendered, the Erase button becomes available on the bus" \
            "missing:$miss in $post"
    fi
fi

press "Erase $FX_LOSSES item(s) now" >/dev/null 2>&1
for _ in $(seq 1 60); do
    grep -q -- '--commit' "$APEX_ARGV" && break
    sleep 0.25
done
commit_line="$(grep -- '--commit' "$APEX_ARGV" | head -1)"
if [ -z "$commit_line" ]; then
    bad "ACT 4: a reader can COMPLETE the reset over the bus, with the exact token the plan printed" \
        "nothing with --commit was recorded. This is the shape of the defect found on 2026-09-19: the loss list acknowledged itself one line before the phase allowed it, commitReady was false for ever, and the reset could not be completed by anybody. Recorded: $(tr '\n' ';' <"$APEX_ARGV")"
elif [ "$commit_line" = "apex recover reset --scope desktop --commit --confirm $FX_TOKEN" ]; then
    ok "ACT 4: a reader can COMPLETE the reset over the bus, with the exact token the plan printed"
else
    bad "ACT 4: a reader can COMPLETE the reset over the bus, with the exact token the plan printed" \
        "got: $commit_line — expected the confirm token $FX_TOKEN, derived from the paths that really exist"
fi

# And the reader is told what happened. Not by an announcement — see below —
# but the outcome must at least BE on the bus to be read at all.
sleep 3
python3 "$WALK" --dump >"$W/tree-done.txt" 2>/dev/null
if grep -qF '| name=Reset complete. |' "$W/tree-done.txt"; then
    ok "and the outcome apexd reported comes back on the bus, verbatim"
else
    bad "and the outcome apexd reported comes back on the bus, verbatim" \
        "no node named 'Reset complete.'; the stub's stdout is what RecoveryService puts in resetMessage"
fi

nope "the outcome is ANNOUNCED to a reader whose focus is on the button" \
     "a description or a label changing is not speech — a reader does not generally speak a change on an object it is not on. Accessible.announce() is the fix, it is Qt 6.8+, and it is not written yet; this is a could-not-run, not a pass"

echo
echo "  This suite does NOT claim the shell is accessible. The factory was put"
echo "  back by a test-only LD_PRELOAD; on a real machine a screen reader still"
echo "  gets one node. What it claims is that this page's markup is correct all"
echo "  the way to the bus and that its flows are completable through it."

totals
[ "$fail" -eq 0 ] || exit 1
exit 0
