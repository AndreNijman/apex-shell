<h1 align=center>Rime Shell</h1>

<h3 align="center">
The standard desktop shell of Rime OS: a modular Wayland shell built with Quickshell and QML for Hyprland, niri and labwc.
</h3>

<p align="center">
  <img src="https://img.shields.io/github/last-commit/AndreNijman/rime-shell?style=for-the-badge&color=8D748C&logoColor=D9E0EE&labelColor=252733" alt="Last Commit" />
  <img src="https://img.shields.io/github/stars/AndreNijman/rime-shell?style=for-the-badge&logo=starship&color=AB6C6A&logoColor=D9E0EE&labelColor=252733" alt="Stars" />
  <img src="https://img.shields.io/badge/version-0.1.0-8D748C?style=for-the-badge&logoColor=D9E0EE&labelColor=252733" alt="Version 0.1.0" />
  <br>
  <img src="https://img.shields.io/badge/hyprland-v0.55+-5E81AC?style=for-the-badge&logoColor=D9E0EE&labelColor=252733" alt="Hyprland v0.55+" />
  <img src="https://img.shields.io/badge/compositor-niri-5E81AC?style=for-the-badge&logoColor=D9E0EE&labelColor=252733" alt="niri" />
  <img src="https://img.shields.io/badge/framework-quickshell-A1C999?style=for-the-badge&logoColor=D9E0EE&labelColor=252733" alt="Quickshell Framework" />
  <br>
  <a href="https://github.com/AndreNijman/rime-shell/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/AndreNijman/rime-shell?style=for-the-badge&color=A1C999&logo=opensourceinitiative&logoColor=D9E0EE&labelColor=252733" alt="License" />
  </a>
  <a href="https://github.com/AndreNijman/rime-shell/issues">
    <img src="https://img.shields.io/github/issues/AndreNijman/rime-shell?style=for-the-badge&logo=github&color=5E81AC&logoColor=D9E0EE&labelColor=252733" alt="Issues" />
  </a>
</p>

---

<h2 align="center">Features</h2>

- **Fluid motion**: surfaces grow out of the bar and the screen's frame, and
  open and close on springs that keep their velocity when you reverse them
  mid-way. One motion system (`Motion.qml`) times everything, and Reduce Motion
  and the motion speed setting apply to all of it, Hyprland's window animations
  included
- **Settings (Nexus)**: sixteen pages in five groups (Look & feel, Input,
  Privacy & agents, Devices, System). Open it with SUPER+C or the Dashboard's
  Settings tab; the window extrudes from the centre notch
- **Dashboard**: Home, System (CPU, RAM, battery, temperatures), Agents, Tasks
  and Apps tabs, plus the Settings tab
- **Kanban/Tasks**: To Do, Ongoing and Completed lists with Priority and
  Deadlines
- **App Launcher**: apps (pinned first, then frecency-ranked recents), files,
  settings, windows, clipboard, calculator, commands, projects, agents, SSH
  hosts and package search, plus inline answers for queries typed with a leading
  `?`. Entries that set `PrefersNonDefaultGPU` (Steam) launch on the discrete
  GPU
- **Volume and brightness in the notch**: the level shows inside the centre
  notch; a separate OSD appears only over a fullscreen window, in focus mode, or
  while the Dashboard or Settings is open
- **Lock screen**: a native Wayland session lock. It arrives as the notch
  pouring down over a still of the desktop and leaves the same way in reverse;
  the password field shows one Material 3 Expressive shape per character, never
  the characters
- **Workspaces**: the capsule shows only occupied, focused and urgent
  workspaces, each dot numbered
- **Background apps**: the tray folds behind one toggle that shows how many apps
  are running in the background
- **Frame**: screen-edge strips whose corner fillets merge into the bar; on
  Hyprland the shell sets window rounding so window corners are concentric with
  the frame
- **Screenshots**: an area screenshot freezes every output while you pick the
  region
- **Material You Integration**: dynamic colors via Matugen, updated live from
  the wallpaper, in a light or dark scheme
- **Lua-Based Config**: Hyprland v0.55+ compatible
- **Multi-Compositor**: Hyprland, niri and labwc, auto-detected; Hyprland-only
  features hide themselves on the other two
- **Per-output sizing**: each surface sizes itself for the output it is on
- **Keybinds**: set your own keybind for each popup
- **Recovery**: Settings → Recovery reads `rime recover status` and
  `rime doctor` and shows what is wrong, how to roll back, and what a factory
  reset would delete (Rime OS only; read-only until you press something)
