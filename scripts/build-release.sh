#!/bin/bash
# Build a signed, notarized, DMG-packaged release of Detour.
#
# Usage:
#   ./scripts/build-release.sh 1.2.3    # set version, increment build number, build release
#   ./scripts/build-release.sh          # use current version from Info.plist
#
# Prerequisites (one-time setup):
#
#   1. Store notarization credentials:
#      xcrun notarytool store-credentials "detour-notary" \
#          --apple-id "YOUR_APPLE_ID" \
#          --team-id "58MN2R524R" \
#          --password "APP_SPECIFIC_PASSWORD"
#
#   2. Generate Sparkle EdDSA signing key:
#      # After resolving SPM packages, run:
#      ~/Library/Developer/Xcode/DerivedData/Detour-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
#      # Copy the public key into Info.plist as SUPublicEDKey

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="Detour"
CONFIG="Release"
BUNDLE_ID="com.detourbrowser.mac"
SIGN_IDENTITY="Developer ID Application: Tienshiao Ma (58MN2R524R)"
ENTITLEMENTS="Detour/Resources/Detour.entitlements"
NOTARY_PROFILE="detour-notary"
PLIST="Detour/Resources/Info.plist"
BUILD_DIR="build"

# --- Parse version ---

if [ -n "${1:-}" ]; then
    VERSION="$1"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
    BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
    BUILD=$((BUILD + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
    BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
fi

DMG_NAME="Detour-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

echo "==> Building Detour v${VERSION} (build ${BUILD})"

# --- Generate Xcode project ---

echo "==> Generating Xcode project..."
xcodegen generate 2>&1 | tail -1

# --- Build ---

echo "==> Building ${SCHEME} (${CONFIG})..."
xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" clean build 2>&1 | tail -5

# --- Find built app ---

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

APP_PATH=$(find_app_path)
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find the $CONFIG Detour.app (bundle ID $BUNDLE_ID) in this checkout's build products"
    exit 1
fi
echo "    Found: $APP_PATH"

# --- Code sign ---

echo "==> Signing..."
codesign --force --deep --sign "$SIGN_IDENTITY" \
    --timestamp -o runtime \
    --entitlements "$ENTITLEMENTS" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH" && echo "    Signature: VALID" || { echo "    Signature: FAILED"; exit 1; }

# --- Create DMG ---

echo "==> Creating DMG..."
DMG_STAGE="${BUILD_DIR}/dmg-stage"
rm -rf "$DMG_STAGE" "$DMG_PATH"
mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create -volname "Detour" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG_PATH"
rm -rf "$DMG_STAGE"
echo "    Created: $DMG_PATH"

# --- Notarize ---

echo "==> Submitting for notarization..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

# --- Done ---

echo ""
echo "========================================="
echo "  Release artifact: $DMG_PATH"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Generate/update appcast:"
echo "     ${APP_PATH%/Build/Products/*}/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast ${BUILD_DIR}/"
echo ""
echo "  2. Upload ${DMG_NAME} and appcast.xml to GitHub Releases"
