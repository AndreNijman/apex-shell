<h1 align=center>APEX Shell</h1>

<h3 align="center">
The standard desktop shell of APEX-OS — a dynamic, highly modular Wayland shell built with Quickshell and QML for Hyprland and niri.
</h3>

<p align="center">
  <img src="https://img.shields.io/github/last-commit/AndreNijman/apex-shell?style=for-the-badge&color=8D748C&logoColor=D9E0EE&labelColor=252733" alt="Last Commit" />
  <img src="https://img.shields.io/github/stars/AndreNijman/apex-shell?style=for-the-badge&logo=starship&color=AB6C6A&logoColor=D9E0EE&labelColor=252733" alt="Stars" />
  <img src="https://img.shields.io/badge/version-0.1.0-8D748C?style=for-the-badge&logoColor=D9E0EE&labelColor=252733" alt="Version 0.1.0" />
  <br>
  <img src="https://img.shields.io/badge/hyprland-v0.55+-5E81AC?style=for-the-badge&logoColor=D9E0EE&labelColor=252733" alt="Hyprland v0.55+" />
  <img src="https://img.shields.io/badge/compositor-niri-5E81AC?style=for-the-badge&logoColor=D9E0EE&labelColor=252733" alt="niri" />
  <img src="https://img.shields.io/badge/framework-quickshell-A1C999?style=for-the-badge&logoColor=D9E0EE&labelColor=252733" alt="Quickshell Framework" />
  <br>
  <a href="https://github.com/AndreNijman/apex-shell/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/AndreNijman/apex-shell?style=for-the-badge&color=A1C999&logo=opensourceinitiative&logoColor=D9E0EE&labelColor=252733" alt="License" />
  </a>
  <a href="https://github.com/AndreNijman/apex-shell/issues">
    <img src="https://img.shields.io/github/issues/AndreNijman/apex-shell?style=for-the-badge&logo=github&color=5E81AC&logoColor=D9E0EE&labelColor=252733" alt="Issues" />
  </a>
</p>

---

<h2 align="center">Features</h2>

- **Modular Setup** — Unintrusive setup
- **Material You Integration** — Dynamic colors via Matugen
- **Lua-Based Config** — Hyprland v0.55+ compatible
- **Multi-Compositor** — Hyprland, niri and labwc, auto-detected, with Hyprland-only features degrading gracefully
- **System Dashboard** — Monitor CPU, RAM, battery, temps, and more
- **Kanban/Tasks** — To Do, Ongoing and Completed lists with Priority and Deadlines
- **App Launcher** — App search, plus inline answers for queries typed with a leading `?`
- **Keybinds** — Set your own keybinds for each popup
- **Recovery** — Config → Recovery reads `apex recover status` and `apex doctor`
  and shows what is wrong, how to roll back, and what a factory reset would
  actually delete (APEX-OS only; read-only until you press something)
- **Theming Engine** — Live wallpaper-synced color updates
- **Network Manager** — WiFi (incl. WPA2-Enterprise/802.1X), Bluetooth, VPN integration
- **Notifications** — DBus Notifications via libnotify
- **Audio Control** — PipeWire volume & device management
- **Screen Recorder** — Built-in recording with wf-recorder
- **Clipboard Manager** — Cliphist integration for history management
- **Highly Customizable** — QML-based UI, easily extended

> **Note:** APEX Shell is currently in its `v0.1.0` release. While the core architecture and theming pipeline are feature-complete, you may encounter bugs. Please report them via GitHub Issues.

---

<h2>
  Installation
</h2>

### One line installer

```bash
curl -fsSL https://raw.githubusercontent.com/AndreNijman/apex-shell/refs/heads/main/install.sh | bash
```

### Manual installation

```bash
git clone https://github.com/AndreNijman/apex-shell.git
cd apex-shell
chmod +x install.sh
./install.sh
```

The installer automatically:

- ✓ Detects your Linux distribution
- ✓ Detects your Window Manager and Hyprland Config
- ✓ Backs up your entire `~/.config`
- ✓ Installs all required dependencies
- ✓ Clones the repository to `~/.local/src/apex-shell`
- ✓ Updates your Hyprland config to auto-start APEX Shell and required dependencies
- ✓ Renders a portable matugen config (no hardcoded paths) into `~/.config/apex-shell/matugen.toml`
- ✓ Creates configuration directories
- ✓ Installs a tightly scoped polkit rule for passwordless sing-box VPN toggling (only when sing-box is present)

**After installation, restart Hyprland for changes to take effect.**

---

<h2>
  VPN (sing-box) control plane
</h2>

