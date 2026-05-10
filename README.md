# Brain Shell

A modular session shell for Hyprland, built on Quickshell. 

## Devlog 9: Clipboard History, QuickControl, and v0.1.0 Prep

**Core Additions**
* **Clipboard History:** Fully functional clipboard manager backed by `cliphist` and `wl-copy`/`wl-paste`. Requires two `exec-once` lines in the Hyprland config to capture both text and images. The popup features live search filtering, arrow key navigation, and a clear-all function.
* **QuickControl Panel:** A new hover-open panel accessible from the right-center border strip for quick brightness and master volume adjustments. This surface acts as a fast, one-handed control that coexists independently from the full click-to-open `AudioPopup`.
* **Layout Cycling:** The `LayoutDisplayer` module now supports mouse interaction. You can cycle through available Hyprland layouts using left/right clicks or the scroll wheel.

**Compositor & Rendering Fixes**
* **WallpaperPopup Polish:** Implemented batched scan results to prevent UI thrashing on large directories, fixed URI scheme duplication, and added double-tap to apply. Added an invisible filler item to eliminate hover-flicker loops.
* **Notch Geometry:** Corrected the clickable space inside the center notch.
* **TabSwitcher Cleanup:** Adjusted the height of the TabSwitcher in the ArchMenu for better layout, added urgent workspace visual effects, and removed the left accent bar from the active tab.

**Architecture Refactoring**
* **Unified Animations:** Animation durations are now pulled dynamically from `Theme.qml` instead of being hardcoded.
* **Border Configuration:** Refactored Theme and Border properties to improve system configuration.
* **Dashboard Routing:** Updated the default page property in `Dashboard.qml` to open directly to the 'home' tab instead of 'stats'. Added reset functionality to the TabSwitcher to enhance Dashboard close behavior.

---

## Current Architecture Status

* **Centralized Popups:** `shell.qml` handles the anchor windows, but passes them to `PopupLayer.qml`, which acts as the single source of truth for instantiating all popup windows.
* **Universal Animations:** Slide-in/out and hover-to-open logic are standardized across the shell via `PopupSlide.qml`.
* **State Management:** Local state stays local unless needed elsewhere. Cross-cutting variables live in `ShellState.qml`, and theme variables stream dynamically through `Theme.qml` via the `ColorLoader` watcher.

## Roadmap / Up Next (Approaching v0.1.0 Release)

* **Release Milestone:** The shell is rapidly approaching its v0.1.0 release milestone.
* **Config Tab:** Building the unified GUI to manage border-hover popup assignments, animation durations, and feature toggles.
* **Keybind Wiring:** Documenting and mapping Hyprland keybinds (including the clipboard toggle) to the shell.
