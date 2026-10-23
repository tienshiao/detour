#!/bin/bash
# Publish a release that build-release.sh has built: Sparkle appcast, git tag,
# GitHub release, the update server, and the website.
#
# Usage:
#   ./scripts/build-release.sh 1.2.3       # first: version bump, signed + notarized DMG
#   ./scripts/publish-release.sh           # then: publish the version in Info.plist
#   ./scripts/publish-release.sh --dry-run # check and prepare build/, publish nothing
#   ./scripts/publish-release.sh --skip-website
#
# Inputs:
#   build/Detour-<version>.dmg     from build-release.sh
#   build/appcast.xml + earlier DMGs, kept in build/ between releases (git-ignored;
#                                  generate_appcast needs the earlier DMGs to make deltas)
#   docs/releases/<version>.md     release notes: a "# " heading, then "- **Title** — text" items
#
# Steps, in order. Each one checks whether it is already done, so a run that
# stopped part way can be run again:
#   1. preflight   the DMG is stapled and holds the version and build in Info.plist
#   2. appcast     release notes -> build/Detour-<version>.html, then generate_appcast
#   3. git         commit Info.plist + notes, tag v<version>, push main and the tag
#   4. github      pre-release v<version> with the DMG (the website's download link)
#   5. updates     DMG, new deltas, then appcast.xml to R2 bucket detour-updates
#                  (served as https://updates.detourbrowser.com/)
#   6. website     ../detour-website: version, links and size; commit, push, wrangler deploy
#
# Needs: gh (logged in), npx (wrangler logged in to the Cloudflare account that
# owns detour-updates: `npx wrangler login`), the Sparkle EdDSA key in the
# keychain, python3. Override wrangler with WRANGLER="..." and the website
# checkout with WEBSITE_DIR=...

set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="Detour/Resources/Info.plist"
BUILD_DIR="build"
BUCKET="detour-updates"
UPDATES_URL="https://updates.detourbrowser.com/"
SITE_URL="https://detourbrowser.com/"
REPO="tienshiao/detour"
WEBSITE_DIR="${WEBSITE_DIR:-../detour-website}"
WRANGLER="${WRANGLER:-npx --yes wrangler@4}"

DRY_RUN=0
SKIP_WEBSITE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --skip-website) SKIP_WEBSITE=1 ;;
        *) echo "Unknown argument: $arg"; exit 2 ;;
    esac
done

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
TAG="v${VERSION}"
DMG_NAME="Detour-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
NOTES_MD="docs/releases/${VERSION}.md"
NOTES_HTML="${BUILD_DIR}/Detour-${VERSION}.html"