The VPN tab controls the [sing-box](https://sing-box.sagernet.org/) VLESS/Reality
tunnel through **systemd**: `systemctl start|stop sing-box.service` to
connect/disconnect and `systemctl is-active sing-box.service` to read status.

To keep the toggle password-free without granting broad `sudo`, APEX Shell ships
a tightly scoped **polkit** rule at
[`dots-extra/polkit/49-apex-shell-singbox.rules`](dots-extra/polkit/49-apex-shell-singbox.rules).
It authorizes `start` / `stop` / `restart` of **only** `sing-box.service`
(`org.freedesktop.systemd1.manage-units`) for an active local session — nothing
else. Reading status needs no rule (it is an unprivileged query).

The Arch installer drops it into `/etc/polkit-1/rules.d/` automatically when
sing-box is detected. To install it by hand on any systemd host:

```bash
sudo install -Dm644 dots-extra/polkit/49-apex-shell-singbox.rules \
     /etc/polkit-1/rules.d/49-apex-shell-singbox.rules
```

polkitd hot-reloads `rules.d/`, so it takes effect immediately — no restart. On
image-based systems (e.g. APEX-OS) ship it read-only under
`/usr/share/polkit-1/rules.d/` instead. APEX Shell assumes `sing-box.service` is
installed **disabled** (it never autostarts) with its config at
`/etc/sing-box/config.json`.

---

<h2>
  Requirements
</h2>

> [!IMPORTANT]
> **Matugen is required** for dynamic color generation. APEX Shell will not function correctly without it.

### Core Dependencies

<details open>
<summary><b>Runtime & Rendering</b></summary>

- **Hyprland** v0.55+ – Wayland compositor (niri and labwc also supported)
- **Quickshell** – QML shell framework
- **Qt6** – Qt6 libraries and QML engine
- **qt6ct** – Qt6 theme configuration

</details>

<details open>
<summary><b>System Tools</b></summary>

- **PipeWire** – Audio server (pipewire, pipewire-pulse, wireplumber)
- **NetworkManager** – Network management
- **BlueZ** – Bluetooth stack (bluez, bluez-utils)
- **Brightnessctl** – Backlight control
- **Mpris** – Media Retrieval
- **Playerctl** – Player controls
- **UPower** – Battery and power info
- **libnotify** – Desktop notifications
- **Polkit** – Privilege escalation
- **wl-clipboard** – Wayland clipboard (wl-copy/wl-paste)

</details>

<details open>
<summary><b>Theming & Wallpaper</b></summary>

- **Matugen** – Material You color generation **(REQUIRED)**
- **awww** – Wallpaper daemon (Wayland)
- **ImageMagick** – Image manipulation

</details>

<details open>
<summary><b>Recording & Utilities</b></summary>

- **wf-recorder** – Screen recording (Wayland)
- **cava** – Audio visualizer
- **slurp** – Region/window selection
- **wtype** – Keyboard input emulation
- **cliphist** – Clipboard history manager

</details>

<details open>
<summary><b>Hardware Management</b></summary>

- **lm_sensors** – CPU temperature & fan monitoring
- **rfkill** – Airplane mode control
- **envycontrol** – GPU switching (NVIDIA/Intel)
- **auto-cpufreq** – CPU frequency scaling
- **nbfc-linux** – Laptop fan control

</details>

<details open>
<summary><b>Hyprland Integration</b></summary>

- **hyprlock** – Lock screen
- **hypridle** – Idle management daemon
- **hyprsunset** – Blue light filter
- **hyprshutdown** – Graceful shutdown
- **xdg-desktop-portal-hyprland** – Portal backend

</details>

<details open>
<summary><b>Fonts</b></summary>

- **ttf-jetbrains-mono-nerd** – Primary font (Nerd Font variant)
- **ttf-noto-nerd** – Emoji and CJK support

</details>

---

<h2>
  Roadmap
</h2>

### Current (v0.1.0)

- [x] Core shell framework
- [x] System monitoring dashboard
- [x] Keybind editor with live conflict detection
- [x] Network management (WiFi, Bluetooth, VPN)
- [x] Audio control panel
- [x] Screen recording integration
- [x] Clipboard manager
- [x] Material You color integration
- [x] Lua config generation
- [x] niri compatibility layer
- [x] Professional installer (Arch)
- [x] Auto-update mechanism

### Upcoming (Post-v0.1.0)

- [ ] Scaling on Different Screen-Sizes
- [x] Config Pages for Shell Customization — Appearance / Layout / Data / Input /
      Display / Blueprint / Recovery / Keybinds / Misc
- [ ] Multi-Monitor Support — *partial:* per-screen bars, borders and dashboard
      focus work; global scaling and per-monitor brightness do not
- [ ] Additional theme options
- [ ] App launcher enhancements (pinned/recent)
- [ ] Unified popup configuration layer
- [ ] Extended documentation
- [ ] Community themes
- [ ] CLI
- [ ] More Linux distribution support

### Performance

The shell forked 5–6 processes per second while completely idle and never got a
full second of rest. That is fixed; see [Performance](#performance-1) below for
what changed and how it is measured.

---

<h2>
Known Issues
</h2>

- **Multi-Monitor Scaling:** Global scaling across mixed-resolution monitors (e.g., 4K paired with 1080p) is currently inconsistent. UI elements may appear misproportioned or poorly sized on non-1080p screens. Sizes are currently absolute pixel literals in `src/theme/Metrics.qml`; making them a function of `screen.height` is the outstanding work.

- **Top Bar Clipping:** Elements within the right notch may become visually clipped if the system tray is expanded and contains an excessive number of active items.

- **Shutdown Menu (Hyprshutdown) State:** Canceling a shutdown or logout action can sometimes leave the Hyprland session in an empty state with most applications unintentionally closed. It may also occasionally struggle to terminate all running apps smoothly.

- **Tray icon themes:** Applications that advertise a private `IconThemePath`
  may show a fallback glyph instead of their real icon.

> [!WARNING]
> **NixOS & Flakes Support:** The current NixOS installation pipeline and Flake implementation are experimental and may be broken. If you are on NixOS, manual configuration is currently required.

---

<h2>
  Compositors
</h2>

Auto-detected; a manual override lives in Config → Misc.

| | Hyprland | niri | labwc |
|---|---|---|---|
| Bar, notch, popups, OSD | yes | yes | yes |
| Lock screen | yes | yes | yes |
| Workspace indicator | yes | yes | yes (`ext-workspace`) |
| Active window / fullscreen unmap | yes | yes | yes |
| Idle inhibit (caffeine) | yes | yes | yes |
| Screenshots, recording | yes | yes | yes |
| Keybind editor writes live binds | yes | yes¹ | yes² |
| Keybind capture (passthrough) | yes | no | no |
| Layout indicator, gaps, blur tiles | yes | no | no |
| Night light | `hyprsunset` | no | no |
| Special/scratchpad workspace | yes | no | no |

¹ **niri.** Every save writes `~/.config/apex-shell/ApexShellKeybinds.kdl`, and
niri live-reloads its config and any file that config `include`s. Add the
`include` line to the top level of your `~/.config/niri/config.kdl` once — the
generated file's own header gives it verbatim — and edits apply immediately
after that, with no restart. It is not rewritten for you, because `include`
needs niri **v25.11 or newer** and rewriting `config.kdl` would break an older
one; on a pre-v25.11 niri, paste the generated block in instead.

² **labwc.** Every save runs `/usr/libexec/apex-labwc-keybinds apply`, which
splices the bindings into the marked region of `~/.config/labwc/rc.xml` — an
XML-aware edit that leaves the rest of a file you also own alone — and then
runs `labwc --reconfigure`. The helper ships in the APEX-OS image. If you are
running this shell from a `$HOME` checkout on a machine without it, the save
still writes the shell's own files and skips this step (there is a `test -x`
guard for exactly that), so labwc keeps whatever is already in its `rc.xml`.

**labwc** is a stacking compositor and is deliberately IPC-free — no D-Bus
interface, no sway/i3 socket, no `hyprctl`. Everything the shell needs from it
arrives over Wayland protocols instead, and labwc implements the ones that
matter: `ext-workspace-v1`, `ext-session-lock-v1`, `wlr-layer-shell`,
`wlr-foreign-toplevel`, `ext-idle-notify`, `wlr-output-power` and
`wlr-gamma-control`. So workspaces are fully functional there rather than
degraded, including click-to-switch.

What is still Hyprland-only is keybind CAPTURE — recording a shortcut by
pressing it inside the editor. That needs the compositor to stop swallowing
its own bindings for the duration, and the mechanism used is `hyprctl dispatch
submap, clean`. The tiling-specific tiles and the layout indicator hide
themselves on both niri and labwc, as the table says.

To verify shell behaviour under labwc without rebooting:

```bash
tests/run-nested-labwc.sh shell.qml 20
```

That runs labwc nested inside the current session with the shell inside it, and
reports any errors or warnings.

<h2>
  Performance
</h2>

APEX Shell used to fork 5–6 processes per second while completely idle, and on a
machine where the dashboard had been opened once it was far worse than that.
Measured properly it was **~22 process creations per second** doing nothing.

Almost none of it was necessary:

- **Every `/proc` read was a subprocess.** CPU, memory and network stats each
  ran `cat` on a timer; the network service additionally ran
  `ip route get | awk` every second to find the default interface; the CPU
  governor service ran `pgrep` plus two globbed `cat` pipelines every 2s. A
  comment in the memory service claimed `FileView` could not read virtual
  filesystems, which is false — `/proc` and `/sys` read fine in-process.
- **Nothing could stop.** Only one of seven telemetry services was a singleton,
  so the dashboard and the config page each built their own pollers, per screen,
  and the stats page gated them on an `Item`'s `visible` — which stays true
  inside a hidden window. Selecting the stats page once left six services
  polling until logout.
- **Two brightness sliders each polled `brightnessctl` once a second**, forever,
  to watch a number that only changes when a human touches a key.
- **The bar ran three `nmcli` pipelines every five seconds**, because the bar is
  always mapped.
- **Four independent 1 Hz clocks** ticked in parallel, so the process never got a
  full second of rest.

What it does now: `/proc` and `/sys` are read with `FileView`; every telemetry
service is a singleton whose timer is gated on a reference count; consumers
declare demand with [`ServiceRef`](src/components/ServiceRef.qml) bound to real
window visibility; network state comes from `Quickshell.Networking` (live
NetworkManager D-Bus) instead of `nmcli`; brightness is one inotify-driven
service with no polling at all; there is one shared `SystemClock` with a
refcounted seconds tier; the app launcher uses Quickshell's native
`DesktopEntries` index instead of spawning a Python scanner per open; and pages
and popups are built on first use rather than at login.

### Measuring it

```bash
tests/measure-idle-cost.sh packaged    # the installed shell
tests/measure-idle-cost.sh worktree    # this checkout
```

`perf stat -e sched:sched_process_exec` is the obvious tool and cannot be used:
`perf` is absent on a stock install and `perf_event_paranoid` is 2, so it needs
root. The kernel's cumulative fork counter (`/proc/stat` `processes`) answers the
same question with no privileges.

It matters that the script is **paired and alternating**. `/proc/stat` is
system-wide, and on a real desktop the background rate is both large and
non-stationary — a single floor window followed by a single shell window
produces nonsense, including negative attributions. The script instead stops and
resumes the shell repeatedly and reports the median paired difference, so drift
cancels.

Results on a ThinkPad L16 (Ryzen 7 PRO 250), 8 pairs × 8s, every page and popup
opened once first so both shells are compared with everything built:

| | attributable process creations |
|---|---|
| Before | **+21.9/s** (all 8 pairs positive, 15.4–27.6) |
| After | **−0.75/s** (pairs scattered −5.6…+7.0) |

The "after" figure is not a claim of literally zero — it means the shell's idle
cost has fallen below what this method can resolve on a live desktop. The
before-signal was unambiguous; the after-signal is absent.

Behaviour of the refcount tier is covered by
[`tests/service-tier-test.qml`](tests/service-tier-test.qml) (32 assertions
against real `/proc` and `/sys`), run via `tests/run-service-tier-test.sh`.

---

<h2>
  Contributing
</h2>

APEX Shell is actively developed and welcomes contributions!

- Found a bug? → [Open an issue](https://github.com/AndreNijman/apex-shell/issues)
- Have an idea? → [Start a discussion](https://github.com/AndreNijman/apex-shell/discussions)
- Want to contribute? → Fork, branch, and submit a pull request

---

<h2>
  Credits / Acknowledgements
</h2>

APEX Shell is inspired by and originally derived from [Brain_Shell](https://github.com/Brainitech/Brain_Shell) by Brainitech (Venkat Saahit Kamu), used under the MIT License. APEX Shell has since diverged as the standard shell for APEX-OS.

Additional thanks to the projects and communities that make this shell possible:

- **[Hyprland Community](https://github.com/hyprwm)** – For creating an exceptional Wayland compositor and fostering an amazing community
- **[Quickshell Contributors](https://github.com/quickshell/quickshell)** – For the powerful QML framework that powers this shell
- **[Matugen Team](https://github.com/InioX/matugen)** – For Material You color generation technology
- **[Wayland Project](https://wayland.freedesktop.org)** – For the modern display protocol foundation
- **[Caelestia Shell](https://github.com/caelestia-dots/shell)** & **[AX-Shell](https://github.com/Axenide/ax-shell)** — For the inspiration

---

<h2>
  Star History
</h2>

<div align="center">
  <a href="https://www.star-history.com/?repos=AndreNijman%2Fapex-shell&type=date&legend=top-left">
   <picture>
     <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=AndreNijman/apex-shell&type=date&theme=dark&legend=top-left" />
     <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=AndreNijman/apex-shell&type=date&legend=top-left" />
     <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=AndreNijman/apex-shell&type=date&legend=top-left" />
   </picture>
  </a>
</div>

---

<h2>
  License
</h2>

This project is licensed under the MIT License – see the [LICENSE](LICENSE) file for details.