- **Network Manager**: Wi-Fi (incl. WPA2-Enterprise/802.1X), Bluetooth, VPN
  integration
- **Notifications**: a notification server with a notification centre, toasts
  and Do Not Disturb
- **Audio Control**: PipeWire volume & device management
- **Screen Recorder**: built-in recording with wf-recorder
- **Clipboard Manager**: cliphist integration for history management
- **Plugins**: bar widgets, launcher providers and quick-settings tiles; see
  [docs/plugins.md](docs/plugins.md)
- **Customizable**: a QML-based UI you can extend

> **Note:** Rime Shell is at `v0.1.0`. The core architecture and theming pipeline are feature-complete, but you may still hit bugs; please report them in GitHub Issues.

---

<h2>
  Installation
</h2>

Rime OS ships the shell in its image, built from this repository's `main`, and
`sudo rime update` updates it. The installer below is for other distributions.

### One line installer

```bash
curl -fsSL https://raw.githubusercontent.com/AndreNijman/rime-shell/refs/heads/main/install.sh | bash
```

### Manual installation

```bash
git clone https://github.com/AndreNijman/rime-shell.git
cd rime-shell
chmod +x install.sh
./install.sh
```

The installer:

- ✓ Detects your Linux distribution
- ✓ Detects your Window Manager and Hyprland Config
- ✓ Backs up your entire `~/.config`
- ✓ Installs all required dependencies
- ✓ Clones the repository to `~/.local/src/rime-shell`
- ✓ Updates your Hyprland config to auto-start Rime Shell and required dependencies
- ✓ Renders a portable matugen config (no hardcoded paths) into `~/.config/rime-shell/matugen.toml`
- ✓ Creates configuration directories
- ✓ Installs a tightly scoped polkit rule for passwordless sing-box VPN toggling (only when sing-box is present)
- ✓ Registers the polkit action behind the Always Unrestricted agent toggle

**After installation, restart Hyprland for changes to take effect.**

---

<h2>
  VPN (sing-box) control plane
</h2>

