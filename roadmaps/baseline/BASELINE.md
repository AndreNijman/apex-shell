# Phase 0 baseline — APEX Shell before the UI/UX redesign

Measured 2026-09-25 against `origin/main` @ `17eec38` (tray-menu style merge),
before any redesign change. Everything here is a measurement or a reading of the
tree at that commit; where a number came from a tool, the tool is named so it can
be re-run after a change and compared.

## 1. How to reproduce

| What | Command |
|---|---|
| Frame bursts of every surface, cold (first open after login) and warm | `tests/visual/capture-surfaces.sh OUTDIR` |
| One labelled sheet per surface | `tests/visual/contact-sheet.py OUTDIR dashboard-warm OUT.png --crop 360,0,1200,600 --scale 0.3 --cols 6` |
| Renderer frame cost | `tests/visual/bench-renderer.sh` (Canvas vs Shape, CPU per frame) |

The capture runs the worktree's own `shell.qml` inside the private headless labwc
sandbox (`tests/lib/headless.sh`), GPU-rendered (`HEADLESS_WLR_RENDERER=gles2`),
at 1920x1080, with a dark palette (`#171210` / `#fab898`) and the shipped
wallpaper 0 behind it. It sets the legacy `animDuration` to **1200 ms** (the
slider's maximum), so every sheet is the shell at **3.75x slow motion**: a frame
stamped 374 ms is the shell at ~100 ms at its default speed.

The sheets from this run are in `sheets/`.

## 2. Motion inventory (whole tree, comment lines excluded)

| Metric | Count |
|---|---|
| Files containing motion code | 77 of 224 |
| `Behavior on …` blocks | 397 |
| `duration:` sites | 453 |
| — literal numbers (unreachable by Reduce Motion) | **403** (89 %) |
| — `Theme.animDuration` family (the only thing Reduce Motion zeroes) | 43 (9.5 %) |
| — `SettingsService.reduceMotion`-aware private literals (`Osd.qml`) | 3 |
| — other expressions (stagger `index*650`, countdowns, marquee length) | 4 |
| Animations with no `easing.type` (Qt default: **Linear**) | 346 (76 %) |
| `loops: Animation.Infinite` | 25 |
| `SpringAnimation` | 3 (all Kanban drag, with visible overshoot) |
| Overshooting curves in use | `OutBack` ×5, `OutElastic` ×1 |
| Press (pointer-down) feedback anywhere | **0** — every interactive animation is hover- or selection-driven |
| Timers whose interval is an animation duration | 16 |
| Distinct literal duration values | 31 — 120 ms ×83, 100 ms ×83, 80 ×36, 150 ×36, 200 ×34, 130 ×23, … |

`tests/check-reduce-motion.sh` pins this state as a ratchet: honour 41, literal
402, unresolved 9 (its own classification, which counts `Osd`'s ternaries as
unresolved).

### Easing in use (107 explicit)

OutCubic 44 · InOutCubic 27 · InOutSine 14 · Linear 6 · OutBack 5 · InOutQuad 5 ·
OutQuad 2 · OutExpo 1 · OutElastic 1 · InQuad 1 · InCubic 1.

Every large connected surface (Dashboard, Network, Notifications, Toast, Clipboard,
Wallpaper, ArchMenu, Audio, QuickControl, the bar's `cWidth`/`rWidth`/
`rightBottomRadius`/`implicitHeight`) uses **`InOutCubic` at the one global
320 ms** — the slow first third is what reads as input latency (§4).

### Lifecycle timers coupled to a guessed animation length

| File | Timer | Interval | Gates |
|---|---|---|---|
| `components/PopupSlide.qml` | `slideCloseTimer` | `slideDuration + 20` | unmap (ArchMenu, Audio, QuickControl) |
| `components/PopupSlide.qml` | `hoverCloseTimer` | `animDuration + 200` | hover-intent close (a debounce, not a tail) |
| `nexus/Nexus.qml` | `closeTimer` | `animDuration + 20` | unmap |
| `popups/AudioPopup.qml` | `audioResetTimer` | `animDuration + 20` | sub-page reset |
| `popups/ClipboardPopup.qml` | `closeTimer` | `animDuration + 20` | unmap |
| `popups/ContextMenu.qml` | `closeTimer` | `animDuration + 20` | unmap |
| `popups/NotificationToast.qml` | `slideOutTimer` | `animDuration + 20` | queue advance / unmap |
| `popups/NotificationsPopup.qml` | `closeTimer` | `animDuration + 20` | unmap |
| `popups/NetworkPopup.qml` | `closeTimer` | `animDuration + 20` | unmap |
| `popups/Dashboard.qml` | `closeTimer` | `animDuration + 20` | unmap + tab reset |
| `popups/Osd.qml` | `goneTimer` | `showAnim + 60` | unmap |
| `popups/WallpaperPopup.qml` | `closeTimer` / `hoverCloseTimer` / `centerLockTimer` | `+20` / `+200` / `animDuration` | unmap / hover close / list recentre |

No surface has an explicit Closed/Opening/Open/Closing state; reversal works only
because each `Behavior` retargets from its current value, and correctness of the
unmap depends on the timer outliving the slowest animation it guards.

### Width/height animated over live child layouts

Dashboard sizer (`width`/`height`, content anchored `fill` inside — relayout every
frame), Network sizer, Notifications sizer (height follows `notifList.height`),
Toast card, ArchMenu sizer, Audio sizer, Clipboard, Wallpaper, TopBar `cWidth`,
SysTray `Layout.preferredWidth`, several in-row reveals (Wi-Fi/Bluetooth forget and
password rows, Kanban draft, PlayerCard list).

### Loops that outlive their surface

The Wi-Fi/Bluetooth scan rings and VPN/Wi-Fi spinners are gated on a business
flag cleared only when the scan process exits, and the PlayerCard title marquee is
gated on `isPlaying` inside a latched `LazyPage` — all keep ticking in an unmapped
window. `CenterContent.qml:812` still has the 50 ms `Behavior on height` on the
recorder level bars that the comment beside the Cava bars says was removed as an
anti-pattern.

### Other defects found while inventorying

- `WindowSwitcher.qml` fades out via `opacity: root.visible ? 1 : 0` where `visible`
  IS the mapped state — the surface unmaps the frame the fade would start. The
  exit fade has never rendered.
- `TopBar.qml` animates `cWidth` and `rWidth` but not `lWidth`; the left notch snaps.
- `NotificationList` has no `add`/`remove`/`displaced` transitions: rows teleport.
  The only list-displacement transition in the tree is the clipboard history's.
- `LayoutDisplayer.qml:128` hangs a scale animation of a sibling off `Behavior on text`.

## 3. Renderer cost (measured)

`tests/visual/bench-renderer.sh` — one animated ~900x600 connected shape, 600
frames at 60 Hz in a 1280x720 window, CPU of the whole quickshell process tree
sampled from `/proc` outside the process (Radeon 780M, gles2, Qt 6.10.3,
Quickshell 0.3.1). A 2 ms busy-loop mutant reads +1.7 ms, so the tool measures what
it claims.

| Renderer | CPU/frame above an idle 0.77 ms |
|---|---|
| `Shape` + CurveRenderer | +0.18 ms |
| `Shape` + GeometryRenderer + 4x MSAA layer | +0.24 ms |
| `Canvas` + 8x MSAA layer (today's `PopupShape` / `SeamlessBarShape` / `Border`) | **+1.45 ms** |

GPU-side cost was not measured. Canvas also re-uploads its whole raster as a
texture on every repaint, so its cost grows with the surface's pixel area; the Shape
path does not.

## 4. Visual baseline (sheets/)

Read at 3.75x slow motion; times below are converted back to the default speed.

- **Dashboard, cold** (`dashboard-cold.png`) — the first open after login does not
  animate its height: the body is full height within one frame while the width is
  still the notch's, and the page content is laid out inside that ~300 px column
  (visibly squeezed and overlapping) until the width catches up at ~350 ms. The
  roadmap's CENTER_BLOOM asks for the opposite order (width first).
- **Dashboard, warm** (`dashboard-warm.png`) — nothing visible for the first
  ~60 ms (InOutCubic), then a rounded rectangle grows diagonally; content lays out
  at every intermediate width. Close: content fades by ~70 ms, then the empty body
  shrinks for another ~200 ms — the user watches an empty box leave.
- **Network** (`network-warm.png`) — same InOutCubic dead start; the right notch's
  status icons disappear while any right-side popup is open (`RightContent` fades
  itself out), so the bar loses its battery/clock/network readout exactly when the
  network panel is up. Pill and card join as one straight-edged rectangle.
- **Power** (`power-warm.png`) — slides in horizontally from off-screen with the
  concave melt into the left strip; the join is clean, the motion is a translation
  rather than an emergence.
- **Nexus** (`nexus-warm.png`) — 0.97 → 1 scale + fade at the same 320 ms as every
  popup; no difference in character from the connected surfaces.
- **Context menu** — scale 0.96 from the top-left corner at 160 ms both ways.

Not captured here (need hardware or a notification source): OSD repeat behaviour,
notification arrival/removal, the toast, lock/unlock, mixed refresh rates.
