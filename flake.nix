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
      # pnpm-lock.yaml changes. A stale hash can be reused from the store, so the
      # build may fail with ERR_PNPM_NO_OFFLINE_TARBALL instead of a hash mismatch.
      # This app blanks the hash to force Nix to recompute the dependency store,
      # then writes the "got: sha256-..." value back. Run with: nix run .#update
      apps = forAllSystems (pkgs: {
        update = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "update-vesktop" ''
              set -e -o pipefail

              buildLog=$(${pkgs.coreutils}/bin/mktemp)
              trap '${pkgs.coreutils}/bin/rm -f "$buildLog"' EXIT

              oldHash=$(${pkgs.gnugrep}/bin/grep -oP 'hash = "\K[^"]+' package.nix | ${pkgs.coreutils}/bin/head -n1 || true)

              getHash() {
                ${pkgs.gnugrep}/bin/grep -oP 'got:\s*\Ksha256-[A-Za-z0-9+/=]+' "$buildLog" | ${pkgs.coreutils}/bin/tail -n1 || true
              }

              restoreHash() {
                ${pkgs.gnused}/bin/sed -i \
                  "s|hash = \"[^\"]*\";|hash = \"$oldHash\";|" \
                  package.nix
              }

              # Stream output through tee so progress stays visible while the
              # log is still captured for the hash grep below. pipefail makes
              # the `if` test nix exit status even though tee always exits 0
              if ${pkgs.nix}/bin/nix build "$PWD#vesktop" --no-link 2>&1 | ${pkgs.coreutils}/bin/tee "$buildLog"; then
                echo "Flake hash is up to date"
                exit 0
              fi

              hash=$(getHash)

              if [ -z "$hash" ]; then
                # No hash mismatch means Nix reused the stale fixed-output store.
                # Force a fresh fetchPnpmDeps build by blanking the hash.
                echo "No hash mismatch found; recomputing pnpmDeps from an empty hash..." >&2
                ${pkgs.gnused}/bin/sed -i \
                  's|hash = "[^\"]*";|hash = "";|' \
                  package.nix

                if ${pkgs.nix}/bin/nix build "$PWD#vesktop" --no-link 2>&1 | ${pkgs.coreutils}/bin/tee "$buildLog"; then
                  echo "Error: build succeeded with an empty hash; cannot determine pnpmDeps hash" >&2
                  restoreHash
                  exit 1
                fi

                hash=$(getHash)
              fi

              if [ -z "$hash" ]; then
                echo "Error: build failed without a pnpm dependency hash mismatch:" >&2
                ${pkgs.coreutils}/bin/cat "$buildLog" >&2
                restoreHash
                exit 1
              fi

              echo "Updating pnpmDeps hash: $hash"
              ${pkgs.gnused}/bin/sed -i \
                "s|hash = \"[^\"]*\";|hash = \"$hash\";|" \
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
