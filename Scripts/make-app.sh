#!/bin/bash
# Builds AgilentDMM.app from the Swift package.
#
# Swift Package Manager produces a bare executable; macOS wants an application
# bundle for a proper Dock icon, menu bar and window restoration. This assembles
# one around the built binary.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP="$ROOT/build/AgilentDMM.app"

cd "$ROOT"
echo "Building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product AgilentDMM
swift build -c "$CONFIGURATION" --product agmult-sim

BINARY="$(swift build -c "$CONFIGURATION" --product AgilentDMM --show-bin-path)/AgilentDMM"
SIMULATOR="$(swift build -c "$CONFIGURATION" --product agmult-sim --show-bin-path)/agmult-sim"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/AgilentDMM"
cp "$SIMULATOR" "$APP/Contents/MacOS/agmult-sim"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AgilentDMM</string>
    <key>CFBundleDisplayName</key>
    <string>34401A Multimeter</string>
    <key>CFBundleExecutable</key>
    <string>AgilentDMM</string>
    <key>CFBundleIdentifier</key>
    <string>com.agmult.AgilentDMM</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# An ad-hoc signature is enough to run locally and keeps macOS from complaining
# about a broken bundle after the binaries were copied in.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it with: open '$APP'"
