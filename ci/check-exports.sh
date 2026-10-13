#!/bin/bash
# Fails early (before xcodebuild) if a C function the Swift app calls is not exported by
# Cemu.framework. Scans the headers the bridging header pulls in for C prototypes.
set -eo pipefail
cd "$(dirname "$0")/.."
BIN=build-ios/out/Cemu.framework/Cemu
HEADERS=(MeloCafe/MeloCafe/Core/MeloCafe-Bridging-Header.h MeloCafe/MeloCafe/Core/Controller/CemuController.h src/ios/BiiUDiagnostics.h)
EXPORTS=$(nm -gU "$BIN" | awk '{print $3}')
missing=0
for h in "${HEADERS[@]}"; do
  [ -f "$h" ] || continue
  for fn in $(grep -hoE '^[A-Za-z_][A-Za-z0-9_ \*]*[ \*](Cemu[A-Za-z0-9_]*|GCControllerBridge_[A-Za-z0-9_]*|BiiU_[A-Za-z0-9_]*)\(' "$h" \
              | sed -E 's/.*[ \*]([A-Za-z0-9_]+)\($/\1/' | sort -u); do
    if ! grep -qx "_$fn" <<< "$EXPORTS"; then
      echo "::error::$fn (declared in $h) is not exported by Cemu.framework"
      missing=1
    fi
  done
done
[ "$missing" = 0 ] && echo "all bridge functions are exported"
exit $missing
