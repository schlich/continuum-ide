{
  # Development shell for building and running Continuum IDE from source on NixOS
  # (or any Linux with Nix). It provides the native build inputs the desktop app
  # compiles against and the shared libraries Electron's prebuilt binary loads.
  # Usage: `nix develop`, then follow docs/DEVELOPMENT.md (vp i, vp run dev:desktop).
  # The package (`nix run`, `packages.<system>.default`) builds the desktop app
  # from this checkout with nix/package.nix.
  description = "Continuum IDE: desktop IDE for coding agents";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      version = (builtins.fromJSON (builtins.readFile ./apps/desktop/package.json)).version;
      # Bump whenever pnpm-lock.yaml changes; the build prints the new hash.
      pnpmDepsHash = "sha256-27Ljt2lY4J1Fi3ddVIflPQ5erRqmgaZ8+YBH9fhCLzo=";
      continuum-ide =
        pkgs:
        pkgs.callPackage ./nix/package.nix {
          inherit version pnpmDepsHash;
          # Leave out VCS metadata and the agents' reference checkouts.
          src = nixpkgs.lib.cleanSourceWith {
            name = "continuum-ide-source";
            src = self;
            filter =
              path: _type:
              !(builtins.elem (baseNameOf path) [
                ".git"
                ".jj"
                ".repos"
                "node_modules"
              ]);
          };
        };
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # Libraries Electron's downloaded binary links against, loaded through nix-ld
      # (NixOS: `programs.nix-ld.enable = true;`).
      electronLibraries =
        pkgs: with pkgs; [
          alsa-lib
          at-spi2-atk
          at-spi2-core
          cairo
          cups
          dbus
          expat
          gdk-pixbuf
          glib
          gtk3
          libdrm
          libgbm
          libnotify
          libsecret
          libxkbcommon
          mesa
          nspr
          nss
          pango
          systemd
          libx11
          libxcomposite
          libxdamage
          libxext
          libxfixes
          libxrandr
          libxcb
          libxshmfence
          libxtst
          libxscrnsaver
          stdenv.cc.cc.lib
          vulkan-loader
          wayland
        ];
    in
    {
      packages = forAllSystems (pkgs: {
        default = continuum-ide pkgs;
        continuum-ide = continuum-ide pkgs;
      });

      overlays.default = final: _prev: { continuum-ide = continuum-ide final; };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            cargo
            gh
            git
            gnumake
            imagemagick
            pkg-config
            python3
            rustc
            libsecret
            # electron-builder's .deb and .rpm targets shell out to these.
            dpkg
            fakeroot
            rpm
          ];
          # nix-ld must load these with the glibc they were built against, not the host's.
          NIX_LD = pkgs.lib.fileContents "${pkgs.stdenv.cc}/nix-support/dynamic-linker";
          NIX_LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (electronLibraries pkgs);
          shellHook = ''
            if ! command -v vp >/dev/null 2>&1 && [ -f "$HOME/.config/vite-plus/env" ]; then
              . "$HOME/.config/vite-plus/env"
            fi
            command -v vp >/dev/null 2>&1 || echo "Install Vite+ first: curl -fsSL https://vite.plus | bash"
          '';
        };
      });
    };
}
