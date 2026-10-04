#!/bin/bash
# Deploy a signed Release build of Detour to /Applications for 1Password testing.
# Usage:
#   ./scripts/deploy-1password-test.sh          # build, sign, deploy, launch
#   ./scripts/deploy-1password-test.sh --log    # also stream 1PW-DEBUG logs after launch

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="Detour"
CONFIG="Release"
BUNDLE_ID="com.detourbrowser.mac"
SIGN_IDENTITY="Developer ID Application: Tienshiao Ma (58MN2R524R)"
ENTITLEMENTS="Detour/Resources/Detour.entitlements"
DEST="/Applications/Detour.app"

# The products directory of the build that just ran, asked of xcodebuild itself.
# Never glob DerivedData for it: a machine with several checkouts or worktrees
# has several Detour-* directories, and the first match can be another
# checkout's stale build.
built_products_dir() {
    xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = / && !found { print $2; found = 1 }' || true
}

find_app_path() {
    local app
    app="$(built_products_dir)/Detour.app"
    if [ -f "$app/Contents/Info.plist" ]; then
        bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist" 2>/dev/null || true)
        if [ "$bid" = "$BUNDLE_ID" ]; then
            echo "$app"
        fi
    fi
}

echo "==> Generating Xcode project..."
xcodegen generate 2>&1 | tail -1

echo "==> Building $SCHEME ($CONFIG)..."
xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" build 2>&1 | tail -3

APP_PATH=$(find_app_path)
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find the $CONFIG Detour.app (bundle ID $BUNDLE_ID) in this checkout's build products"
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
    echo "==> Streaming 1PW-DEBUG logs and extension console output (Ctrl+C to stop)..."
    echo "    Extension console text shows as <private> unless you opted in before launch:"
    echo "    defaults write com.detourbrowser.mac ExtensionConsoleLogPublic -bool YES"
    echo "    (revert with: defaults delete com.detourbrowser.mac ExtensionConsoleLogPublic)"
    echo ""
    log stream --process Detour --predicate 'composedMessage CONTAINS "1PW-DEBUG" OR category == "extension-polyfill" OR category == "EXT-LOAD"'
fi
