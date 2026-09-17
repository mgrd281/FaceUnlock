#!/usr/bin/env bash
# Build and launch FaceUnlock from the command line, with no Xcode window and
# no per-target settings to click through. Run it again after every `git pull`;
# the command never changes.
#
#   ./Scripts/run-local.sh            build and run
#   ./Scripts/run-local.sh --logs     build, run, then stream the app's log
#
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA="build/local"
APP="$DERIVED_DATA/Build/Products/Debug/FaceUnlock.app"

echo "==> Stopping any running copy"
killall FaceUnlock 2>/dev/null || true

echo "==> Building (this takes a minute the first time)"
xcodebuild \
    -project FaceUnlock.xcodeproj \
    -scheme FaceUnlock \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    build

echo "==> Launching $APP"
open "$APP"

if [ "${1:-}" = "--logs" ]; then
    echo
    echo "==> Streaming the app's log. Ctrl-C to stop."
    echo "    Keychain lines are what matter for the storage problem."
    log stream --style compact --predicate 'subsystem == "de.faceunlock.mac"'
fi
