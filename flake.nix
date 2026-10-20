{
  description = "Vesktop with an external push-to-talk control socket";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = (builtins.fromJSON (builtins.readFile ./package.json)).version;
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          vesktop = pkgs.vesktop.overrideAttrs (_old: {
            inherit version;
            src = self;
          });
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
            # libvesktop's binding.gyp links against GLib/GIO.
            glib
            libpulseaudio
            pipewire
          ];

          packages = with pkgs; [
            electron_43
          ];

          # The npm Electron package does not run cleanly on NixOS, so skip it
          # and run the app with nixpkgs Electron instead
          ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
        };
      });
    };
}
