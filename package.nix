{
  lib,
  stdenv,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_11,
  nodejs_22,
  jq,
  electron,
  libicns,
  pipewire,
  libpulseaudio,
  autoPatchelfHook,
  copyDesktopItems,
  makeDesktopItem,
  makeWrapper,
  src,
  withMiddleClickScroll ? false,
}:

let
  version = (builtins.fromJSON (builtins.readFile "${src}/package.json")).version;
  pnpmDeps = fetchPnpmDeps {
    pname = "vesktop";
    inherit version src;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    # Run `nix run .#update` to recompute hash when pnpm-lock.yaml changes
    hash = "sha256-7wzkmGaXx1t43zNAWsocKJy12ib9CUoDNN3d9unoahg=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "vesktop";
  inherit version src pnpmDeps;

  nativeBuildInputs = [
    nodejs_22
    pnpmConfigHook
    pnpm_11
    jq
    # vesktop uses venmic, which is shipped as a prebuilt node module and
    # needs to be patched
    autoPatchelfHook
    copyDesktopItems
    # Environment variables in the wrapper must be expanded at runtime, so use
    # a script wrapper rather than makeBinaryWrapper
    makeWrapper
  ];

  buildInputs = [
    libpulseaudio
    pipewire
    (lib.getLib stdenv.cc.cc)
  ];

  env = {
    ELECTRON_SKIP_BINARY_DOWNLOAD = 1;
  };

  preBuild = ''
    # Validate the Electron version matches package.json
    expectedMajor="$(jq -r '.devDependencies.electron | ltrimstr("^") | split(".") | .[0]' < package.json)"
    actualMajor="${lib.versions.major electron.version}"
    if [ "$actualMajor" != "$expectedMajor" ] 2>/dev/null; then
      echo "ERROR: electron version mismatch between package.json (major $expectedMajor) and nixpkgs (major $actualMajor)"
      exit 1
    fi

    # Electron builds must be writable
    cp -r ${electron.dist} electron-dist
    chmod -R u+w electron-dist
  '';

  buildPhase = ''
    runHook preBuild

    pnpm build
    pnpm exec electron-builder \
      --dir \
      -c.asarUnpack="**/*.node" \
      -c.electronDist=electron-dist \
      -c.electronVersion=${electron.version}

    runHook postBuild
  '';

  postBuild = ''
    pushd build
    ${libicns}/bin/icns2png -x icon.icns
    popd
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/opt/Vesktop
    cp -r dist/*unpacked/resources $out/opt/Vesktop/

    for file in build/icon_*x32.png; do
      file_suffix=''${file//build\/icon_}
      install -Dm0644 $file $out/share/icons/hicolor/''${file_suffix//x32.png}/apps/vesktop.png
    done

    runHook postInstall
  '';

  postFixup = ''
    makeWrapper ${electron}/bin/electron $out/bin/vesktop \
      --add-flags $out/opt/Vesktop/resources/app.asar \
      ${lib.optionalString withMiddleClickScroll "--add-flags \"--enable-blink-features=MiddleClickAutoscroll\""} \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "vesktop";
      desktopName = "Vesktop";
      exec = "vesktop %U";
      icon = "vesktop";
      startupWMClass = "Vesktop";
      genericName = "Internet Messenger";
      comment = "Alternative Discord client with Vencord built-in";
      keywords = [
        "discord"
        "vencord"
        "electron"
        "chat"
      ];
      categories = [
        "Network"
        "InstantMessaging"
        "Chat"
      ];
      mimeTypes = [ "x-scheme-handler/discord" ];
    })
  ];

  passthru = {
    inherit (finalAttrs) pnpmDeps;
  };

  meta = {
    description = "Alternative Discord client with Vencord built-in";
    homepage = "https://github.com/Vencord/Vesktop";
    license = lib.licenses.gpl3Plus;
    mainProgram = "vesktop";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
})
