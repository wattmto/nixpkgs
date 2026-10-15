{
  lib,
  stdenv,
  actool,
  apple-sdk_26,
  fetchFromGitHub,
  libiconv,
  nix-update-script,
  python3,
  rcodesign,
  swiftPackages,
  xcbuild,
  xcbuildHook,
  writeShellScriptBin,
  zlib,
}:

let
  sdkWithXpc = apple-sdk_26.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      sdkRoot="$out/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
      if [ ! -e "$sdkRoot/usr/include/zconf.h" ]; then
        ln -s ${zlib.dev}/include/zconf.h "$sdkRoot/usr/include/zconf.h"
      fi
      if [ ! -e "$sdkRoot/usr/include/zlib.h" ]; then
        ln -s ${zlib.dev}/include/zlib.h "$sdkRoot/usr/include/zlib.h"
      fi

      swiftLibDir="$sdkRoot/usr/lib/swift"
      stdlibToolSpec="$out/Library/Xcode/Specifications/com.apple.build-tools.swift-stdlib-tool.xcspec"
      rm -f "$stdlibToolSpec"
      cp ${xcbuild}/Library/Xcode/Specifications/com.apple.build-tools.swift-stdlib-tool.xcspec "$stdlibToolSpec"
      chmod u+w "$stdlibToolSpec"
      substituteInPlace "$stdlibToolSpec" \
        --replace-fail builtin-swiftStdLibTool ${swiftPackages.swift}/bin/swift-stdlib-tool \
        --replace-fail 'DefaultValue = "$(EFFECTIVE_TOOLCHAINS_DIRS)";' 'DefaultValue = "";'

      for library in ${swiftPackages.swift}/lib/libswift*.tbd; do
        libraryName="$(basename "$library")"
        if [ ! -e "$swiftLibDir/$libraryName" ]; then
          ln -s "$library" "$swiftLibDir/$libraryName"
        fi
      done
    '';
  });

  actoolCompat = writeShellScriptBin "actool" ''
    args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --product-type|--sticker-pack-identifier-prefix) shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    exec ${actool}/bin/actool "''${args[@]}"
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "macskk";
  version = "2.21.1";

  src = fetchFromGitHub {
    owner = "mtgto";
    repo = "macSKK";
    tag = finalAttrs.version;
    hash = "sha256-qk7Y9vPmSfHcJU2XyU12bPkWBIPyBrgiU+9fFMl3lm8=";
  };

  patches = [ ./nix-build.patch ];

  nativeBuildInputs = [
    actoolCompat
    python3
    rcodesign
    swiftPackages.swift
    xcbuildHook
  ];

  buildInputs = [
    sdkWithXpc
    libiconv
    zlib.dev
  ];

  strictDeps = true;

  xcbuildFlags = [
    "-project"
    "macSKK.xcodeproj"
    "-scheme"
    "macSKK"
    "-configuration"
    "Release"
    "CODE_SIGNING_ALLOWED=NO"
    "DEVELOPMENT_TEAM="
    "MACOSX_DEPLOYMENT_TARGET=13.3"
    "SWIFT_INSTALL_OBJC_HEADER=NO"
    "DEBUG_INFORMATION_FORMAT=dwarf"
    "SWIFT_LIBRARY_PATH=${sdkWithXpc}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/swift"
    "OTHER_LDFLAGS=-L${libiconv}/lib"
  ];

  preBuild = ''
    export DEVELOPER_DIR=${sdkWithXpc}
    export SDKROOT=${sdkWithXpc}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Library/Input Methods" "$out/bin"
    cp -R Products/Release/macSKK.app "$out/Library/Input Methods/"
    ln -s "$out/Library/Input Methods/macSKK.app/Contents/MacOS/macSKK" "$out/bin/macSKK"

    runHook postInstall
  '';

  # xcbuild omits standard bundle keys and corrupts non-ASCII .strings resources.
  postInstall = ''
    app="$out/Library/Input Methods/macSKK.app"
    cp macSKK/InfoPlist.strings "$app/Contents/Resources/InfoPlist.strings"
    cp macSKK/en.lproj/Localizable.strings "$app/Contents/Resources/en.lproj/Localizable.strings"
    cp macSKK/ja.lproj/Localizable.strings "$app/Contents/Resources/ja.lproj/Localizable.strings"

    python3 - \
      "$app/Contents/Info.plist" \
      "$app/Contents/XPCServices/FetchUpdateService.xpc/Contents/Info.plist" \
      "$app/Contents/XPCServices/SKKServClient.xpc/Contents/Info.plist" <<'PY'
    import plistlib
    import sys

    app_plist, fetch_update_plist, skk_serv_plist = sys.argv[1:]
    bundles = {
        app_plist: {
            "CFBundleIdentifier": "net.mtgto.inputmethod.macSKK",
            "CFBundleExecutable": "macSKK",
            "CFBundleName": "macSKK",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "${finalAttrs.version}",
            "CFBundleShortVersionString": "${finalAttrs.version}",
            "LSBackgroundOnly": True,
            "LSUIElement": True,
        },
        fetch_update_plist: {
            "CFBundleIdentifier": "net.mtgto.inputmethod.macSKK.FetchUpdateService",
            "CFBundleExecutable": "FetchUpdateService",
            "CFBundleDisplayName": "FetchUpdateService",
            "CFBundleName": "FetchUpdateService",
            "CFBundlePackageType": "XPC!",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleVersion": "${finalAttrs.version}",
            "CFBundleShortVersionString": "${finalAttrs.version}",
        },
        skk_serv_plist: {
            "CFBundleIdentifier": "net.mtgto.inputmethod.macSKK.SKKServClient",
            "CFBundleExecutable": "SKKServClient",
            "CFBundleDisplayName": "SKKServClient",
            "CFBundleName": "SKKServClient",
            "CFBundlePackageType": "XPC!",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleVersion": "${finalAttrs.version}",
            "CFBundleShortVersionString": "${finalAttrs.version}",
        },
    }

    for path, metadata in bundles.items():
        with open(path, "rb") as source:
            info = plistlib.load(source)
        info.update(metadata)
        with open(path, "wb") as destination:
            plistlib.dump(info, destination, fmt=plistlib.FMT_XML)
    PY
  '';

  # The generic Darwin hook signs Mach-O files but leaves the app bundle's
  # resources unsealed. Sign the complete bundle after fixups instead.
  postFixup = ''
    rcodesign sign "$out/Library/Input Methods/macSKK.app"
  '';

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Yet Another macOS SKK Input Method";
    homepage = "https://github.com/mtgto/macSKK";
    changelog = "https://github.com/mtgto/macSKK/blob/${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.gpl3Plus;
    maintainers = with lib.maintainers; [ wattmto ];
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
    mainProgram = "macSKK";
  };
})
