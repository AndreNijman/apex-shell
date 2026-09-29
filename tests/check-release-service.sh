#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-release-service.sh — after an update the Shell opens that release's
#  rimeos.com page once, and only once it exists (src/services/ReleaseService.qml).
#
#  Andre, 2026-09-29: "every update from now on after updating opens a page in
#  your default browser on the website that has the update and what this update
#  has". rimeos.com master spec §7. The decisions are release.js (node
#  tests/release-test.js); the service end to end is run-release-service-test.
#  These are the properties a later edit would break without either noticing:
#
#   ONCE      it is started once, from shell.qml's start-up scope, never inside
#             the per-screen Variants (one per monitor = one tab per monitor)
#   PROBE     the browser is only ever launched from the probe's 200 branch: a
#             page that does not answer yet stays pending instead of opening a
#             404 (the site publishes on its own schedule)
#   DETACHED  the opener is detached (setsid -f), so the browser does not die
#             with a shell restart, and it is the user's default browser
#   SETTLED   it decides only after SettingsService has read settings.json:
#             before that, a user who turned it off reads as on (measured)
#   SETTING   "Open what's new after an update" is a saved setting, default on,
#             with its switch on the Misc page's Updates section
#   ROLLBACK  booting an older release shows a notice and never probes/opens
#   PRIVATE   the only network use is the probe of the public page: no data is
#             sent (no POST, no upload flags) — spec §7.5 "No state is uploaded"
#
#  Each rule is mutated on a copy to prove it can fail.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

check_tree() {   # check_tree <root> — "RULE PASS|FAIL detail" per rule
    python3 - "$1" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
def code(p):
    return "\n".join(l.split("//", 1)[0] for l in (root / p).read_text().split("\n"))
def verdict(rule, good, detail=""):
    print(rule, "PASS" if good else "FAIL", detail)

sh = code("shell.qml")
ref = re.search(r'property var _release\s*:\s*ReleaseService', sh)
var = sh.find("Variants {")
verdict("ONCE", bool(ref) and var > 0 and ref.start() < var and sh.count("ReleaseService") == 1,
        "referenced %d time(s), before the Variants: %s" % (sh.count("ReleaseService"), bool(ref) and ref.start() < var))

rs = code("src/services/ReleaseService.qml")
probe = re.search(r'property Process _probeProc\s*:\s*Process\s*\{(.*?)\n    \}', rs, re.S)
p = probe.group(1) if probe else ""
starts = len(re.findall(r'_openProc\.running\s*=\s*true', rs))
verdict("PROBE", bool(probe) and re.search(r'code === "200"\)\s*\{[^}]*_openProc\.running\s*=\s*true', p, re.S) is not None
        and starts == 1 and re.search(r'"curl"', rs) is not None,
        "_openProc started %d time(s)" % starts)

verdict("DETACHED", 'setsid -f' in rs and '/usr/libexec/rime-open-browser' in rs, "opener launch")

ck = re.search(r'function check\(\)\s*\{(.*?)\n    \}', rs, re.S)
verdict("SETTLED", bool(ck) and re.search(r'if\s*\(\s*!SettingsService\._loaded\s*\)', ck.group(1)) is not None
        and "on_LoadedChanged" in rs, "check() waits for the settings file")

st = code("src/services/SettingsService.qml")
misc = code("src/services/config_tab/pages/MiscPage.qml")
verdict("SETTING", re.search(r'property bool\s+openReleaseNotes\s*:\s*true', st) is not None
        and re.search(r'openReleaseNotes\s*:\s*true', re.search(r'_defaults\s*:\s*\(\{(.*?)\}\)', st, re.S).group(1)) is not None
        and '"openReleaseNotes"' in re.search(r'_keys\s*:\s*\[(.*?)\]', st, re.S).group(1)
        and re.search(r'checked\s*:\s*SettingsService\.openReleaseNotes', misc) is not None,
        "setting + switch")

dec = re.search(r'function _decide\(\)\s*\{(.*?)\n    \}', rs, re.S)
d = dec.group(1) if dec else ""
rb = re.search(r'if \(d\.action === "rollback"\)\s*\{(.*?)\}', d, re.S)
verdict("ROLLBACK", bool(rb) and "_probe" not in rb.group(1) and "_openProc" not in rb.group(1)
        and "_notify(" in rb.group(1), "rollback branch")

net = re.findall(r'"(curl|wget|http[^"]*)"', rs)
verdict("PRIVATE", "curl" in net and "wget" not in net
        and not re.search(r'"(-d|--data[^"]*|-F|--form|-T|--upload-file|-X)"', rs), "network use: %s" % sorted(set(net)))
PY
}

label() {
    case "$1" in
        ONCE)     echo "started once, outside the per-screen Variants" ;;
        PROBE)    echo "the browser is launched only after the page answers 200" ;;
        DETACHED) echo "the default browser, detached from the shell" ;;
        SETTLED)  echo "it decides only once the settings file has been read" ;;
        SETTING)  echo "\"Open what's new after an update\" is a saved setting, default on, with its switch" ;;
        ROLLBACK) echo "a rollback gets a notice, never the page" ;;
        PRIVATE)  echo "the only network use is the probe; nothing is sent" ;;
    esac
}

echo "── the release service ──"
verdicts="$(check_tree .)"
while read -r rule verdict detail; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$(label "$rule")"; else bad "$(label "$rule") — $detail"; fi
done <<<"$verdicts"
[ "$(grep -c . <<<"$verdicts")" -eq 7 ] && ok "all seven rules were evaluated" || bad "expected seven verdicts, got: $verdicts"

echo "── self-test: can these checks fail? ──"
MW="$(mktemp -d)"; trap 'rm -rf "$MW"' EXIT INT TERM
mutant() {   # mutant <label> <file> <old> <new> <rule that must FAIL>
    rm -rf "$MW/t"; mkdir -p "$MW/t"; cp -r src "$MW/t/src"; cp shell.qml "$MW/t/"
    if ! python3 - "$MW/t/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s: sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
PY
    then bad "self-test $1: the mutation did not apply"; return; fi
    if check_tree "$MW/t" | grep -q "^$5 FAIL"; then ok "self-test $1: caught"
    else bad "self-test $1: SURVIVED"; fi
}
mutant "a second reference inside the per-screen Variants" shell.qml \
    'Variants {' $'Variants {\n                property var _again: ReleaseService' ONCE
mutant "opening without the probe" src/services/ReleaseService.qml \
    $'            if (d.state) root._save(d.state)      // pending until it has opened\n            root._probe(d.url)' \
    $'            if (d.state) root._save(d.state)\n            root._openProc.running = true' PROBE
mutant "a launch the shell owns" src/services/ReleaseService.qml \
    'setsid -f \"$h\" \"$2\"' '\"$h\" \"$2\"' DETACHED
mutant "deciding before the settings are read" src/services/ReleaseService.qml \
    'if (!SettingsService._loaded) { root._wantCheck = true; return }' '' SETTLED
mutant "the setting off by default" src/services/SettingsService.qml \
    'property bool   openReleaseNotes:   true' 'property bool   openReleaseNotes:   false' SETTING
mutant "a rollback that opens the page" src/services/ReleaseService.qml \
    $'        if (d.action === "rollback") {\n' $'        if (d.action === "rollback") {\n            root._probe(d.url)\n' ROLLBACK
mutant "a probe that posts" src/services/ReleaseService.qml \
    '"--max-time", "10", canonical]' '"--max-time", "10", "--data", "x", canonical]' PRIVATE

echo
echo "check-release-service: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
