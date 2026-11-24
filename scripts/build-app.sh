#!/bin/bash
# Builds "build/App Checker.app" as a universal binary.
#   scripts/build-app.sh [version]
# CODESIGN_IDENTITY selects the signing identity. The default "-" is an ad-hoc signature for local use.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="build/App Checker.app"
[[ -f rules.json ]] || { echo "rules.json is missing" >&2; exit 1; }

BUILD=(swift build -c release --arch arm64 --arch x86_64)
"${BUILD[@]}"
PRODUCTS="$("${BUILD[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$PRODUCTS/AppChecker" "$APP/Contents/MacOS/"
cp -R "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/"
cp rules.json Resources/AppIcon.icns "$APP/Contents/Resources/"
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
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/AppChecker"))"
