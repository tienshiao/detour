#!/bin/bash
# Sign a built Detour.app for Developer ID distribution, with its provisioning
# profile embedded so the app has an application identifier.
#
# Usage:
#   ./scripts/sign-app.sh path/to/Detour.app
#   ./scripts/sign-app.sh --check     # only check the profile, identity and entitlements
#
# Environment:
#   DETOUR_PROVISIONING_PROFILE   the Developer ID profile for com.detourbrowser.mac
#                                 (default: signing/Detour_Developer_ID.provisionprofile)
#
# Why the profile: AuthenticationServices refuses WebAuthn (security keys and
# passkeys) from a process without an application identifier, and only a
# provisioning profile can grant com.apple.application-identifier to a
# Developer ID app (TASK-313).
#
# Why not `codesign --deep --entitlements`: it stamps the app's entitlements on
# every nested binary. Sparkle's Autoupdate, Updater.app and XPC services would
# then claim Detour's application identifier with no profile of their own, and
# macOS refuses to launch them, which breaks updates. Nested code is signed
# first, following Sparkle's own recipe; only the app gets Detour's entitlements.

set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
    CHECK_ONLY=1
    APP_PATH=""
else
    APP_PATH="${1:?usage: sign-app.sh path/to/Detour.app | --check}"
    # A relative path is the caller's, so resolve it before moving to the repo root.
    case "$APP_PATH" in /*) ;; *) APP_PATH="$PWD/$APP_PATH" ;; esac
fi
cd "$(dirname "$0")/.."

BUNDLE_ID="com.detourbrowser.mac"
TEAM_ID="58MN2R524R"
SIGN_IDENTITY="Developer ID Application: Tienshiao Ma (${TEAM_ID})"
ENTITLEMENTS_SOURCE="Detour/Resources/Detour.entitlements"
PROFILE="${DETOUR_PROVISIONING_PROFILE:-signing/Detour_Developer_ID.provisionprofile}"

fail() { echo "ERROR: $*" >&2; exit 1; }

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/detour-sign.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }

# --- Check the profile ---

[ -f "$PROFILE" ] || fail "No provisioning profile at $PROFILE.
  Create one at developer.apple.com > Certificates, Identifiers & Profiles > Profiles > +:
  Distribution > Developer ID, App ID $BUNDLE_ID, the Developer ID Application certificate.
  Save it as $PROFILE or point DETOUR_PROVISIONING_PROFILE at it."

PROFILE_PLIST="$WORK_DIR/profile.plist"
security cms -D -i "$PROFILE" > "$PROFILE_PLIST" 2>/dev/null || fail "$PROFILE is not a provisioning profile"

APP_ID=$(pb "Entitlements:com.apple.application-identifier" "$PROFILE_PLIST") || fail "the profile grants no application identifier"
APP_ID_PREFIX=${APP_ID%%.*}
[ "$APP_ID" = "${APP_ID_PREFIX}.${BUNDLE_ID}" ] \
    || fail "the profile is for $APP_ID, not ${BUNDLE_ID} (an explicit App ID is required, not a wildcard)"
[ "$(pb "Entitlements:com.apple.developer.team-identifier" "$PROFILE_PLIST")" = "$TEAM_ID" ] \
    || fail "the profile belongs to another team than $TEAM_ID"
[ "$(pb ProvisionsAllDevices "$PROFILE_PLIST")" = "true" ] \
    || fail "the profile is not a Developer ID profile (it is limited to listed devices)"

# ISO 8601 in UTC, so the parse depends on neither the locale nor the time zone.
EXPIRY=$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null) || fail "the profile has no expiration date"
EXPIRY_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$EXPIRY" +%s 2>/dev/null) || fail "cannot read the profile's expiration date ($EXPIRY)"
[ "$EXPIRY_EPOCH" -gt "$(date +%s)" ] || fail "the profile expired on $EXPIRY"

# The profile must list the certificate we sign with, or macOS refuses to launch the app.
# Sign by that certificate's hash: with a second identity of the same name in the
# keychain (a renewed certificate), signing by name is ambiguous or picks a
# certificate the profile does not list.
IDENTITY_SHA1S=$(security find-identity -v -p codesigning | awk -v name="\"$SIGN_IDENTITY\"" 'index($0, name) { print $2 }')
[ -n "$IDENTITY_SHA1S" ] || fail "signing identity not found in the keychain: $SIGN_IDENTITY"
SIGN_SHA1=""
i=0
while pb "DeveloperCertificates:$i" "$PROFILE_PLIST" > /dev/null; do
    /usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:$i" "$PROFILE_PLIST" > "$WORK_DIR/cert.der"
    CERT_SHA1=$(openssl x509 -inform DER -in "$WORK_DIR/cert.der" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
    if [ -z "$SIGN_SHA1" ] && grep -qx "$CERT_SHA1" <<< "$IDENTITY_SHA1S"; then
        SIGN_SHA1=$CERT_SHA1
    fi
    i=$((i + 1))
done
[ -n "$SIGN_SHA1" ] || fail "the profile does not include the certificate of any \"$SIGN_IDENTITY\" in the keychain ($(echo $IDENTITY_SHA1S)); regenerate it with that certificate"

echo "    Profile: $(pb Name "$PROFILE_PLIST"), $APP_ID, expires $EXPIRY"

# --- The app's entitlements ---

# Detour.entitlements is written for Xcode, which expands $(AppIdentifierPrefix);
# codesign does not, so expand it here, then add the identity the profile grants.
ENTITLEMENTS="$WORK_DIR/Detour.entitlements"
sed "s/\$(AppIdentifierPrefix)/${APP_ID_PREFIX}./g" "$ENTITLEMENTS_SOURCE" > "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" "$ENTITLEMENTS" > /dev/null
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS" > /dev/null
grep -q '\$(' "$ENTITLEMENTS" && fail "unexpanded build variable left in the entitlements: $(grep '\$(' "$ENTITLEMENTS")"

# Every entitlement value must be one the profile allows (a trailing * in the
# profile is a wildcard), or macOS refuses to launch the app.
python3 - "$ENTITLEMENTS" "$PROFILE_PLIST" <<'PY' || fail "the entitlements ask for more than the profile grants"
import plistlib, sys
wanted = plistlib.load(open(sys.argv[1], "rb"))
granted = plistlib.load(open(sys.argv[2], "rb"))["Entitlements"]
def allowed(value, grant):
    grants = grant if isinstance(grant, list) else [grant]
    return any(g == value or (isinstance(g, str) and g.endswith("*") and isinstance(value, str) and value.startswith(g[:-1])) for g in grants)
# A profile grants the keychain group as keychain-access-groups; the app may
# spell it com.apple.security.keychain-access-groups.
granted_key = {"com.apple.security.keychain-access-groups": "keychain-access-groups"}
bad = []
for key, value in wanted.items():
    if key.startswith("com.apple.security.") and key not in granted_key:
        continue  # sandbox and hardened-runtime entitlements need no profile
    grant = granted.get(granted_key.get(key, key))
    if grant is None:
        bad.append(f"{key} (not in the profile)")
        continue
    for v in value if isinstance(value, list) else [value]:
        if not allowed(v, grant):
            bad.append(f"{key} = {v!r} (profile allows {grant!r})")
for b in bad:
    print("    not granted:", b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY

if [ "$CHECK_ONLY" = 1 ]; then
    echo "    Signing identity: $SIGN_SHA1 (listed in the profile)"
    exit 0
fi

# --- Sign, inside out ---

# Sparkle's helpers are signed with no entitlements at all. Sparkle's own recipe
# keeps Downloader.xpc's, but in the Sparkle artifact they are empty (they
# matter only to a sandboxed app, and Detour is not sandboxed), and keeping
# them would carry over whatever an earlier signing left: an incremental build
# re-signs the previous release's app, whose helpers the old --deep signing gave
# Detour's entitlements. (The artifact's Autoupdate carries an application
# identifier of its own, which a Developer ID signature without a profile must
# not keep either.)
sign_nested() {
    codesign --force --sign "$SIGN_SHA1" --timestamp -o runtime "$1"
}

SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
        [ -e "$xpc" ] && sign_nested "$xpc"
    done
    sign_nested "$SPARKLE/Versions/B/Autoupdate"
    sign_nested "$SPARKLE/Versions/B/Updater.app"
    sign_nested "$SPARKLE"
fi
# Any other framework or dylib a future build adds.
if [ -d "$APP_PATH/Contents/Frameworks" ]; then
    find "$APP_PATH/Contents/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) ! -name Sparkle.framework \
        | while read -r nested; do sign_nested "$nested"; done
fi

# The stdio MCP helper (TASK-228.1): its own signature, without Detour's
# entitlements (it needs none, and must not claim the app's identifier).
HELPER="$APP_PATH/Contents/MacOS/detour-mcp"
[ -f "$HELPER" ] && sign_nested "$HELPER"

cp "$PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"
codesign --force --sign "$SIGN_SHA1" --timestamp -o runtime \
    --entitlements "$ENTITLEMENTS" "$APP_PATH"

# --- Check the result ---

codesign --verify --deep --strict "$APP_PATH" || fail "signature does not verify"
# Read the key itself: the keychain access group is the same string as the
# application identifier, so a plain grep for it would pass without the key.
codesign -d --entitlements - --xml "$APP_PATH" > "$WORK_DIR/signed.entitlements" 2>/dev/null \
    || fail "cannot read the signed app's entitlements"
[ "$(pb com.apple.application-identifier "$WORK_DIR/signed.entitlements")" = "$APP_ID" ] \
    || fail "the signed app does not carry the application identifier $APP_ID"
for nested in "$SPARKLE"/Versions/B/XPCServices/*.xpc "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$HELPER"; do
    [ -e "$nested" ] || continue
    # Captured first: grep -q exiting early under pipefail could SIGPIPE codesign
    # and turn a match into a pass.
    nested_entitlements=$(codesign -d --entitlements - --xml "$nested" 2>/dev/null || true)
    if grep -qE "application-identifier|${BUNDLE_ID//./\\.}" <<< "$nested_entitlements"; then
        fail "$nested carries Detour's entitlements"
    fi
done
echo "    Signature: VALID ($APP_ID, profile embedded, Sparkle signed without Detour's entitlements)"
