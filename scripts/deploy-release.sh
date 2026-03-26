#!/bin/bash
# Deploy a signed Release build of Detour to /Applications for 1Password testing.
# Usage:
#   ./scripts/deploy-release.sh          # build, sign, deploy, launch
#   ./scripts/deploy-release.sh --log    # also stream 1PW-DEBUG logs after launch

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="Detour"
CONFIG="Release"
BUNDLE_ID="com.detourbrowser.mac"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
SIGN_IDENTITY="Developer ID Application: Tienshiao Ma (58MN2R524R)"
ENTITLEMENTS="Detour/Resources/Detour.entitlements"
DEST="/Applications/Detour.app"

find_app_path() {
    for d in "$DERIVED_DATA"/Detour-*/Build/Products/$CONFIG/Detour.app; do
        if [ -f "$d/Contents/Info.plist" ]; then
            bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$d/Contents/Info.plist" 2>/dev/null || true)
            if [ "$bid" = "$BUNDLE_ID" ]; then
                echo "$d"
                return
            fi
        fi
    done
}

echo "==> Generating Xcode project..."
xcodegen generate 2>&1 | tail -1

echo "==> Building $SCHEME ($CONFIG)..."
xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" build 2>&1 | tail -3

APP_PATH=$(find_app_path)
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find Detour.app with bundle ID $BUNDLE_ID"
    exit 1
fi

echo "==> Signing: $APP_PATH"
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp -o runtime --entitlements "$ENTITLEMENTS" "$APP_PATH"
codesign -v "$APP_PATH" && echo "    Signature: VALID" || { echo "    Signature: FAILED"; exit 1; }

echo "==> Deploying to $DEST"
killall Detour 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP_PATH" "$DEST"

echo "==> Launching..."
open "$DEST"

echo ""
echo "Done. Detour is running from $DEST"

if [ "${1:-}" = "--log" ]; then
    echo ""
    echo "==> Streaming 1PW-DEBUG logs (Ctrl+C to stop)..."
    echo ""
    log stream --process Detour --predicate 'composedMessage CONTAINS "1PW-DEBUG"'
fi
