{
  lib,
  stdenv,
  actool,
  apple-sdk_26,
  darwin,
  fetchFromGitHub,
  libiconv,
  nix-update-script,
  python3,
  swiftPackages,
  xcbuild,
  xcbuildHook,
  writeShellScriptBin,
  zlib,
}:

let
  xpcPackageType = {
    Identifier = "com.apple.package-type.xpc-service";
    Type = "PackageType";
    BasedOn = "com.apple.package-type.wrapper";
    Name = "XPC Service";
    DefaultBuildSettings = {
      PRODUCT_BUNDLE_PACKAGE_TYPE = "XPC!";
      WRAPPER_SUFFIX = ".xpc";
    };
    ProductReference = {
      FileType = "wrapper.xpc-service";
      Name = "$(WRAPPER_NAME)";
      IsLaunchable = "NO";
    };
  };

  xpcProductType = {
    Identifier = "com.apple.product-type.xpc-service";
    Type = "ProductType";
    BasedOn = "com.apple.product-type.bundle";
    Name = "XPC Service";
    DefaultBuildProperties = {
      MACH_O_TYPE = "mh_execute";
      WRAPPER_EXTENSION = "xpc";
    };
    PackageTypes = [ "com.apple.package-type.xpc-service" ];
  };

  sdkWithXpc = apple-sdk_26.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ python3 ];
    postInstall = (old.postInstall or "") + ''
      chmod u+w "$out/Library/Xcode/Specifications/PackageTypes.xcspec" "$out/Library/Xcode/Specifications/ProductTypes.xcspec"
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

      python3 - "$out/Library/Xcode/Specifications/PackageTypes.xcspec" "$out/Library/Xcode/Specifications/ProductTypes.xcspec" <<'PY'
      import plistlib
      import sys

      entries = [${builtins.toJSON xpcPackageType}, ${builtins.toJSON xpcProductType}]
      for path, entry in zip(sys.argv[1:], entries):
          with open(path, "rb") as source:
              plist = plistlib.load(source)
          plist.append(entry)
          with open(path, "wb") as destination:
              plistlib.dump(plist, destination, fmt=plistlib.FMT_XML)
      PY
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
    swiftPackages.swift
    xcbuildHook
  ]
  ++ lib.optionals stdenv.hostPlatform.isAarch64 [ darwin.autoSignDarwinBinariesHook ];

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
