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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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

# The application icon, if there is one to build it from.
#
# The artwork is deliberately not in the repository: drop a square icon.png in
# the root and it is picked up, leave it out and the app gets the generic icon.
# Every size macOS wants is a downscale of that one file, and iconutil needs all
# ten — the Finder picks by size, and a missing one is a blank icon at exactly
# that size rather than an obvious failure.
ICON_SOURCE="$ROOT/icon.png"
if [[ -f "$ICON_SOURCE" ]]; then
    echo "Building the icon…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_SOURCE" \
            --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" "$ICON_SOURCE" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil --convert icns "$ICONSET" --output "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
else
    echo "No icon.png in the repository root — the app gets the generic icon."
fi

# App Intents metadata — what makes the intents in Intents.swift visible to
# Shortcuts, Spotlight and Siri.
#
# Xcode generates this from a build phase that Swift Package Manager has no
# equivalent of, so the two steps it does are done by hand here: the compiler
# writes out the compile-time constants of every type conforming to an App
# Intents protocol, and appintentsmetadataprocessor turns those into the
# Metadata.appintents bundle the system reads. Both tools ship inside Xcode
# rather than the command line tools, so a machine without it still gets a
# working app — just one Shortcuts cannot see.
TOOLCHAIN="$(xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain"
PROTOCOLS_SOURCE="$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json"
PROCESSOR="$TOOLCHAIN/usr/bin/appintentsmetadataprocessor"

if [[ -x "$PROCESSOR" && -f "$PROTOCOLS_SOURCE" ]]; then
    echo "Extracting App Intents metadata…"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT

    # The compiler wants a bare array of protocol names; the toolchain ships the
    # same list wrapped in an object with a version alongside it.
    /usr/bin/python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["constValueProtocols"], open(sys.argv[2], "w"))' \
        "$PROTOCOLS_SOURCE" "$WORK/protocols.json"

    MODULE_SOURCES=("$ROOT"/Sources/AgilentDMMKit/*.swift)
    OTHER_SOURCES=()
    for source in "${MODULE_SOURCES[@]}"; do
        [[ "$source" == *"/Intents.swift" ]] || OTHER_SOURCES+=("$source")
    done

    # One frontend job over the module with Intents.swift as the primary file.
    # Constants are gathered per primary file, and that is the only file with
    # anything to gather.
    "$TOOLCHAIN/usr/bin/swiftc" -frontend -c \
        -primary-file "$ROOT/Sources/AgilentDMMKit/Intents.swift" "${OTHER_SOURCES[@]}" \
        -o "$WORK/Intents.o" \
        -module-name AgilentDMMKit -swift-version 5 \
        -sdk "$(xcrun --show-sdk-path)" \
        -target "$(uname -m)-apple-macos14.0" \
        -I "$(dirname "$BINARY")/Modules" \
        -plugin-path "$TOOLCHAIN/usr/lib/swift/host/plugins" \
        -const-gather-protocols-file "$WORK/protocols.json" \
        -emit-const-values-path "$WORK/Intents.swiftconstvalues" \
        >/dev/null 2>&1

    if [[ -f "$WORK/Intents.swiftconstvalues" ]]; then
        printf '%s\n' "${MODULE_SOURCES[@]}" > "$WORK/sources.txt"
        echo "$WORK/Intents.swiftconstvalues" > "$WORK/constvals.txt"

        "$PROCESSOR" \
            --output "$APP/Contents/Resources" \
            --toolchain-dir "$TOOLCHAIN" \
            --module-name AgilentDMMKit \
            --sdk-root "$(xcrun --show-sdk-path)" \
            --xcode-version "$(xcodebuild -version | tail -1 | awk '{print $3}')" \
            --platform-family macOS \
            --deployment-target 14.0 \
            --target-triple "$(uname -m)-apple-macos14.0" \
            --source-file-list "$WORK/sources.txt" \
            --swift-const-vals-list "$WORK/constvals.txt" \
            --force
    else
        echo "  skipped: the compiler produced no constant values"
    fi
else
    echo "App Intents metadata skipped — needs a full Xcode, not just the command line tools."
    echo "  The app works; Shortcuts will not list its actions."
fi

# An ad-hoc signature is enough to run locally and keeps macOS from complaining
# about a broken bundle after the binaries were copied in. It goes last: the
# metadata bundle above is part of what gets signed.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it with: open '$APP'"
