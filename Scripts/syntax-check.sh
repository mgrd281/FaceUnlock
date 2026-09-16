#!/usr/bin/env bash
# Parse-only syntax check for every Swift file in the project.
#
# This is a stop-gap for environments without Xcode: `swiftc -frontend -parse`
# validates Swift syntax without resolving imports, so it catches syntax errors
# but not type errors. On macOS, use `xcodebuild build` instead.
set -uo pipefail
SWIFTC="${SWIFTC:-swiftc}"
status=0
while IFS= read -r file; do
  if ! out=$("$SWIFTC" -frontend -parse -swift-version 6 "$file" 2>&1); then
    echo "=== $file"
    echo "$out"
    status=1
  fi
done < <(find FaceUnlock FaceUnlockTests -name '*.swift' 2>/dev/null | sort)
exit $status
