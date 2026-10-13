#!/bin/bash
# Builds Cemu.framework (the emulator core) for arm64 iOS into build-ios/out.
# Incremental: the build directory and ccache are restored from the GitHub Actions cache,
# so only changed files recompile. Delete build-ios to force a clean build.
set -eo pipefail
cd "$(dirname "$0")/.."

mkdir -p .vcpkg-archives build-ios .lto-cache

FLAGS=(
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_SYSROOT=iphoneos
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
  -DVCPKG_TARGET_TRIPLET=arm64-ios
  -DBUILD_HEADLESS_DYLIB=ON
  -DCMAKE_MACOSX_BUNDLE=OFF
  -DCMAKE_BUILD_TYPE=Release
  -DBIIU_LTO_CACHE_DIR="$PWD/.lto-cache"
)
if command -v ccache >/dev/null 2>&1; then
  FLAGS+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
          -DCMAKE_OBJC_COMPILER_LAUNCHER=ccache -DCMAKE_OBJCXX_COMPILER_LAUNCHER=ccache
          # lets ccache cache files built with precompiled headers
          "-DCMAKE_CXX_FLAGS=-Xclang -fno-pch-timestamp"
          "-DCMAKE_OBJCXX_FLAGS=-Xclang -fno-pch-timestamp")
fi

# vcpkg downloads ports from third-party hosts during configure; retry transient failures.
for attempt in 1 2 3; do
  if cmake -S . -B build-ios -G Ninja "${FLAGS[@]}" 2>&1 | tee configure.log; then
    break
  fi
  if [ "$attempt" = 3 ]; then
    echo "::error::CMake configure failed three times - see configure.log"
    exit 1
  fi
  echo "configure attempt $attempt failed; retrying in $((attempt * 30))s"
  sleep $((attempt * 30))
done

cmake --build build-ios --target CemuBin 2>&1 | tee build.log

FW=$(find build-ios -type d -name Cemu.framework -not -path '*/CMakeFiles/*' -not -path 'build-ios/out/*' | head -n1)
if [ -z "$FW" ]; then echo "::error::build finished but produced no Cemu.framework"; exit 1; fi
rm -rf build-ios/out && mkdir -p build-ios/out
cp -R "$FW" build-ios/out/
file build-ios/out/Cemu.framework/Cemu
