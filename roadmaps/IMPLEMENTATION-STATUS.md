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
| D3 | Bar and popup stay separate layer surfaces. One lifecycle object per surface per screen owns `progress`. **Revised in Phase 9:** no moving edge is shared between two windows — the surface draws every part of the notch that moves (band, shoulder, a cover over the bar's own corner) and the bar draws only what never moves. At progress 0 the surface's shape over the notch is the bar's own, so map/unmap is invisible. | Measured: with the bar widening in step from the same integer function, the two layer surfaces presented their frames independently and the notch sat one frame off the body (35-42 px ledges on close/cold open). With the band in the popup window, every frame of every sequence measured seam-exact. The Dashboard already covered its notch the same way. |
| D4 | `SeamlessBarShape` moved off Canvas in Phase 9 (earlier than planned) onto `geometry.js barSilhouette` + CurveRenderer, same corners and rounding. | Measured: the Canvas (8x MSAA layer) repainted a frame or more behind its inputs — up to 77 px of notch lag mid-pour — at 2.28 vs 0.80 ms/frame. Only one Canvas changed, per §27.2's intent. |
| D5 | Motion is its own singleton (`Motion`, registered once in `src/qmldir`), not tokens inside `ThemeSet`. | `tests/lib/theme-stub.sh` regex-parses ThemeSet property declarations; motion is not a per-output quantity. |
| D6 | Roadmaps copied into `roadmaps/` in apex-shell. | `ROADMAP/` above the repos is not under version control. |

## Phase map

| Phase | Status | Files / components | Depends on | Tests / artifacts | Risks |
|---|---|---|---|---|---|
| 0 Baseline | IMPLEMENTED | `roadmaps/baseline/BASELINE.md`, `sheets/`, `tests/visual/{capture-surfaces.sh,contact-sheet.py,bench-renderer.*}`, `tests/lib/headless.sh` (`HEADLESS_WLR_RENDERER`) | — | capture + bench reproducible | OSD/notifications/lock/mixed-refresh not capturable headless without a source; recorded as gaps |
| 1 Motion architecture | IMPLEMENTED | `src/theme/{Motion.qml,motion.js,anim/Motion{Color,Fade,Move}.qml}`, `SettingsService` (motionSpeed/motionScale, animDuration migrated by ratio), `LayoutPage`, `tests/check-reduce-motion.sh` (the motion lint), `tests/motion-test.js` | 0 | motion-test 107/0; lint 22/0 incl. self-tests; 403 literals → 8 (AppLauncher) + 2 allowlisted countdowns; 0 ungated loops | legacy `Theme.animDuration` (40 sites) and named easings (35) remain in the surfaces not yet on SurfaceLifecycle — ratchets |
| 2 Visual tokens | IN PROGRESS | `ThemeSet`: radius roles XS–Full, `notchShoulder`/`notchBottom`, spacing scale | 0 | check-scale-tokens 49/0 | control heights, typography roles, surface roles (Colors) still to add — brief §C.3–C.5 |
| 3 Interaction primitives | NOT STARTED | `src/components/controls/Apex*.qml` | 1, 2 | qmltestrunner press/keyboard tests | a11y adoption in `CfgRow` must keep working |
| 4 Parametric shape engine | IMPLEMENTED | `src/shapes/fluid/{geometry.js,FluidShape.qml}`, `tests/fluid-geometry-test.js`, `tests/visual/fluid-harness.{sh,qml}` | 1 | geometry suite 129/0; harness sheets reviewed, joins zoomed | GPU cost of CurveRenderer unmeasured |
| 5 Shape families | IN PROGRESS | CENTER_BLOOM, RIGHT_POUR (+ `rightPourWidth`; now draws the notch band, shoulder and corner cover), LEFT_SPILL, EDGE_SPILL (right); `barNotch`, `barSilhouette` | 4 | geometry suite 147/0: per-family sweeps, character checks, pour-at-0 equals the bar notch pixel for pixel, corner cover, cover clear of the icons (mutants caught) | CAPSULE, PIVOT_POP, QUIET_SHEET, LENS_REVEAL, STACK_REFLOW are motion-only families, built with their surfaces |
| 6 Surface lifecycle | IN PROGRESS | `SurfaceLifecycle.qml` (linear progress on open, fastDecel on close, content delay 40/in 130/out 70); under Reduce Motion a close holds the finished shape while it fades (brief B.10); a close+reopen in one tick is a no-op. Dashboard and the right panel migrated | 1 | lifecycle suite 15/0 | remaining popups migrate with their redesign; the CI applyOpenState step now asserts the right panel's clock waits for the panel |
| 7 Connected navigation | IN PROGRESS | `TabSwitcher.qml`: one pill per switcher travels to the chosen tab (selection token, emphasizedDecel; armed after first placement); tabs draw hover only. `LazyPage.qml`: directional enter/exit (pageTravel, page token), interruption-safe. Dashboard derives direction from tab order via `shownPage` | 1, 3 | nav-geometry 4398/16 (pre-existing), wheel 16/0, settings-controls 16/0, a11y 26/0, rtl 37/0, popup smoke clean; `capture-surfaces.sh … tabs` sheets fwd/back | Nexus `NavPane` still pending (Phase 13) |
| 8 Dashboard v2 | IMPLEMENTED (motion) | `Dashboard.qml` on CENTER_BLOOM + SurfaceLifecycle, content at final layout under the bloom clip; `TopBar.cWidth` no longer widens for it; `SeamlessBarShape` on the notch tokens, whole-pixel positions | 4–7 | captures cold/warm at 2.5x (`tests/visual/capture-surfaces.sh`), shoulder zoom; popup/nexus smoke, scaling 88/0 | page redesign is Phase 17 |
| 9 Right quick surfaces | IMPLEMENTED | 9a: `RightPanel.qml` — Network, the notification centre, audio and the toast as panes of ONE RIGHT_POUR surface per screen (`NetworkPane`, `NotificationsPane`, `AudioControl`, `NotificationToast` as Items); clock `TopBar.rightLife`, starting only once the panel is built; the bar's notch never moves (the panel draws the band); pane switch keeps the body open and retargets W/D over `page`, panes cross-fade; `OpenPill` on the owning glyph (wifi/bt/vpn/hotspot, speaker, bell), no ▾; network tabs arrive directionally. 9b: Audio moved from the right strip to a pane under its own notch trigger (`AudioPopup` removed); `QuickControl` on EDGE_SPILL as a PanelWindow spanning the right strip, built by the strip hover (it was unreachable, see below), a `quick-toggle` IPC for keyboards | 4–7 | captures cold/warm/switch/toast (private bus)/Reduce Motion/audio/quick, per-frame seam measurement; service-tier 88/0, scaling 90/0, labwc matrix 57/0 (was not running its per-output half), popup smoke incl. quick-toggle, lint ratchets lowered (legacy 30, easing 25, unresolved 2) | Network depth fixed at 648 (content-sized is Phase 17); audio pages still switch instantly (width retargets, pill travels); right panel opens on every screen, as the centre always did |
| 10 Left surfaces | NOT STARTED | `ArchMenu`, `PowerMenu` | 4–6 | captures | labwc: PopupDismiss unmapped for ArchMenu |
| 11 Notifications stack | NOT STARTED | `NotificationList`, toast | 1, 6 | stack harness | no notification source headless (use notify-send stub path) |
| 12 Launcher | NOT STARTED | `AppLauncher.qml` | 1–3 | first-keypress test | the launcher agent's fix landed (PR #25, 99c5ab7) and main is merged here (6ce1653); the 8 unlisted literals are its ratchet |
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

## Also shipped on this branch

| Change | Where | Verification |
|---|---|---|
| Password shapes on the lock screen (and the login screen, apex-os `feat/password-shapes`) — one geometric shape per character, chosen by position only, fed the field's length only | `src/components/auth/PasswordShapes.qml`, `Lockscreen.qml`; apex-os `GreetSurface`/`GreetContext`/`apex-greet-wallpaper` | `check-password-shapes.sh` 13/0 (mutants), `run-password-shapes-test.sh` 12/0, `check-lockscreen-a11y.sh` 33/0, apex-os `test-apex-greet-motion.sh` 25/0; captured on the real lock and login screens; visual advisor review folded in |
| Lock screen: a refused password now clears the field (it left the rejected attempt in place) | `Lockscreen.qml` `fail()` | `check-password-shapes.sh` CLEAR rule + mutant |
| Greeter: a refused login's error survives the field being cleared | apex-os `GreetSurface.qml` | `test-apex-greet-motion.sh` §4 + mutant |

## Deviations from the roadmaps

| Where | Roadmap says | Implemented | Why |
|---|---|---|---|
| Right notch while a panel is open | brief A.2: the bar widens its notch, `rWidth = W(p)` | the bar's notch stays at its natural width; the panel draws the widened band over it | a moving edge split across two layer surfaces is a frame off itself (measured, D3) |
| Toast while a panel is open | — | not shown; a toast on screen is dismissed when Network or the centre opens; opening the centre drops the queue; a toast arriving while the centre is open is not queued | the body belongs to the open panel; the centre already lists every one of them |
| Toast state | a global `Popups.notificationToastOpen` read by every bar | each screen's panel pushes its own toast state to its own bar | one screen's dismiss used to close every bar's notch |
| Audio popup | RIGHT_POUR | Moves to hang under the right notch as a RIGHT_POUR (its trigger lives in the notch); QuickControl, which is edge-triggered, becomes EDGE_SPILL | The design brief found a pour has no source at mid-edge; the user's instructions and both roadmaps name Audio as RIGHT_POUR. Moving it under its own trigger satisfies both. |
| Dashboard height | — | The finished body's bottom is `notchHeight + dashboardHeight` (was `dashboardHeight` from the screen top) | Pages gain the 40 px the bar used to take, which fixes Home clipping its last tile row (brief §F.1); the setting now means "height below the bar". |
| notchRadius default | brief: 15 → 12 | kept at 15; the bottom corner is now a derived token (14) | A default change is a product call for Andre. |
| Right panel title in the bar's notch | brief §D.5 (optional) | not done; the band's left stays empty | Product call; the brief's own fallback. |
| Phase 0 | "Record videos … frame timing at 60 Hz and one high-refresh target" | Timestamped frame bursts at 3.75x slow motion + CPU/frame bench; no high-refresh capture | Headless outputs are 60 Hz; no high-refresh hardware reachable without opening windows on the user's desk. |

## Resume notes (kept current)

- Committed through Phase 9b. Next: 10 (ArchMenu on LEFT_SPILL + its hover-build
  defect), then 11, 12.
- The toast capture needs a notification and must never send one to the desk:
  `env -u WAYLAND_DISPLAY -u DISPLAY dbus-run-session -- env APEX_CAPTURE_BUS=private
  tests/visual/capture-surfaces.sh OUT toast` (gdbus Notify — this host's
  notify-send does not deliver to the private bus).
- Before each phase commit: EVERY `tests/check-*.sh` (Phase 7 broke two that a
  narrower list missed: agent-center's lazy-page grep and the white-foreground
  ratchet), `tests/check-reduce-motion.sh`,
  `check-wheel-value.sh`, `node tests/{motion,fluid-geometry}-test.js`, the
  qmltestrunner suites (settings-controls, a11y-controls, rtl, lifecycle,
  password-shapes), `run-nav-geometry-test.sh` (16 pre-existing),
  `run-popup-smoke.sh`, `run-nexus-smoke.sh`, then a capture sheet of the surface.
- Staged quickshell harnesses import `./src/services` before `./src`.
- Fable design brief: session scratchpad `fable-brief-1.md` (shape families, tokens,
  top bar, controls).

## Failures that are NOT this branch's (measured on untouched main)

- QuickControl could not be opened at all since the lazy-popup change
  (`cea90b5`, #2): built only by `Popups.quickOpen`, which nothing sets. FIXED in
  9b. ArchMenu's and the wallpaper picker's strip hovers have the same shape
  (they work only after the first click has built the window) — for Phase 10.
- `tests/labwc-matrix-test.qml` built `PopupDismiss` without its required
  `topBar` (since `6b39094`), so the per-output half built no instances and
  failed; CI skips the suite (no labwc there), which is why nobody saw it.
  FIXED in 9b.
- `tests/run-nav-geometry-test.sh`: 16 — the Privacy page lays out no rows at some scales (identical on `17eec38`).
- `tests/run-lockscreen-atspi.sh`: 1 pinned assertion — this machine's Qt now publishes 8 AT-SPI nodes; the pin itself says that is an improvement.
- apex-os `tests/test-apex-greet-sessions.sh`: 2 — a new `apex-safe-graphics` session the suite does not expect.
- `tests/check-colour-page.sh`: flaky, ~1 run in 3, on main as well.

## Verification log

- 2026-09-26 — Phase 9b: audio pane and EDGE_SPILL quick controls captured; full `check-*.sh` sweep, node suites, headless suites green (nav-geometry 16 pre-existing); RTL window-root pin 15 → 16 (QuickControl is a PanelWindow).
- 2026-09-26 — Phase 9a: one right panel; seam measured per frame on cold/warm open and close and both pane switches — exact after moving the band into the panel (was 35-77 px off with a Canvas bar, then one-frame ledges with a Shape bar); toast captured on a private bus; Reduce Motion close fades the finished shape. All `check-*.sh` green, node suites green, headless suites green except nav-geometry's 16 pre-existing. Fixed two Phase 7 regressions found by the full sweep.
- 2026-09-26 — Phase 7: shared tab pill + directional pages on the Dashboard; forward/back tab sheets reviewed (pill lands ~290 ms, no pop); suites as in the phase row.
- 2026-09-26 — Phase 8a: Dashboard on CENTER_BLOOM; cold open no longer squeezes the page; lint 22/0 (legacy 40, easing 35, unresolved 4); popup smoke, nexus smoke, scaling 88/0; nav-geometry 16 (pre-existing).
- 2026-09-25 — password shapes (both screens), tokens, four shape families (geometry 129/0), Phase 1 motion + migration, lifecycle.
- 2026-09-25 — Phase 0: baseline captured from `17eec38`; renderer bench (idle 0.63, shape 0.80, geometry 0.93, canvas 2.28, busy-control 2.37 ms/frame).
