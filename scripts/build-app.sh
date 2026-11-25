#!/bin/bash
# Builds "build/Kanarie.app" as a universal binary.
#   scripts/build-app.sh [version]
# CODESIGN_IDENTITY selects the signing identity. The default "-" is an ad-hoc signature for local use.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="build/Kanarie.app"
[[ -f findings/index.json ]] || { echo "findings/index.json is missing: run scripts/sign-findings.sh" >&2; exit 1; }

BUILD=(swift build -c release --arch arm64 --arch x86_64)
"${BUILD[@]}"
PRODUCTS="$("${BUILD[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$PRODUCTS/Kanarie" "$APP/Contents/MacOS/"
# SwiftPM links without telling the linker which SDK it used, so the binary names the deployment target as its SDK
# and macOS draws the app in that older look, with a toolbar that does not line up with the sidebar.
# The minimum stays what the compiler wrote. Each value on a line of its own, so a command that fails stops the build.
BINARY="$APP/Contents/MacOS/Kanarie"
MINIMUM="$(xcrun vtool -show-build "$BINARY" | awk '$1 == "minos" { print $2; exit }')"
SDK="$(xcrun --sdk "${SDKROOT:-macosx}" --show-sdk-version)"
[[ -n "$MINIMUM" && -n "$SDK" ]] || { echo "Could not read the minimum macOS version or the SDK version." >&2; exit 1; }
xcrun vtool -set-build-version macos "$MINIMUM" "$SDK" -replace -output "$BINARY" "$BINARY"
WRITTEN="$(xcrun vtool -show-build "$BINARY")"
# Every architecture of the universal binary.
awk -v sdk="$SDK" '$1 == "sdk" { n++; if ($2 != sdk) bad = 1 } END { exit !(n > 0 && !bad) }' <<< "$WRITTEN" || { echo "The SDK version was not written into the binary." >&2; exit 1; }
cp -R "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R findings "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Hardened runtime needs a real identity: with an ad-hoc signature, library validation would refuse to load Sparkle.
if [[ "$IDENTITY" == "-" ]]; then OPTIONS=(--timestamp=none); else OPTIONS=(--options runtime --timestamp); fi
sign() { codesign --force --sign "$IDENTITY" "${OPTIONS[@]}" "$@"; }

# Sparkle's helpers are signed inside out, in the order its documentation gives. Never use --deep.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign "$APP"

codesign --verify --strict --deep "$APP"
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Kanarie"))"