step() { echo ""; echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
# Runs a command that changes something outside build/, or only prints it.
run() {
    if [ "$DRY_RUN" = 1 ]; then echo "    [dry run] $*"; else "$@"; fi
}

echo "Publishing Detour ${VERSION} (build ${BUILD})$([ "$DRY_RUN" = 1 ] && echo ' — dry run')"

# --- 1. Preflight ---

step "Preflight"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "releases are cut from main"
dirty=$(git status --porcelain --untracked-files=all | awk '{print $2}' | grep -v -x -e "$PLIST" -e "$NOTES_MD" || true)
[ -z "$dirty" ] || fail "uncommitted changes besides the version bump and notes:"$'\n'"$dirty"
[ -f "$DMG_PATH" ] || fail "$DMG_PATH not found; run ./scripts/build-release.sh first"
[ -f "$NOTES_MD" ] || fail "$NOTES_MD not found; write the release notes first"
for tool in gh npx python3; do command -v "$tool" >/dev/null || fail "$tool not found"; done

xcrun stapler validate "$DMG_PATH" >/dev/null || fail "$DMG_PATH has no stapled notarization ticket"
echo "    Notarization ticket: stapled"

# build-release.sh once signed another checkout's older build; check what's inside.
MOUNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG_PATH" >/dev/null
dmg_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MOUNT/Detour.app/Contents/Info.plist")
dmg_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$MOUNT/Detour.app/Contents/Info.plist")
codesign --verify --deep --strict "$MOUNT/Detour.app" || { hdiutil detach "$MOUNT" >/dev/null; fail "the app in $DMG_PATH fails codesign --verify"; }
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT"
[ "$dmg_version" = "$VERSION" ] && [ "$dmg_build" = "$BUILD" ] \
    || fail "$DMG_PATH holds ${dmg_version} (${dmg_build}), Info.plist says ${VERSION} (${BUILD})"
echo "    DMG app: ${dmg_version} (${dmg_build}), signature valid"

DMG_SIZE=$(stat -f %z "$DMG_PATH")

# --- 2. Appcast ---

step "Appcast"
python3 - "$NOTES_MD" "$NOTES_HTML" <<'EOF'
import html, re, sys
src, dst = sys.argv[1], sys.argv[2]
out, items = [], []
for line in open(src, encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("# "):
        out.append(f"<h2>{html.escape(line[2:].strip())}</h2>")
    elif line.startswith("- "):
        text = html.escape(line[2:].strip(), quote=False)
        items.append("  <li>" + re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text) + "</li>")
    elif line.strip():
        sys.exit(f"{src}: unexpected line (only '# ' and '- ' lines): {line}")
if not out or not items:
    sys.exit(f"{src}: needs a '# ' heading and at least one '- ' item")
out += ["<ul>", *items, "</ul>"]
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
EOF
echo "    Release notes: $NOTES_HTML"

BUILT_PRODUCTS_DIR=$(xcodebuild -scheme Detour -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = / { print $2; exit }')
GENERATE_APPCAST="${BUILT_PRODUCTS_DIR%/Build/Products/*}/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
[ -x "$GENERATE_APPCAST" ] || fail "generate_appcast not found at $GENERATE_APPCAST"

# Re-running is safe: generate_appcast updates the existing item.
"$GENERATE_APPCAST" --download-url-prefix "$UPDATES_URL" --embed-release-notes "$BUILD_DIR/"

# The item generate_appcast wrote must be this release, first in the feed.
python3 - "$BUILD_DIR/appcast.xml" "$VERSION" "$BUILD" "${UPDATES_URL}${DMG_NAME}" "$DMG_SIZE" <<'EOF'
import sys, xml.etree.ElementTree as ET
path, version, build, url, size = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = ET.parse(path).getroot().find("channel/item")
got = (item.findtext("sparkle:shortVersionString", namespaces=ns),
       item.findtext("sparkle:version", namespaces=ns),
       item.find("enclosure").get("url"), item.find("enclosure").get("length"))
if got != (version, build, url, size):
    sys.exit(f"appcast's first item is {got}, expected {(version, build, url, size)}")
if not (item.findtext("description") or "").strip():
    sys.exit("appcast's first item has no release notes")
EOF
DELTAS=()
while IFS= read -r f; do DELTAS+=("$f"); done < <(ls "$BUILD_DIR"/Detour"${BUILD}"-*.delta 2>/dev/null || true)
echo "    appcast.xml: first item is ${VERSION} (${BUILD}), ${#DELTAS[@]} delta(s)"

# --- 3. Git ---

step "Git commit, tag and push"
if [ -n "$(git status --porcelain -- "$PLIST" "$NOTES_MD")" ]; then
    run git add "$PLIST" "$NOTES_MD"
    run git commit -m "Release ${VERSION} (build ${BUILD})"
else
    echo "    Version bump and notes already committed"
fi
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "    Tag ${TAG} exists at $(git rev-parse --short "${TAG}^{commit}")"
else
    run git tag -a "$TAG" -m "$TAG"
fi
run git push origin main "$TAG"

# --- 4. GitHub release ---

step "GitHub release"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "    ${TAG} exists; uploading the DMG again (--clobber)"
    run gh release upload "$TAG" "$DMG_PATH" --repo "$REPO" --clobber
else
    PREV_TAG=$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || git describe --tags --abbrev=0 HEAD^)
    GH_NOTES=$(mktemp)
    { echo "**Full Changelog**: https://github.com/${REPO}/compare/${PREV_TAG}...${TAG}"; echo; grep '^- ' "$NOTES_MD"; } > "$GH_NOTES"
    run gh release create "$TAG" "$DMG_PATH" --repo "$REPO" --prerelease --title "$TAG" --notes-file "$GH_NOTES" --verify-tag
    rm -f "$GH_NOTES"
fi

# --- 5. Update server (Sparkle) ---

step "Upload to R2 bucket ${BUCKET}"
r2_put() {  # <file> <content type>
    run $WRANGLER r2 object put "${BUCKET}/$(basename "$1")" --file "$1" --content-type "$2" --remote
}
r2_put "$DMG_PATH" application/x-diskcopy
for delta in "${DELTAS[@]}"; do r2_put "$delta" application/octet-stream; done
# Last, so the feed never points at a file that isn't there yet.
r2_put "$BUILD_DIR/appcast.xml" text/xml

if [ "$DRY_RUN" = 0 ]; then
    live=$(curl -fsS "${UPDATES_URL}appcast.xml" | grep -m1 -o '<sparkle:shortVersionString>[^<]*' | sed 's/.*>//')
    [ "$live" = "$VERSION" ] || fail "${UPDATES_URL}appcast.xml lists ${live:-nothing} first, expected ${VERSION}"
    live_size=$(curl -fsSI "${UPDATES_URL}${DMG_NAME}" | awk 'tolower($1)=="content-length:" { print $2 }' | tr -d '\r')
    [ "$live_size" = "$DMG_SIZE" ] || fail "${UPDATES_URL}${DMG_NAME} is ${live_size:-missing} bytes, expected ${DMG_SIZE}"
    echo "    Live: appcast lists ${VERSION} first; ${DMG_NAME} is ${DMG_SIZE} bytes"
fi

# --- 6. Website ---

if [ "$SKIP_WEBSITE" = 1 ]; then
    step "Website: skipped"
    exit 0
fi

step "Website (${WEBSITE_DIR})"
[ -d "$WEBSITE_DIR/.git" ] || fail "website checkout not found at $WEBSITE_DIR (set WEBSITE_DIR)"
[ -z "$(git -C "$WEBSITE_DIR" status --porcelain --untracked-files=no)" ] || fail "the website checkout has uncommitted changes"
SIZE_MB=$(python3 -c "print(f'{$DMG_SIZE / 1048576:.2f} MB')")
# Replaces every occurrence of the previous version and size in index.html
# (the schema, version pill, three download links and two size lines) and the
# sitemap's lastmod. Look at the diff it prints if the page has started to
# mention versions elsewhere.
python3 - "$WEBSITE_DIR/public" "$VERSION" "$SIZE_MB" "$DRY_RUN" <<'EOF'
import datetime, json, re, sys
public, version, size, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
index = open(f"{public}/index.html", encoding="utf-8").read()
schema = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', index, re.S).group(1))
old_version, old_size = schema["softwareVersion"], schema["fileSize"]
if old_version == version:
    print(f"    The site already shows {version}")
    sys.exit(0)
new = index.replace(old_version, version).replace(old_size, size)
print(f"    {old_version} -> {version}: {index.count(old_version)} places; {old_size} -> {size}: {index.count(old_size)} places")
sitemap = open(f"{public}/sitemap.xml", encoding="utf-8").read()
sitemap = re.sub(r"<lastmod>[^<]*</lastmod>", f"<lastmod>{datetime.date.today()}</lastmod>", sitemap)
if not dry:
    open(f"{public}/index.html", "w", encoding="utf-8").write(new)
    open(f"{public}/sitemap.xml", "w", encoding="utf-8").write(sitemap)
EOF
if [ -n "$(git -C "$WEBSITE_DIR" status --porcelain --untracked-files=no)" ]; then
    git -C "$WEBSITE_DIR" --no-pager diff --stat
    run git -C "$WEBSITE_DIR" commit -am "Update to ${VERSION}"
fi
run git -C "$WEBSITE_DIR" push origin HEAD

# Deploy the committed tree, not the working copy (which can hold .DS_Store
# files and other strays that would be served).
SITE_EXPORT=$(mktemp -d)
git -C "$WEBSITE_DIR" archive HEAD | tar -x -C "$SITE_EXPORT"
(cd "$SITE_EXPORT" && run $WRANGLER deploy)
rm -rf "$SITE_EXPORT"

if [ "$DRY_RUN" = 0 ]; then
    curl -fsS "$SITE_URL" | grep -q "v${VERSION} · pre-release" \
        || fail "${SITE_URL} does not show v${VERSION} yet (CDN cache?); check by hand"
    echo "    Live: ${SITE_URL} shows v${VERSION}"
fi

echo ""
echo "Published Detour ${VERSION} (build ${BUILD})."
