# APEX Shell UI/UX redesign — implementation status

Working tracker for the coordinated implementation of
`APEX-Shell-Master-UIUX-Roadmap-v3.md` (engineering order, lifecycle, performance,
QA) and `APEX-Shell-Fluid-Visual-Design-Roadmap-v1.md` (what it looks and moves
like). It is not a third roadmap: it records where each phase is, what it touched,
how it was verified, and every place the implementation deliberately departs from
the text.

Branch: `feat/uiux-redesign` (from `origin/main` @ `17eec38`). Worktree:
`/var/tmp/apex-work/wt-uiux-shell`.

Statuses: NOT STARTED · IN PROGRESS · BLOCKED · IMPLEMENTED (built, tests pass) ·
VERIFIED (built, tests pass, visually reviewed at 1x and slow motion, scrutinised).

## Decisions that shape everything below

| # | Decision | Evidence / reason |
|---|---|---|
| D1 | Fluid geometry renders with `QtQuick.Shapes` + CurveRenderer from a path built each frame out of named parameters; no MSAA layer. | Measured: Shape +0.17 ms/frame vs Canvas +1.65 ms/frame (`tests/visual/bench-renderer.sh`, BASELINE §3). |
| D2 | The geometry itself is a plain-JS module (family, progress, params → path + bounds + content clip), unit-tested with node like `agentstate.js`. | Continuity, no self-intersection and monotone bounds become assertions a CI runner without a compositor can check. |
| D3 | Bar and popup stay separate layer surfaces. One lifecycle object per surface per screen owns `progress`; the bar's notch geometry is a pure function of that same value, the popup body another. No `Behavior` on either side. | Drawing the notch inside the popup window would hide `CenterContent`/`RightContent` or duplicate them; two independent Behaviors on one visual edge is the drift the roadmap complains about. |
| D4 | `SeamlessBarShape` (the bar) stays Canvas for this milestone and is migrated in its own change once the popup families are proven. | Roadmap §27.2 — do not replace every Canvas at once. |
| D5 | Motion is its own singleton (`Motion`, registered once in `src/qmldir`), not tokens inside `ThemeSet`. | `tests/lib/theme-stub.sh` regex-parses ThemeSet property declarations; motion is not a per-output quantity. |
| D6 | Roadmaps copied into `roadmaps/` in apex-shell. | `ROADMAP/` above the repos is not under version control. |

## Phase map

