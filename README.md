# Brain Shell

A modular session shell for Hyprland, built on Quickshell.

## Devlog 10: Keybind Engine, Lua Migration, and Bug Squashing

**Core Additions**

- **Keybind Editor:** Created a full in-shell keybind editor via `KeybindsPage.qml` and the `KeybindService.qml` singleton. It captures keystrokes on key release without needing a confirm button. It detects conflicts with both shell binds and live Hyprland binds. It isolates key captures from compositor shortcuts using a `BrainShell_clean` submap.

- **Dynamic Lua Config:** The `KeybindService` generates a Hyprland Lua keybind block, appends it to the shell's config, and automatically calls `hyprctl reload` after a 300 ms delay.

**Architecture & Under-the-Hood Changes**

- **Hyprland Lua Migration:** The Hyprland configuration was migrated from the legacy `hyprland.conf` format to the v0.55 Lua API. IPC dispatchers and workspace events were updated to the new `hl.dsp.*` syntax.

- **Screen Recorder Backend:** The screen recording dependency was switched from `wl-screenrec` to `wf-recorder` because it is actively maintained and available in the `extra` repo.

- **Shader Decoupling:** The shader tile was decoupled from `hyprshade`. It now lists `.glsl` files directly from `~/.config/hypr/shaders/` and applies them using `hyprctl keyword decoration:screen_shader`.

**Bug Fixes & Polish**

- **Notification Fixes:** Stored notifications are marked on first receipt so they no longer re-fire and trigger toasts upon Quickshell reloads.

- **Network Panel Polish:** Added an eye icon to toggle password visibility in the Wi-Fi tab. Fixed a bug where the Forget command failed on SSIDs with colons or special characters by using a robust `awk` pipeline. Fixed the Hotspot tab's eye button height from 2 to 28 so it is properly clickable.

- **UI/UX Tweaks:** The `ClockCard`'s manual time input panel now properly collapses immediately after confirming a custom timer. The Dashboard page area now requests global focus on open, ensuring the Escape key reliably closes the dashboard from any tab.

---

## Current Architecture Status

- **Centralized Popups:** `shell.qml` handles the anchor windows, but passes them to `PopupLayer.qml`, which acts as the single source of truth for instantiating all popup windows.
- **Universal Animations:** Slide-in/out and hover-to-open logic are standardized across the shell via `PopupSlide.qml`.
- **State Management:** Local state stays local unless needed elsewhere. Cross-cutting variables live in `ShellState.qml`, and theme variables stream dynamically through `Theme.qml` via the `ColorLoader` watcher.

## Roadmap / Up Next

- **Dashboard Config Tab:** Finishing the remaining configuration sub-tabs (Appearance, Layout & Behavior, Data & Storage, Misc) to complete the dashboard settings UI.
- **Auto Updater:** Building and integrating an automatic update mechanism for the shell.
- **Isolated Configs:** Matugen, Hyprland modifications and config changes will be isolated to the Shell to keep the user's config untouched.
- **General Polish:** Making further improvements and stability fixes as the project approaches the v0.1.0 release candidate.
- **Post-v0.1.0 Scope:** Unifying the border-hover popup configuration into a single runtime management layer. Adding a pinned or recent row to the App Launcher.
