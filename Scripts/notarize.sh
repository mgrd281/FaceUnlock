#!/usr/bin/env bash
#
# Notarises and staples an already-signed FaceUnlock.app (or a .dmg).
#
# Required environment — one of:
#   NOTARY_PROFILE                              A keychain profile created with
#                                               `xcrun notarytool store-credentials`.
#   APPLE_ID + TEAM_ID + APP_SPECIFIC_PASSWORD  Direct credentials.
#
# Usage: Scripts/notarize.sh build/export/FaceUnlock.app
set -euo pipefail

TARGET="${1:-build/export/FaceUnlock.app}"
[ -e "$TARGET" ] || { echo "No such path: $TARGET" >&2; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${APPLE_ID:?Set NOTARY_PROFILE, or APPLE_ID/TEAM_ID/APP_SPECIFIC_PASSWORD}"
  : "${TEAM_ID:?Set TEAM_ID}"
  : "${APP_SPECIFIC_PASSWORD:?Set APP_SPECIFIC_PASSWORD}"
  AUTH=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_SPECIFIC_PASSWORD")
fi

case "$TARGET" in
  *.app)
    UPLOAD="$(dirname "$TARGET")/$(basename "$TARGET" .app)-notarize.zip"
    echo "==> Zipping for submission"
    # ditto preserves the bundle structure and extended attributes; `zip` does not.
    ditto -c -k --keepParent "$TARGET" "$UPLOAD"
    ;;
  *)
    UPLOAD="$TARGET"
    ;;
esac

echo "==> Submitting to the notary service"
xcrun notarytool submit "$UPLOAD" "${AUTH[@]}" --wait

echo "==> Stapling"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$TARGET" || \
  spctl --assess --type open --context context:primary-signature --verbose=4 "$TARGET"

echo "==> Notarised: $TARGET"