| Phase | Status | Files / components | Depends on | Tests / artifacts | Risks |
|---|---|---|---|---|---|
| 0 Baseline | IMPLEMENTED | `roadmaps/baseline/BASELINE.md`, `sheets/`, `tests/visual/{capture-surfaces.sh,contact-sheet.py,bench-renderer.*}`, `tests/lib/headless.sh` (`HEADLESS_WLR_RENDERER`) | — | capture + bench reproducible | OSD/notifications/lock/mixed-refresh not capturable headless without a source; recorded as gaps |
| 1 Motion architecture | NOT STARTED | `src/theme/Motion.qml`, `SettingsService` (speed/scale/migration), `tests/check-reduce-motion.sh` → motion lint | 0 | node/qml motion tests, lint self-test | 403 literals to migrate; lint counts churn in every later commit |
| 2 Visual tokens | NOT STARTED | `ThemeSet` (spacing/radius/control/type roles), `Colors`/`Theme` (surface roles) | 0 | `check-color-tokens.sh`, `check-scale-tokens.sh`, contrast test | theme-stub regex; 211-site translucent-white ratchet |
| 3 Interaction primitives | NOT STARTED | `src/components/controls/Apex*.qml` | 1, 2 | qmltestrunner press/keyboard tests | a11y adoption in `CfgRow` must keep working |
| 4 Parametric shape engine | NOT STARTED | `src/shapes/fluid/` | 1 | node geometry suite; prototype harness sheets | CurveRenderer AA on transparent layer surfaces |
| 5 Shape families | NOT STARTED | CENTER_BLOOM, RIGHT_POUR, LEFT_SPILL, CAPSULE, PIVOT_POP, QUIET_SHEET, LENS_REVEAL, STACK_REFLOW | 4 | harness: open/close/reverse at 25/50/75 %, scales 0.85/1/1.5 | "two necks" on RIGHT_POUR |
| 6 Surface lifecycle | NOT STARTED | `src/components/SurfaceLifecycle.qml`, every popup | 1 | lifecycle unit test, reversal harness | lazy-built popups miss their first open (LazyPopup.applyOpenState) |
| 7 Connected navigation | NOT STARTED | `TabSwitcher.qml`, `NavPane.qml` | 1, 3 | `run-nav-geometry-test.sh`, `check-wheel-value.sh` | exact wheel-site counts |
| 8 Dashboard v2 | NOT STARTED | `Dashboard.qml`, `TopBar.qml`, home/stats pages | 4–7 | captures, a11y | cold-open defect (BASELINE §4) |
| 9 Right quick surfaces | NOT STARTED | `NetworkPopup`, `NotificationsPopup` container, toast, `AudioPopup`, `QuickControl` | 4–7 | captures | multi-monitor: network popup has no `screen:` |
| 10 Left surfaces | NOT STARTED | `ArchMenu`, `PowerMenu` | 4–6 | captures | labwc: PopupDismiss unmapped for ArchMenu |
| 11 Notifications stack | NOT STARTED | `NotificationList`, toast | 1, 6 | stack harness | no notification source headless (use notify-send stub path) |
| 12 Launcher | NOT STARTED | `AppLauncher.qml` | 1–3 | first-keypress test | **held**: another agent is editing `AppLauncher.qml` (fix/launcher-hover-select) |
| 13 Nexus | NOT STARTED | `Nexus.qml`, `NavPane.qml`, config controls | 2, 3, 7 | nexus smoke, a11y suites | a11y tree assertions |
| 14 OSD / toasts / context menus | NOT STARTED | `Osd.qml`, `ContextMenu.qml`, `TrayMenu.qml` | 1, 6 | captures | — |
| 15 Top bar redesign | NOT STARTED | `TopBar.qml`, `SeamlessBarShape`, modules | 2, 5 | ci.yml literal greps on TopBar | CI greps literal TopBar lines |
| 16 Component visual refresh | NOT STARTED | shared components | 2, 3 | — | — |
| 17 Page-level redesign | NOT STARTED | Dashboard pages, Network tabs, Nexus pages | 16 | — | — |
| 18 Color/material v2 | NOT STARTED | `Colors`, `ColorLoader` | 2 | contrast suite | fixed status colours must stay fixed |
| 19 IA cleanup | NOT STARTED | Dashboard Config tab vs Nexus | 13 | — | — |
| 20 Hyprland motion | NOT STARTED | compositor config (apex-os) | 1 | — | lives in apex-os; layer rules must not double-animate |
| 21 Accessibility | NOT STARTED | all | 3 | a11y suites | — |
| 22 Frame pacing | NOT STARTED | — | 8–14 | bench, `QSG_RENDER_TIMING` | GPU-side unmeasured |
| 23 Shape QA | NOT STARTED | — | 5 | harness | — |
| 24 Stress matrix | NOT STARTED | — | all | — | mixed refresh needs hardware |

## Deviations from the roadmaps

| Where | Roadmap says | Implemented | Why |
|---|---|---|---|
| Phase 0 | "Record videos … frame timing at 60 Hz and one high-refresh target" | Timestamped frame bursts at 3.75x slow motion + CPU/frame bench; no high-refresh capture | Headless outputs are 60 Hz; no high-refresh hardware reachable without opening windows on the user's desk. |

## Verification log

- 2026-09-25 — Phase 0: baseline captured from `17eec38`; renderer bench (idle 0.63, shape 0.80, geometry 0.93, canvas 2.28, busy-control 2.37 ms/frame).
