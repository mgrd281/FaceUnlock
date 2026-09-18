#!/usr/bin/env bash
#
# Builds a Release archive and exports a Developer ID-signed FaceUnlock.app.
#
# Required environment:
#   DEVELOPMENT_TEAM   Your 10-character Apple Developer Team ID.
#   SIGNING_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)".
#
# Output: build/export/FaceUnlock.app
set -euo pipefail

cd "$(dirname "$0")/.."

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer Team ID}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/FaceUnlock.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
PLIST="$BUILD_DIR/ExportOptions.plist"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${DEVELOPMENT_TEAM}</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>${SIGNING_IDENTITY}</string>
</dict>
</plist>
PLIST_EOF

echo "==> Archiving"
xcodebuild archive \
  -project FaceUnlock.xcodeproj \
  -scheme FaceUnlock \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$PLIST" \
  -exportPath "$EXPORT_DIR"

# ---------------------------------------------------------------- helpers
# The lock-screen feature needs two more binaries: the SecurityAgent mechanism
# and the root broker. They ride inside the app bundle rather than beside it, so
# that one notarised unit carries everything and the installer can never be run
# against a mismatched pair.
#
# Signing order matters. Nested code is signed first and the app is re-signed
# afterwards, because adding anything under Contents/ invalidates the seal the
# export step created. `--deep` is not used: it signs nested code with the outer
# code's options, which is not what Apple wants and hides mistakes.
HELPERS_SRC="Spike/lock-screen-unlock"
HELPERS_DEST="$EXPORT_DIR/FaceUnlock.app/Contents/Library/LockScreenUnlock"

echo "==> Building the lock-screen helpers"
( cd "$HELPERS_SRC" && FACEUNLOCK_SIGN_IDENTITY="$SIGNING_IDENTITY" ./build.sh >/dev/null )

echo "==> Embedding the helpers in the app"
mkdir -p "$HELPERS_DEST"
ditto "$HELPERS_SRC/build/FaceUnlock.bundle" "$HELPERS_DEST/FaceUnlock.bundle"
ditto "$HELPERS_SRC/build/faceunlockd" "$HELPERS_DEST/faceunlockd"
for script in install.sh uninstall.sh compose-rule.py; do
    ditto "$HELPERS_SRC/$script" "$HELPERS_DEST/$script"
done
chmod +x "$HELPERS_DEST"/*.sh "$HELPERS_DEST/compose-rule.py"

echo "==> Signing the helpers with a secure timestamp"
codesign --force --options runtime --timestamp \
    -i de.faceunlock.daemon --sign "$SIGNING_IDENTITY" "$HELPERS_DEST/faceunlockd"
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" "$HELPERS_DEST/FaceUnlock.bundle"

echo "==> Re-signing the app around the embedded helpers"
codesign --force --options runtime --timestamp \
    --entitlements Config/FaceUnlock.entitlements \
    --sign "$SIGNING_IDENTITY" "$EXPORT_DIR/FaceUnlock.app"

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$EXPORT_DIR/FaceUnlock.app"
# A missing timestamp passes codesign but fails notarisation, so it is checked
# here rather than discovered twenty minutes later.
#
# The output is captured before being matched rather than piped into `grep -q`:
# under `set -o pipefail`, grep exits at the first match and closes the pipe,
# codesign dies of SIGPIPE, and the pipeline reports failure for a binary that
# was signed perfectly well.
require_timestamp() {
    local description
    description="$(codesign --display --verbose=4 "$1" 2>&1)"
    case "$description" in
        *"Timestamp="*) ;;
        *) echo "No secure timestamp on $1" >&2; exit 1 ;;
    esac
}

for nested in "$HELPERS_DEST/faceunlockd" "$HELPERS_DEST/FaceUnlock.bundle"; do
    codesign --verify --strict --verbose=2 "$nested"
    require_timestamp "$nested"
done
require_timestamp "$EXPORT_DIR/FaceUnlock.app"
codesign --display --entitlements - "$EXPORT_DIR/FaceUnlock.app"

echo "==> Done: $EXPORT_DIR/FaceUnlock.app"
