#!/usr/bin/env bash
#
# Builds a distributable, signed DMG from an exported FaceUnlock.app.
#
# Usage: Scripts/make-dmg.sh [path/to/FaceUnlock.app]
# Optional environment:
#   SIGNING_IDENTITY   Signs the DMG itself, so Gatekeeper trusts the container too.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-build/export/FaceUnlock.app}"
[ -d "$APP" ] || { echo "No app at $APP — run Scripts/build-release.sh first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGING="build/dmg-staging"
DMG="build/FaceUnlock.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"

echo "==> Staging"
ditto "$APP" "$STAGING/FaceUnlock.app"
ln -s /Applications "$STAGING/Applications"
cp README.md SECURITY.md PRIVACY.md KNOWN_LIMITATIONS.md "$STAGING/" 2>/dev/null || true

echo "==> Creating the disk image"
hdiutil create \
  -volname "FaceUnlock $VERSION" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG"

if [ -n "${SIGNING_IDENTITY:-}" ]; then
  echo "==> Signing the disk image"
  codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi

rm -rf "$STAGING"
echo "==> Done: $DMG"
echo "    Notarise it with: Scripts/notarize.sh $DMG"
