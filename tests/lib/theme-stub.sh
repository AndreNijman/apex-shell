#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  theme-stub.sh — the size half of the Theme stub that the qmltestrunner
#  suites stage.
#
#  Three runners build a tiny tree out of src/components/config plus a
#  hand-written Theme singleton, so a control can be measured without standing
#  up the shell. Since P1-040 those components do not read sizes from Theme at
#  all: each declares its own token set for the output it is drawn on,
#
#      readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }
#
#  which needs two things the hand-written stub cannot provide by itself — the
#  `ThemeSet` TYPE, and `Theme.factorForHeight`. Without them the staged tree
#  fails to load with "ThemeSet is not a type", which is what happened the first
#  time the migration ran.
#
#  ── The stub is DERIVED, not written ────────────────────────────────────────
#  The token table is generated from src/theme/ThemeSet.qml itself, with the
#  SettingsService reads replaced by SettingsService's own declared defaults. A
#  hand-written copy would be a second token table, which is the defect this
#  whole roadmap item was opened for — and it would drift the first time anyone
#  added a token.
#
#  ── And it is checked for coverage ──────────────────────────────────────────
#  stage_theme_set also reads every `theme.<name>` the staged components
#  actually use and fails if the generated set does not define it. A stub that
#  goes short otherwise leaves a binding undefined, which is a silent zero in a
#  layout test rather than an error.
#
#  Usage:  stage_theme_set <stage_dir> <repo_root> [<staged component dir>...]
# ─────────────────────────────────────────────────────────────────────────────

stage_theme_set() {
    local stage="$1" root="$2"
    shift 2
    python3 - "$stage" "$root" "$@" <<'PY'
import os, re, sys

stage, root = sys.argv[1], sys.argv[2]
scan = sys.argv[3:] or [stage]

table = open(os.path.join(root, "src", "theme", "ThemeSet.qml")).read()
settings = open(os.path.join(root, "src", "services", "SettingsService.qml")).read()

defaults = {}
for m in re.finditer(r'^\s*(?:readonly\s+)?property\s+\w+\s+(\w+):\s*([^\n]+?)\s*$',
                     settings, re.M):
    defaults[m.group(1)] = m.group(2)
# effectiveAnim is reduceMotion ? 0 : animDuration; the stub is the un-reduced
# desk, which is what these suites measure.
defaults["effectiveAnim"] = defaults.get("animDuration", "320")

missing = []
def sub(m):
    name = m.group(1)
    v = defaults.get(name)
    if v is None or not re.fullmatch(r'[-\d.]+|true|false|"[^"]*"', v):
        missing.append(name)
        return m.group(0)
    return v

out = re.sub(r'\bSettingsService\.(\w+)', sub, table)
out = re.sub(r'^import "\.\./services"\n', '', out, flags=re.M)

if missing:
    sys.stderr.write("theme-stub: no literal default for SettingsService.%s — the "
                     "generated ThemeSet would not compile\n" % ", ".join(sorted(set(missing))))
    sys.exit(2)

open(os.path.join(stage, "ThemeSet.qml"), "w").write(out)

qmldir = os.path.join(stage, "qmldir")
have = open(qmldir).read() if os.path.exists(qmldir) else ""
if "ThemeSet ThemeSet.qml" not in have:
    open(qmldir, "a").write("ThemeSet ThemeSet.qml\n")

# Coverage: every token the staged components read must exist in the stub.
defined = set(re.findall(r'^\s*(?:readonly\s+)?property\s+\w+\s+(\w+)\s*:', out, re.M))
defined |= {"px", "fs", "scale"}
used = set()
for d in scan:
    for dp, dn, fn in os.walk(d):
        for f in fn:
            if f.endswith(".qml"):
                used |= set(re.findall(r'\btheme\.([A-Za-z_]\w*)',
                                       open(os.path.join(dp, f)).read()))
short = sorted(used - defined)
if short:
    sys.stderr.write("theme-stub: the staged components read theme.%s, which the "
                     "generated set does not define\n" % ", theme.".join(short))
    sys.exit(3)

print("theme-stub: %d tokens, covering %d read by the staged components"
      % (len(defined), len(used)))
PY
}
