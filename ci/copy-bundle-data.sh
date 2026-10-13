#!/bin/bash
# Xcode post-build step: copies Cemu's data files (shared fonts, game profiles) into
# BiiU.app/CemuData. The app copies them into Documents on first launch.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${BUILT_PRODUCTS_DIR:?not running inside an Xcode build}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/CemuData"
rm -rf "$DEST"
mkdir -p "$DEST/resources"
cp -R "$ROOT/bin/resources/sharedFonts" "$DEST/resources/sharedFonts"
cp -R "$ROOT/bin/gameProfiles" "$DEST/gameProfiles"
echo "copy-bundle-data.sh: copied data to $DEST"
