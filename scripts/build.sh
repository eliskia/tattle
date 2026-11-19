#!/bin/bash
# Builds Tattle.app and (with "install") copies it into /Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."
# Build for both Apple Silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
APP=build/Tattle.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tattle" "$APP/Contents/MacOS/Tattle"
strip -S -x "$APP/Contents/MacOS/Tattle" 2>/dev/null || true
cp scripts/Info.plist "$APP/Contents/Info.plist"
if [ ! -f build/Tattle.icns ]; then
  swiftc scripts/make_icon.swift -o build/make_icon 2>/dev/null
  build/make_icon build/icon_1024.png
  mkdir -p build/Tattle.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out build/Tattle.iconset/icon_${s}x${s}.png >/dev/null
    d=$((s*2)); sips -z $d $d build/icon_1024.png --out build/Tattle.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/Tattle.iconset -o build/Tattle.icns
fi
cp build/Tattle.icns "$APP/Contents/Resources/Tattle.icns"
# Sign with the private "Tattle Local Signing" key when it exists, so macOS keeps Tattle's permissions
# across updates. Without the key, fall back to a plain local signature (permissions reset on every build).
IDENTITY="Tattle Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP" || { echo "Signing with the key failed; using a plain local signature"; codesign --force --sign - "$APP"; }
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
if [ "${1:-}" = "install" ]; then
  pkill -x Tattle 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Tattle >/dev/null || break; sleep 0.3; done
  rm -rf /Applications/Tattle.app
  cp -R "$APP" /Applications/Tattle.app
  open /Applications/Tattle.app || { sleep 2; open /Applications/Tattle.app; }
  echo "Installed and started /Applications/Tattle.app"
fi
