{
  description = "APEX Shell — Modular Quickshell/QML desktop shell for Hyprland";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # ── Runtime dependencies (required at launch) ──────────────────────
        runtimeDeps = with pkgs; [
          # Core shell runtime
          quickshell
          hyprland
          qt6.full
          qt6ct

          # Audio
          pipewire
          pipewire-pulse
          wireplumber
          playerctl
          mpv-mpris
          mpd-mpris

          # Network / Bluetooth
          networkmanager
          bluez
          bluez-utils

          # Display / input utilities
          brightnessctl
          wl-clipboard
          slurp
          xdg-user-dirs
          xdg-desktop-portal-hyprland

          # System info
          upower
          libnotify
          polkit
          lm_sensors
          rfkill

          # Media & visualiser
          cava
          python3

          # Screen recording
          wf-recorder

          # Wallpaper & theming
          imagemagick
          awww
          matugen

          # Clipboard integration
          wtype
          cliphist

          # Power & hardware management
          envycontrol
          auto-cpufreq

          # Hyprland ecosystem
          hyprsunset
          hyprlock
          hypridle
        ];

        # ── Development extras (not needed at runtime) ─────────────────────
        devDeps = with pkgs; [
          git
          bash
          shellcheck
          python3Packages.python-lsp-server
        ];

        # ── Fonts ──────────────────────────────────────────────────────────
        fonts = with pkgs; [
          (nerdfonts.override { fonts = [ "JetBrainsMono" ]; })
        ];

        # ── The APEX Shell package ────────────────────────────────────────
        apex-shell = pkgs.stdenv.mkDerivation {
          pname   = "apex-shell";
          version = "0.1.0";

          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = runtimeDeps ++ fonts;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/share/apex-shell
            cp -r . $out/share/apex-shell/

            mkdir -p $out/lib
            $CC -shared -fPIC -O2 -Wl,-z,relro,-z,now \
              src/native/quickshell-argc-shim.c -ldl \
              -o $out/lib/libapex-quickshell-argc.so

            mkdir -p $out/bin
            makeWrapper ${pkgs.quickshell}/bin/quickshell $out/bin/apex-shell \
              --add-flags "-c $out/share/apex-shell" \
              --set LD_PRELOAD $out/lib/libapex-quickshell-argc.so \
              --set  QT_QPA_PLATFORMTHEME qt6ct \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description  = "A modular Quickshell/QML desktop shell for Hyprland";
            homepage     = "https://github.com/AndreNijman/apex-shell";
            license      = licenses.mit;
            platforms    = platforms.linux;
            mainProgram  = "apex-shell";
          };
        };

      in
      {
        # ── Packages ───────────────────────────────────────────────────────
        packages = {
          default     = apex-shell;
          apex-shell = apex-shell;
        };

        # ── Dev shell (nix develop) ────────────────────────────────────────
        devShells.default = pkgs.mkShell {
          name = "apex-shell-dev";

          buildInputs = runtimeDeps ++ devDeps ++ fonts;

          shellHook = ''
            export QT_QPA_PLATFORMTHEME=qt6ct
            export APEX_SHELL_ROOT="$(pwd)"

            echo ""
            echo "  APEX Shell dev environment"
            echo "  Run:  quickshell -c \$APEX_SHELL_ROOT"
            echo "  Lint: shellcheck install.sh dots-extra/install-arch.sh"
            echo ""
          '';
        };

        # ── NixOS module ───────────────────────────────────────────────────
        nixosModules.default = { config, lib, pkgs, ... }:
          let cfg = config.programs.apex-shell;
          in {
            options.programs.apex-shell = {
              enable = lib.mkEnableOption "APEX Shell desktop shell";

              autostart = lib.mkOption {
                type    = lib.types.bool;
                default = true;
                description = "Add apex-shell to Hyprland exec-once.";
              };
            };

            config = lib.mkIf cfg.enable {
              environment.systemPackages = [ apex-shell ];

              wayland.windowManager.hyprland.settings = lib.mkIf cfg.autostart {
                exec-once = [
                  "apex-shell"
                  "hypridle"
                  "awww-daemon"
                  "systemctl --user start hyprpolkitagent"
                  "wl-paste --type text  --watch cliphist store"
                  "wl-paste --type image --watch cliphist store"
                ];
              };
            };
          };

        # ── Checks (run by `nix flake check`) ─────────────────────────────
        checks = {
          build = apex-shell;
        };
      }
    );
}
