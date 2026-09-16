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

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$EXPORT_DIR/FaceUnlock.app"
codesign --display --entitlements - "$EXPORT_DIR/FaceUnlock.app"

echo "==> Done: $EXPORT_DIR/FaceUnlock.app"