The VPN tab controls the [sing-box](https://sing-box.sagernet.org/) VLESS/Reality
tunnel through **systemd**: `systemctl start|stop sing-box.service` to
connect/disconnect and `systemctl is-active sing-box.service` to read status.

To keep the toggle password-free without granting broad `sudo`, Rime Shell ships
a tightly scoped **polkit** rule at
[`dots-extra/polkit/49-rime-shell-singbox.rules`](dots-extra/polkit/49-rime-shell-singbox.rules).
It authorizes `start` / `stop` / `restart` of **only** `sing-box.service`
(`org.freedesktop.systemd1.manage-units`) for an active local session, and
nothing else. Reading status needs no rule (it is an unprivileged query).

The Arch installer drops it into `/etc/polkit-1/rules.d/` when it detects
sing-box. To install it by hand on any systemd host:

```bash
sudo install -Dm644 dots-extra/polkit/49-rime-shell-singbox.rules \
     /etc/polkit-1/rules.d/49-rime-shell-singbox.rules
```

polkitd hot-reloads `rules.d/`, so the rule takes effect at once, with no
restart. On image-based systems (e.g. Rime OS) ship it read-only under
`/usr/share/polkit-1/rules.d/` instead. Rime Shell assumes `sing-box.service` is
installed **disabled** (it never autostarts) with its config at
`/etc/sing-box/config.json`.

---

<h2>
  Agent sandbox default (Always Unrestricted)
</h2>

**Settings → Agents** carries one toggle. On, an agent session started from then
on runs with no Rime sandbox: it reads and writes any file you can, the same as
a program you launch yourself. Off is the normal default, where the project is
writable and the rest of `$HOME` is masked.

Switching it **on** takes your password at the desktop's polkit authentication
prompt. Switching it **off** takes effect at once and asks for nothing.

The toggle writes `sandbox` in `~/.config/rime/agent.json`, the agent runtime's
own configuration file (the one `rime agent run` reads), so the setting survives
a reboot and applies to `a` from a terminal as much as to anything started from
the shell. It moves that one key and no other, so a Claude profile set to
`bypassPermissions` survives either direction.

It grants **no root** and hands over **no secrets**. Sessions keep the kernel's
`no_new_privs` flag whichever sandbox they have, so `sudo` fails inside one,
and the secret broker performs a granted operation without ever returning the
credential.

The password prompt needs a registered polkit **action** (an action, not a
rule). It grants nothing: it declares that the id exists and that your own
password answers it (`auth_self`, not `auth_admin`, and not cached):

```bash
sudo install -Dm644 dots-extra/polkit/org.rimeos.shell.agent.policy \
     /usr/share/polkit-1/actions/org.rimeos.shell.agent.policy
```

The Arch installer does this for you. Without it the toggle cannot be switched
on and says so: `pkcheck` exits 127 with *is not registered*. Image builds ship
it read-only at the same path.

---

<h2>
  Requirements
</h2>

> [!IMPORTANT]
> **Matugen is required** for dynamic color generation. Rime Shell will not function correctly without it.

### Core Dependencies

<details open>
<summary><b>Runtime & Rendering</b></summary>

- **Hyprland** v0.55+: Wayland compositor (niri and labwc also supported)
- **Quickshell**: QML shell framework. Needs a build **newer than the 0.3.1
  release**: 0.3.1 publishes a single node to the accessibility bus with nothing
  under it, so a screen reader reaches none of the shell. Upstream fixed it in
  `916a0dd` seven commits after that tag, and no release carries it yet. Rime OS
  installs `quickshell-git` for this reason and the image build refuses a
  quickshell that reports no git revision.
- **Qt6**: Qt6 libraries and QML engine
- **qt6ct**: Qt6 theme configuration

</details>

<details open>
<summary><b>System Tools</b></summary>

- **PipeWire**: audio server (pipewire, pipewire-pulse, wireplumber)
- **NetworkManager**: network management
- **BlueZ**: Bluetooth stack (bluez, bluez-utils)
- **Brightnessctl**: backlight control
- **Mpris**: media players
- **Playerctl**: player controls
- **UPower**: battery and power info
- **libnotify**: desktop notifications
- **Polkit**: privilege escalation
- **wl-clipboard**: Wayland clipboard (wl-copy/wl-paste)

</details>

<details open>
<summary><b>Theming & Wallpaper</b></summary>

- **Matugen**: Material You color generation **(REQUIRED)**
- **awww**: wallpaper daemon (Wayland)
- **ImageMagick**: image manipulation

</details>

<details open>
<summary><b>Recording & Utilities</b></summary>

- **wf-recorder**: screen recording (Wayland)
- **cava**: audio visualizer
- **slurp**: region/window selection
- **grim** / **grimblast**: screenshots (grimblast on Hyprland, grim on niri and
  labwc)
- **hyprpicker**: freezes the screen while you pick a screenshot area
- **wtype**: keyboard input emulation
- **cliphist**: clipboard history manager

</details>

<details open>
<summary><b>Hardware Management</b></summary>

- **lm_sensors**: CPU temperature & fan monitoring
- **rfkill**: Airplane mode control
- **envycontrol**: GPU switching (NVIDIA/Intel)
- **auto-cpufreq**: CPU frequency scaling
- **nbfc-linux**: laptop fan control
- **switcheroo-control**: optional; desktop entries that set
  `PrefersNonDefaultGPU` (Steam) launch on the discrete GPU through
  `switcherooctl launch`

</details>

<details open>
<summary><b>Hyprland Integration</b></summary>

- **hyprlock**: not used by default. The shell draws its own lock screen
  (`src/windows/Lockscreen.qml`); the Arch installer still installs hyprlock,
  and `src/config/hyprlock.conf` stays as a fallback
- **hypridle**: idle management daemon
- **hyprsunset**: blue light filter
- **hyprshutdown**: installed by the Arch installer; the power menu no longer
  calls it (shutdown, reboot and suspend go through `systemctl`; see
  `src/scripts/PowerControl.sh`)
- **xdg-desktop-portal-hyprland**: portal backend

</details>

<details open>
<summary><b>Fonts</b></summary>

- **ttf-jetbrains-mono-nerd**: primary font (Nerd Font variant)
- **ttf-noto-nerd**: emoji and CJK support

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
- [x] UI/UX redesign: fluid motion, Settings (Nexus), the redesigned lock screen
  and bar

### Upcoming (Post-v0.1.0)

- [x] Scaling on Different Screen-Sizes: each surface builds its size tokens
      (`ThemeSet`) at its own output's scale factor
- [x] Config Pages for Shell Customization: sixteen Settings pages in five
      groups (Look & feel, Input, Privacy & agents, Devices, System)
- [ ] Multi-Monitor Support: *partial.* Per-screen bars, borders and dashboard
      focus, per-output sizing and per-monitor brightness (DDC/CI through
      `ddcutil`) work; mixed refresh rates are untested on real panels
- [ ] Additional theme options
- [x] App launcher enhancements (pinned/recent)
- [ ] Unified popup configuration layer
- [ ] Extended documentation
- [ ] Community themes
- [ ] CLI
- [ ] More Linux distribution support

### Performance

The shell forked 5-6 processes per second while idle and never got a full second
of rest. That is fixed; see [Performance](#performance-1) below for what changed
and how it is measured.

---

<h2>
Known Issues
</h2>

- **Top Bar Clipping:** The left notch stops growing at its maximum width, so
  its contents can be clipped when the background apps tray is unfolded and
  holds many items.

- **Tray icon themes:** Applications that advertise a private `IconThemePath`
  may show a fallback glyph instead of their real icon.

> [!WARNING]
> **NixOS & Flakes Support:** The NixOS installation pipeline and Flake implementation are experimental and may be broken. On NixOS, configure the shell by hand for now.

---

<h2>
  Compositors
</h2>

Auto-detected; you can override it in Settings → Misc.

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

¹ **niri.** Every save writes `~/.config/rime-shell/RimeShellKeybinds.kdl`, and
niri live-reloads its config and any file that config `include`s. Add the
`include` line (the generated file's own header gives it verbatim) to the top
level of your `~/.config/niri/config.kdl` once, and from then on edits apply
with no restart. The shell does not add the line for you, because `include`
needs niri **v25.11 or newer** and rewriting `config.kdl` would break an older
one; on a pre-v25.11 niri, paste the generated block in instead.

² **labwc.** Every save runs `/usr/libexec/rime-labwc-keybinds apply`, which
splices the bindings into the marked region of `~/.config/labwc/rc.xml` (an
XML-aware edit that leaves the rest of a file you also own alone), then runs
`labwc --reconfigure`. The helper ships in the Rime OS image. If you are running
this shell from a `$HOME` checkout on a machine without it, the save still
writes the shell's own files and skips this step (a `test -x` guard covers that
case), so labwc keeps whatever is already in its `rc.xml`.

**labwc** is a stacking compositor with no IPC by design: no D-Bus interface, no
sway/i3 socket, no `hyprctl`. Everything the shell needs from it arrives over
Wayland protocols, and labwc implements the ones the shell uses:
`ext-workspace-v1`, `ext-session-lock-v1`, `wlr-layer-shell`,
`wlr-foreign-toplevel`, `ext-idle-notify`, `wlr-output-power` and
`wlr-gamma-control`. Workspaces therefore work in full there, including
click-to-switch.

Keybind CAPTURE (recording a shortcut by pressing it inside the editor) is still
Hyprland-only. It needs the compositor to stop swallowing its own bindings while
you press them, and the shell does that by switching Hyprland to an empty
submap, `RimeShell_clean`. The tiling-specific tiles and the layout indicator
hide themselves on niri and labwc, as the table says.

To verify shell behaviour under labwc without rebooting:

```bash
tests/run-nested-labwc.sh shell.qml 20
```

That runs labwc nested inside the current session with the shell inside it, and
reports any errors or warnings.

<h2>
  Performance
</h2>

Rime Shell used to fork 5-6 processes per second while idle, and far more on a
machine where someone had opened the dashboard once. The paired measurement
below put it at **~22 process creations per second** doing nothing.

Almost none of it was necessary:

- **Every `/proc` read was a subprocess.** CPU, memory and network stats each
  ran `cat` on a timer; the network service additionally ran
  `ip route get | awk` every second to find the default interface; the CPU
  governor service ran `pgrep` plus two globbed `cat` pipelines every 2s. A
  comment in the memory service claimed `FileView` could not read virtual
  filesystems, which is false: `/proc` and `/sys` read fine in-process.
- **Nothing could stop.** Only one of seven telemetry services was a singleton,
  so the dashboard and the config page each built their own pollers, per screen,
  and the stats page gated them on an `Item`'s `visible`, which stays true
  inside a hidden window. Selecting the stats page once left six services
  polling until logout.
- **Two brightness sliders each polled `brightnessctl` once a second**, forever,
  to watch a number that only changes when a human touches a key.
- **The bar ran three `nmcli` pipelines every five seconds**, because the bar is
  always mapped.
- **Four independent 1 Hz clocks** ticked in parallel, so the process never got a
  full second of rest.

The shell now reads `/proc` and `/sys` with `FileView`; every telemetry service
is a singleton whose timer is gated on a reference count; consumers declare
demand with [`ServiceRef`](src/components/ServiceRef.qml) bound to real window
visibility; network state comes from `Quickshell.Networking` (live
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

`perf stat -e sched:sched_process_exec` is the obvious tool, and you cannot use
it: `perf` is absent on a stock install and `perf_event_paranoid` is 2, so it
needs root. The kernel's cumulative fork counter (`/proc/stat` `processes`)
answers the same question with no privileges.

The script is **paired and alternating**, because `/proc/stat` is system-wide
and on a real desktop the background rate is large and non-stationary: a single
floor window followed by a single shell window produces nonsense, including
negative attributions. The script stops and resumes the shell repeatedly and
reports the median paired difference, so drift cancels.

Results on a ThinkPad L16 (Ryzen 7 PRO 250), 8 pairs × 8s, every page and popup
opened once first so both shells are compared with everything built:

| | attributable process creations |
|---|---|
| Before | **+21.9/s** (all 8 pairs positive, 15.4–27.6) |
| After | **−0.75/s** (pairs scattered −5.6…+7.0) |

The "after" figure means the shell's idle cost has fallen below what this method
can resolve on a live desktop; it does not claim zero. The before-signal was
unambiguous, and the after-signal is absent.

[`tests/service-tier-test.qml`](tests/service-tier-test.qml) covers the refcount
tier's behaviour (32 assertions against real `/proc` and `/sys`); run it with
`tests/run-service-tier-test.sh`.

---

<h2>
  Contributing
</h2>

Rime Shell is under active development and takes contributions:

- Found a bug? → [Open an issue](https://github.com/AndreNijman/rime-shell/issues/new/choose)
- Have an idea? → [Suggest a feature](https://github.com/AndreNijman/rime-shell/issues/new?template=feature_request.yml)
- Want to contribute? → Read [CONTRIBUTING.md](CONTRIBUTING.md), then fork, branch, and open a pull request
- Found a security problem? → Report it privately; see [SECURITY.md](SECURITY.md)

---

<h2>
  Credits / Acknowledgements
</h2>

Rime Shell is inspired by and originally derived from [Brain_Shell](https://github.com/Brainitech/Brain_Shell) by Brainitech (Venkat Saahit Kamu), used under the MIT License. Rime Shell has since diverged as the standard shell for Rime OS.

Additional thanks to the projects and communities that make this shell possible:

- **[Hyprland Community](https://github.com/hyprwm)**: for creating an
  exceptional Wayland compositor and fostering an amazing community
- **[Quickshell Contributors](https://github.com/quickshell/quickshell)**: for
  the QML framework that powers this shell
- **[Matugen Team](https://github.com/InioX/matugen)**: for Material You color
  generation technology
- **[Wayland Project](https://wayland.freedesktop.org)**: for the modern display
  protocol foundation
- **[Caelestia Shell](https://github.com/caelestia-dots/shell)** &
  **[AX-Shell](https://github.com/Axenide/ax-shell)**: for the inspiration

---

<h2>
  Star History
</h2>

<div align="center">
  <a href="https://www.star-history.com/?repos=AndreNijman%2Frime-shell&type=date&legend=top-left">
   <picture>
     <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=AndreNijman/rime-shell&type=date&theme=dark&legend=top-left" />
     <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=AndreNijman/rime-shell&type=date&legend=top-left" />
     <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=AndreNijman/rime-shell&type=date&legend=top-left" />
   </picture>
  </a>
</div>

---

<h2>
  License
</h2>

This project is licensed under the MIT License; see the [LICENSE](LICENSE) file
for details.

Third-party code keeps its own licence: `src/shapes/material/` is a vendored
port of AndroidX's graphics-shapes library and Google's Material 3 Expressive
shapes
([rounded-polygon-qmljs](https://github.com/end-4/rounded-polygon-qmljs)), under
the Apache License 2.0; see [its LICENSE](src/shapes/material/LICENSE) and
[README](src/shapes/material/README.md).

