# Shared Neovim build helpers for macOS, Android, and Apple mobile.
{
  lib,
  pkgs,
  buildPackages,
  neovimSrc,
  version,
  appleMobile ? false,
  androidToolchain ? null,
  iosToolchain ? null,
  simulator ? false,
  xcodeUtils ? null,
  toolchainSrc ? null,
}:

let
  inherit (pkgs) stdenv;

  patchDir = ./patches;

  applyAppleMobilePatches = ''
    cp ${patchDir}/patch-neovim-apple-mobile.py ./patch-neovim-apple-mobile.py
    cp ${patchDir}/patch-libuv-spawn.py ./patch-libuv-spawn.py
    cp ${patchDir}/cmake-apple-mobile-flags.snippet ./cmake-apple-mobile-flags.snippet
    cp ${patchDir}/cmake-deps-apple-mobile.snippet ./cmake-deps-apple-mobile.snippet
    python3 patch-neovim-apple-mobile.py
  '';

  baseNative = with buildPackages; [
    cmake
    ninja
    gnumake
    pkg-config
    python3
    lua5_1
  ];

  macNative = baseNative ++ (lib.optional (stdenv.hostPlatform.isDarwin) pkgs.gettext);

  cmakeExtraMac = lib.concatStringsSep " " [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DUSE_LUAJIT=ON"
    "-DLIBINTL_LIBRARY=${pkgs.gettext}/lib/libintl${pkgs.stdenv.targetPlatform.extensions.sharedLibrary}"
    "-DLIBINTL_INCLUDE_DIR=${pkgs.gettext}/include"
  ];

  cmakeExtraAppleMobile = lib.concatStringsSep " " [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DWAWONA_APPLE_MOBILE=ON"
    "-DUSE_LUAJIT=OFF"
    "-DPREFER_LUA=ON"
    "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF"
  ];

  depsCmakeExtraAppleMobile = lib.concatStringsSep " " [
    "-DWAWONA_APPLE_MOBILE=ON"
    "-DUSE_BUNDLED_LUAJIT=OFF"
    "-DUSE_BUNDLED_LUA=ON"
  ];

  hostCodegenPass = ''
    echo "=== wwn-neovim: host codegen pass (macOS native libnlua0) ==="
    export CMAKE_BUILD_TYPE=Release
    export CMAKE_EXTRA_FLAGS="${cmakeExtraAppleMobile} -DCMAKE_PREFIX_PATH=$PWD/.deps/usr"
    export DEPS_CMAKE_FLAGS="${depsCmakeExtraAppleMobile}"
    mkdir -p .deps/usr/bin
    ln -sf ${pkgs.lua5_1}/bin/lua .deps/usr/bin/lua
    ln -sf ${pkgs.lua5_1}/bin/luac .deps/usr/bin/luac
    make deps -j''${NIX_BUILD_CORES:-4}
    make build/.ran-cmake
    ${pkgs.cmake}/bin/cmake --build build --target nlua0 -j''${NIX_BUILD_CORES:-4}
    mkdir -p host-artifacts
    HOST_NLUA=$(find build -path '*/lib/libnlua0.so' -print -quit)
    if [ -z "$HOST_NLUA" ] || [ ! -f "$HOST_NLUA" ]; then
      echo "host libnlua0.so missing after codegen pass" >&2
      exit 1
    fi
    cp "$HOST_NLUA" host-artifacts/libnlua0.so
    rm -rf build .deps
  '';

  iosCrossBuildPass = ''
    echo "=== wwn-neovim: iOS cross-compile pass ==="
    export WAWONA_HOST_NLUA0="$PWD/host-artifacts/libnlua0.so"
    export CMAKE_BUILD_TYPE=Release
    export CMAKE_EXTRA_FLAGS="${cmakeExtraAppleMobile} -DCMAKE_TOOLCHAIN_FILE=$PWD/ios-toolchain.cmake -DCMAKE_PREFIX_PATH=$PWD/.deps/usr"
    export DEPS_CMAKE_FLAGS="${depsCmakeExtraAppleMobile} -DCMAKE_TOOLCHAIN_FILE=$PWD/ios-toolchain.cmake"
    cat >> ios-toolchain.cmake <<'EOF'
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
EOF
    mkdir -p .deps/usr/bin
    ln -sf ${pkgs.lua5_1}/bin/lua .deps/usr/bin/lua
    ln -sf ${pkgs.lua5_1}/bin/luac .deps/usr/bin/luac
    make deps -j''${NIX_BUILD_CORES:-4}
    if ! make -j''${NIX_BUILD_CORES:-4}; then
      if [ ! -f build/src/nvim/CMakeFiles/nvim_bin.dir/main.c.o ]; then
        echo "iOS cross-compile failed before nvim objects were built" >&2
        exit 1
      fi
      echo "wwn-neovim: nvim link failed as expected (libuv Unix libs); collecting static archive"
    fi
  '';

  collectArchive = ''
    WORKDIR=$(mktemp -d)
    SRC_ROOT="$PWD"
    find build -path '*/nvim_bin.dir/*.o' -exec cp {} "$WORKDIR"/ \;
    for lib in "$SRC_ROOT"/.deps/usr/lib/*.a; do
      [ -f "$lib" ] || continue
      (cd "$WORKDIR" && ar x "$lib")
    done
    MAIN_OBJ="$WORKDIR/main.c.o"
    if [ ! -f "$MAIN_OBJ" ]; then
      echo "main.c.o missing in archive workdir" >&2
      exit 1
    fi
    ${pkgs.llvmPackages.llvm}/bin/llvm-objcopy \
      --redefine-sym _main=_wawona_nvim_main "$MAIN_OBJ" "$WORKDIR/wawona_nvim_main.o"
    rm -f "$MAIN_OBJ"
    ${pkgs.llvmPackages.llvm}/bin/llvm-ar rcs libwawona-neovim.a "$WORKDIR"/*.o
    rm -rf "$WORKDIR"
  '';
in
{
  inherit version neovimSrc applyAppleMobilePatches collectArchive;
  inherit cmakeExtraMac cmakeExtraAppleMobile depsCmakeExtraAppleMobile baseNative macNative;
  inherit hostCodegenPass iosCrossBuildPass;
}
