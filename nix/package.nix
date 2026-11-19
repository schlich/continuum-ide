# Continuum IDE built from this checkout, adapted from nixpkgs' t3code recipe
# (pkgs/by-name/t3/t3code). Linux only. Binaries are named `continuum-ide`
# (desktop) and `continuum` (server CLI) so the package can be installed next
# to upstream T3 Code without collisions.
{
  lib,
  stdenv,
  src,
  version,
  pnpmDepsHash,
  copyDesktopItems,
  electron_44,
  installShellFiles,
  libsecret,
  makeBinaryWrapper,
  makeDesktopItem,
  node-gyp,
  nodejs_26,
  pkg-config,
  python3,
  spdx-license-list-data,
  fetchPnpmDeps,
  pnpm_12,
  pnpmConfigHook,
  pnpmBuildHook,
  cacert,
  rustPlatform,
  gh,
  git,
}:

let
  electron = electron_44;
  nodejs = nodejs_26;
  pnpm = pnpm_12;
  # Must match PRODUCT_BRAND.linuxDesktopEntryStem in packages/shared, which the
  # app passes to setDesktopName and uses as its Wayland app ID / WM_CLASS.
  desktopEntryStem = "io.github.swashxdev.ContinuumIDE";
  desktopIcon = "assets/prod/black-universal-1024.png";

  resourceMonitor = rustPlatform.buildRustPackage {
    pname = "continuum-ide-resource-monitor";
    inherit version src;
    cargoRoot = "native/resource-monitor";
    buildAndTestSubdir = "native/resource-monitor";
    cargoLock.lockFile = "${src}/native/resource-monitor/Cargo.lock";
    meta.mainProgram = "t3-resource-monitor";
  };

  unwrapped = stdenv.mkDerivation (finalAttrs: {
    pname = "continuum-ide-unwrapped";
    inherit version src;
    strictDeps = true;
    __structuredAttrs = true;

    postPatch = ''
      substituteInPlace apps/web/vite.config.ts \
        --replace-fail 'const host = explicitHost || "localhost";' \
                       'const host = explicitHost || "127.0.0.1";'

      mkdir -p .generated/third-party-licenses/spdx/v3.28.0
      cp ${spdx-license-list-data.json}/json/details/*.json \
        .generated/third-party-licenses/spdx/v3.28.0
    '';

    nativeBuildInputs = [
      installShellFiles
      makeBinaryWrapper
      node-gyp
      nodejs
      python3
      pnpmConfigHook
      pnpmBuildHook
      pnpm
      cacert
      copyDesktopItems
      pkg-config
    ];

    buildInputs = [ libsecret ];

    pnpmWorkspaces = [
      "@t3tools/monorepo"
      "t3..."
      "@t3tools/desktop..."
      "@t3tools/scripts..."
    ];

    pnpmDeps = fetchPnpmDeps {
      inherit pnpm;
      inherit (finalAttrs)
        pname
        version
        src
        pnpmWorkspaces
        ;
      fetcherVersion = 5;
      hash = pnpmDepsHash;
    };

    preBuild = ''
      export pnpm_config_verify_deps_before_run=false

      node scripts/update-release-package-versions.ts ${version}

      export npm_config_nodedir=${nodejs}
      export ELECTRON_SKIP_BINARY_DOWNLOAD=1
      pnpm rebuild --pending "''${pnpmInstallFlags[@]}" --filter '!@t3tools/monorepo'
    '';

    pnpmBuildScript = "build:desktop";

    postBuild = ''
      pnpm vp cache clean
    '';

    dontPatchELF = true;
    noAuditTmpdir = true;

    installPhase = ''
      runHook preInstall

      lib="$out/libexec/continuum-ide"
      mkdir --parents "$lib"/apps/desktop "$lib"/apps/server
      cp --recursive --no-preserve=mode node_modules "$lib"
      cp --recursive --no-preserve=mode apps/server/{node_modules,dist} "$lib"/apps/server
      cp --recursive --no-preserve=mode \
        apps/desktop/{package.json,node_modules,dist-electron} \
        "$lib"/apps/desktop

      mkdir --parents "$lib"/apps/desktop/prod-resources
      install --mode=444 ${desktopIcon} "$lib"/apps/desktop/prod-resources/icon.png
      install -Dm755 \
        native/browser-secret/build/${stdenv.hostPlatform.node.arch}/t3-browser-secret \
        "$lib"/apps/desktop/prod-resources/browser-secret/t3-browser-secret

      find "$lib" -xtype l -delete

      makeWrapper ${lib.getExe nodejs} "$out"/bin/continuum \
        --add-flags "$lib"/apps/server/dist/bin.mjs

      makeWrapper ${lib.getExe electron} "$out"/bin/continuum-ide \
        --add-flags "$lib"/apps/desktop \
        --inherit-argv0

      install -Dm444 ${desktopIcon} \
        "$out"/share/icons/hicolor/1024x1024/apps/${desktopEntryStem}.png
      install -Dm444 assets/continuum/logo.svg \
        "$out"/share/icons/hicolor/scalable/apps/${desktopEntryStem}.svg

      runHook postInstall
    '';

    postInstall = ''
      for shell in bash fish zsh; do
        installShellCompletion --cmd continuum --"$shell" <("$out/bin/continuum" --completions "$shell")
      done
    '';

    postFixup = ''
      for module in "$out"/libexec/continuum-ide/node_modules/.pnpm/node-pty@*/node_modules/node-pty/prebuilds/linux-${stdenv.hostPlatform.node.arch}/pty.node; do
        patchelf --add-rpath ${lib.makeLibraryPath [ stdenv.cc.cc.lib ]} "$module"
      done
    '';

    desktopItems = [
      (makeDesktopItem {
        name = desktopEntryStem;
        desktopName = "Continuum IDE";
        comment = "Desktop IDE for coding agents";
        exec = "continuum-ide %U";
        terminal = false;
        icon = desktopEntryStem;
        startupWMClass = desktopEntryStem;
        categories = [ "Development" ];
      })
    ];

    meta = {
      description = "Desktop IDE for coding agents (fork of T3 Code)";
      homepage = "https://github.com/SwashX-dev/continuum-ide";
      license = lib.licenses.mit;
      mainProgram = "continuum-ide";
      platforms = lib.platforms.linux;
    };
  });
in
stdenv.mkDerivation {
  pname = "continuum-ide";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [ makeBinaryWrapper ];
  # The resource monitor sidecar is only built by electron-builder upstream; the
  # server checks this variable first. Agent CLIs (claude, codex) are left to
  # the user's PATH so their own configured wrappers are used.
  installPhase = ''
    mkdir -p $out/bin
    ln -s ${unwrapped}/share $out/share
    for program in ${unwrapped}/bin/*; do
      makeWrapper "$program" "$out/bin/$(basename "$program")" \
        --prefix PATH : ${
          lib.makeBinPath [
            gh
            git
          ]
        } \
        --set-default T3CODE_RESOURCE_MONITOR_PATH ${lib.getExe resourceMonitor}
    done
  '';
  passthru = { inherit unwrapped resourceMonitor; };
  meta = unwrapped.meta;
}
