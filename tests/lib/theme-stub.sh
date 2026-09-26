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

# ─────────────────────────────────────────────────────────────────────────────
#  stage_motion — the real motion system, for a qmltestrunner stage.
#
#  Since the UI/UX roadmap's Phase 1 the controls take their timing from the
#  Motion singleton and the MotionColor/MotionFade/MotionMove types, all in the
#  src module. A stage is a stand-in for src/, so they are copied into it at the
#  same relative paths — theme/Motion.qml, theme/motion.js, theme/anim/*.qml —
#  and registered in the stage's qmldir exactly as src/qmldir registers them.
#
#  The one change: Motion.qml's reads of SettingsService are replaced by the
#  shipped defaults (Balanced, 1x, Reduce Motion off), because SettingsService
#  imports Quickshell and qmltestrunner cannot load it. The defaults are READ
#  from SettingsService.qml rather than written here, so a changed default is a
#  changed stage.
#
#  Usage:  stage_motion <stage_dir> <repo_root>
# ─────────────────────────────────────────────────────────────────────────────
stage_motion() {
    local stage="$1" root="$2"
    mkdir -p "$stage/theme/anim"
    cp "$root/src/theme/motion.js" "$stage/theme/motion.js"
    cp "$root/src/theme/spring.js" "$stage/theme/spring.js"
    cp "$root"/src/theme/anim/*.qml "$stage/theme/anim/"
    python3 - "$stage" "$root" <<'PY'
import os, re, sys
stage, root = sys.argv[1], sys.argv[2]
settings = open(os.path.join(root, "src", "services", "SettingsService.qml")).read()
motion = open(os.path.join(root, "src", "theme", "Motion.qml")).read()
defaults = {}
for m in re.finditer(r'^\s*property\s+\w+\s+(\w+):\s*([^\n]+?)\s*$', settings, re.M):
    defaults[m.group(1)] = m.group(2)
missing = []
def sub(m):
    v = defaults.get(m.group(1))
    if v is None or not re.fullmatch(r'[-\d.]+|true|false|"[^"]*"', v):
        missing.append(m.group(1)); return m.group(0)
    return v
out = re.sub(r'\bSettingsService\.(\w+)', sub, motion)
out = re.sub(r'^import "\.\./services"\n', '', out, flags=re.M)
# The frame-pacing flag reads the shell's environment through Quickshell, which
# qmltestrunner does not have: staged, pacing is off, as it is by default.
out = re.sub(r'Quickshell\.env\("APEX_PACING_LOG"\) === "1"', 'false', out)
out = re.sub(r'^import Quickshell\n', '', out, flags=re.M)
if "Quickshell" in re.sub(r'//[^\n]*', '', out):
    sys.stderr.write("stage_motion: Motion.qml reads Quickshell in a way the stage cannot neutralise\n")
    sys.exit(2)
if missing:
    sys.stderr.write("stage_motion: no literal default for SettingsService.%s\n"
                     % ", ".join(sorted(set(missing))))
    sys.exit(2)
open(os.path.join(stage, "theme", "Motion.qml"), "w").write(out)
qmldir = os.path.join(stage, "qmldir")
have = open(qmldir).read() if os.path.exists(qmldir) else ""
add = ""
for line in ("singleton Motion theme/Motion.qml",
             "MotionColor 1.0 theme/anim/MotionColor.qml",
             "MotionFade 1.0 theme/anim/MotionFade.qml",
             "MotionMove 1.0 theme/anim/MotionMove.qml",
             "SpringFollower 1.0 theme/anim/SpringFollower.qml"):
    if line not in have:
        add += line + "\n"
open(qmldir, "a").write(add)
print("stage_motion: Motion staged at the shipped defaults")
PY
    [ -f "$stage/Theme.qml" ] && { stage_roles "$stage" "$root" || return 1; }
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  stage_roles — the surface and text roles, on a staged Theme stub.
#
#  Since the UI/UX roadmap's Phase 2 the shared controls draw with Theme's
#  roles (surfaceRaised, textSecondary, accentText, …), which the real Theme
#  mirrors from Colors.qml → src/theme/roles.js. A stage's Theme is a stub with
#  a fixed palette, so the REAL roles.js is copied in and the stub gains the
#  same role properties, resolved from its own background/active/text — the
#  stage runs the shipped arithmetic, not a second copy of it. Called by
#  stage_motion whenever the stage has a Theme.qml.
#
#  Usage:  stage_roles <stage_dir> <repo_root>
# ─────────────────────────────────────────────────────────────────────────────
stage_roles() {
    local stage="$1" root="$2"
    cp "$root/src/theme/roles.js" "$stage/roles.js"
    python3 - "$stage" "$root" <<'PY'
import os, re, sys
stage, root = sys.argv[1], sys.argv[2]
p = os.path.join(stage, "Theme.qml")
s = open(p).read()
if "_roleSet" in s:
    sys.exit(0)
# The role names are read from the real Colors.qml, so a role added there is a
# role the stage has.
colors = open(os.path.join(root, "src", "theme", "Colors.qml")).read()
names = re.findall(r'^\s*readonly property color (\w+):\s*_c\(_roleSet\.roles\.\w+\)', colors, re.M)
if not names:
    sys.stderr.write("stage_roles: no roles found in Colors.qml\n"); sys.exit(2)
theme = open(os.path.join(root, "src", "theme", "Theme.qml")).read()
fonts = re.findall(r'^\s*(readonly property string font\w+:\s*"[^"]*")', theme, re.M)
block = ["    // ── staged by tests/lib/theme-stub.sh stage_roles ──",
         "    readonly property var _roleSet: Roles.resolve({ background: background, active: active, text: text })",
         "    function _c(o) { return Qt.rgba(o.r, o.g, o.b, 1) }"]
for n in names:
    block.append("    readonly property color %s: _c(_roleSet.roles.%s)" % (n, n))
block.append("    function surfaceHover(c)   { return _c(Roles.hover(c, text)) }")
block.append("    function surfacePressed(c) { return _c(Roles.pressed(c, text)) }")
if "onAccent" not in names:
    block.append("    readonly property color onAccent: \"#1e1e2e\"")
block += ["    " + f for f in fonts]
i = s.rindex("}")
s = s[:i] + "\n".join(block) + "\n" + s[i:]
s = s.replace("import QtQuick\n", "import QtQuick\nimport \"roles.js\" as Roles\n", 1)
open(p, "w").write(s)
print("stage_roles: %d roles staged from roles.js" % len(names))
PY
}
