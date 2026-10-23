{
  description = "A custom Discord desktop app with Vencord built-in";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      packageJson = builtins.fromJSON (builtins.readFile ./package.json);

      # Automatically track the Electron version declared in package.json
      electronMajor = nixpkgs.lib.versions.major (
        nixpkgs.lib.removePrefix "^" packageJson.devDependencies.electron
      );
      electronFor =
        pkgs:
        pkgs."electron_${electronMajor}"
          or (throw "nixpkgs has no electron_${electronMajor} (package.json wants Electron ${electronMajor}, your nixpkgs might need to be updated)");
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          vesktop = pkgs.callPackage ./package.nix {
            src = self;
            electron = electronFor pkgs;
          };
        in
        {
          inherit vesktop;
          default = vesktop;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            nodejs_22
            pnpm_11
            python3
            gnumake
            gcc
            pkg-config
          ];

          buildInputs = with pkgs; [
            # libvesktop's binding.gyp links against GLib/GIO
            glib
            libpulseaudio
            pipewire
          ];

          packages = [ (electronFor pkgs) ];

          # The npm Electron package does not run cleanly on NixOS, so skip it
          # and run the app with nixpkgs Electron instead
          ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
        };
      });

      # The pnpm fixed-output hash in package.nix needs to be updated when
      # pnpm-lock.yaml changes. This app rewrites the hash from the build
      # failure's "got: sha256-..." line. Run with: nix run .#update
      apps = forAllSystems (pkgs: {
        update = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "update-vesktop" ''
              set -e -o pipefail

              buildLog=$(${pkgs.coreutils}/bin/mktemp)
              trap '${pkgs.coreutils}/bin/rm -f "$buildLog"' EXIT

              # Stream output through tee so progress stays visible while the
              # log is still captured for the hash grep below. pipefail makes
              # the `if` test nix exit status even though tee always exits 0
              if ${pkgs.nix}/bin/nix build "$PWD#vesktop" --no-link 2>&1 | ${pkgs.coreutils}/bin/tee "$buildLog"; then
                echo "Flake hash is up to date"
                exit 0
              fi

              hash=$(${pkgs.gnugrep}/bin/grep -oP 'got:\s*\Ksha256-[A-Za-z0-9+/=]+' "$buildLog" | ${pkgs.coreutils}/bin/tail -n1 || true)

              if [ -z "$hash" ]; then
                echo "Error: build failed without a pnpm dependency hash mismatch:" >&2
                ${pkgs.coreutils}/bin/cat "$buildLog" >&2
                exit 1
              fi

              echo "Updating pnpmDeps hash: $hash"
              ${pkgs.gnused}/bin/sed -i \
                "s|hash = \"sha256-[^\"]*\";|hash = \"$hash\";|" \
                package.nix

              echo "Verifying build..."
              ${pkgs.nix}/bin/nix build "$PWD#vesktop" --no-link

              echo "Vesktop flake updated successfully"
            ''
          );
        };
      });
    };
}
