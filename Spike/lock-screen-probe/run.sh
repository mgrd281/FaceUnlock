#!/usr/bin/env bash
# Builds and runs the lock-screen camera probe. Nothing is installed and no
# administrator rights are needed; Ctrl-C stops it and prints the verdict.
set -euo pipefail
cd "$(dirname "$0")"

# A custom toolchain in ~/Library/Developer/Toolchains takes precedence over
# Xcode's own, and a stale one fails to load its libraries. Compile with
# Xcode's toolchain explicitly rather than with whatever `swiftc` resolves to.
unset TOOLCHAINS
DEVELOPER_DIR_PATH="$(xcode-select --print-path 2>/dev/null || true)"
XCODE_SWIFTC="${DEVELOPER_DIR_PATH}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
if [ -x "$XCODE_SWIFTC" ]; then
    SWIFTC="$XCODE_SWIFTC"
else
    SWIFTC="$(xcrun --find swiftc)"
fi

# Invoked directly, swiftc has no SDK and fails with "unable to load standard
# library". SDKROOT points it at the SDK inside the selected Xcode.
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT

echo "Building with $SWIFTC"
"$SWIFTC" -target "$(uname -m)-apple-macos14.0" -sdk "$SDKROOT" -O -o lock-probe main.swift
echo
exec ./lock-probe
