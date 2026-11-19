#!/bin/bash
# Builds Tattle.app and wraps it in a .dmg for sharing.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" scripts/Info.plist)
STAGE=build/dmg
DMG="build/Tattle-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Tattle.app "$STAGE/Tattle.app"
ln -s /Applications "$STAGE/Applications"
cp "docs/Read me first.txt" "$STAGE/Read me first.txt"
hdiutil create -volname "Tattle" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created $DMG"
