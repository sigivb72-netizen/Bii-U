#!/bin/bash
# Packages a built BiiU.app into an unsigned-style IPA (ad-hoc signed with get-task-allow so
# LiveContainer / SideStore can re-sign it and StikDebug can attach for JIT).
# Usage: ci/package-ipa.sh PATH/TO/BiiU.app OUTPUT.ipa VERSION BUILD
set -eo pipefail
APP_IN="${1:?app}"; IPA="$(cd "$(dirname "${2:?ipa}")" && pwd)/$(basename "$2")"; VERSION="${3:?version}"; BUILD="${4:?build}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pb() { /usr/libexec/PlistBuddy "$@"; }

mkdir -p "$WORK/Payload"
cp -R "$APP_IN" "$WORK/Payload/BiiU.app"
APP="$WORK/Payload/BiiU.app"
find "$APP" -name _CodeSignature -type d -prune -exec rm -rf {} +
PL="$APP/Info.plist"
pb -c "Set :CFBundleShortVersionString $VERSION" "$PL" 2>/dev/null || pb -c "Add :CFBundleShortVersionString string $VERSION" "$PL"
pb -c "Set :CFBundleVersion $BUILD" "$PL" 2>/dev/null || pb -c "Add :CFBundleVersion string $BUILD" "$PL"
pb -c "Set :BiiUCommit ${GITHUB_SHA:-local}" "$PL" 2>/dev/null || pb -c "Add :BiiUCommit string ${GITHUB_SHA:-local}" "$PL"

for fw in "$APP"/Frameworks/*.framework; do
  codesign -f -s - "$fw"
done
codesign -f -s - --entitlements "$ROOT/MeloCafe/Sideload.entitlements" --generate-entitlement-der "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q get-task-allow \
  || { echo "::error::get-task-allow missing from the signed app"; exit 1; }

rm -f "$IPA"
( cd "$WORK" && zip -qry "$IPA" Payload )
ls -la "$IPA"
unzip -l "$IPA" | grep -E "BiiU.app/(BiiU|Frameworks/Cemu.framework/Cemu)$" \
  || { echo "::error::IPA is missing the app binary or Cemu.framework"; exit 1; }
