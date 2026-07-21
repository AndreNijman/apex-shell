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
- **niri Compatibility** — Auto-detection with graceful degradation of Hyprland-only features
- **System Dashboard** — Monitor CPU, RAM, battery, temps, and more
- **Kanban/Tasks** — To Do, Ongoing and Completed lists with Priority and Deadlines
- **App Launcher** — Dropdown App Launcher
- **Keybinds** — Set your own keybinds for each popup
- **Theming Engine** — Live wallpaper-synced color updates
- **Network Manager** — WiFi, Bluetooth, VPN integration
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

**After installation, restart Hyprland for changes to take effect.**

---

<h2>
  Requirements
</h2>

> [!IMPORTANT]
> **Matugen is required** for dynamic color generation. APEX Shell will not function correctly without it.

### Core Dependencies

<details open>
<summary><b>Runtime & Rendering</b></summary>

- **Hyprland** v0.55+ – Wayland compositor (niri also supported)
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
- [ ] Config Pages for Shell Customization
- [ ] Multi-Monitor Support
- [ ] Additional theme options
- [ ] App launcher enhancements (pinned/recent)
- [ ] Unified popup configuration layer
- [ ] Extended documentation
- [ ] Community themes
- [ ] CLI
- [ ] More Linux distribution support

---

<h2>
Known Issues
</h2>

- **Multi-Monitor Scaling:** Global scaling across mixed-resolution monitors (e.g., 4K paired with 1080p) is currently inconsistent. UI elements may appear misproportioned or poorly sized on non-1080p screens.

- **Top Bar Clipping:** Elements within the right notch may become visually clipped if the system tray is expanded and contains an excessive number of active items.

- **Shutdown Menu (Hyprshutdown) State:** Canceling a shutdown or logout action can sometimes leave the Hyprland session in an empty state with most applications unintentionally closed. It may also occasionally struggle to terminate all running apps smoothly.

> [!WARNING]
> **NixOS & Flakes Support:** The current NixOS installation pipeline and Flake implementation are experimental and may be broken. If you are on NixOS, manual configuration is currently required.

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
