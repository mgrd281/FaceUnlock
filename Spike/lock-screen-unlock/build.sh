#!/usr/bin/env bash
# Builds the three stage-0 artefacts into build/. Nothing is installed and no
# administrator rights are needed; install.sh is a separate, deliberate step.
#
#   ./build.sh
#
# Signing: ad-hoc by default, which is enough for everything except
# distribution. Set FACEUNLOCK_SIGN_IDENTITY to a Developer ID identity for a
# real build. Note that an ad-hoc signature's code requirement pins the cdhash,
# so every rebuild changes it — re-run install.sh after each build or the broker
# will refuse its own peers.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${FACEUNLOCK_SIGN_IDENTITY:--}"

# A custom toolchain in ~/Library/Developer/Toolchains takes precedence over
# Xcode's own, and a stale one fails to load its libraries. Same reasoning as
# Spike/lock-screen-probe/run.sh.
unset TOOLCHAINS
DEVELOPER_DIR_PATH="$(xcode-select --print-path 2>/dev/null || true)"
XCODE_SWIFTC="${DEVELOPER_DIR_PATH}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
if [ -x "$XCODE_SWIFTC" ]; then SWIFTC="$XCODE_SWIFTC"; else SWIFTC="$(xcrun --find swiftc)"; fi

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
TARGET="$(uname -m)-apple-macos14.0"

rm -rf build && mkdir -p build

echo "==> Broker (faceunlockd)"
"$SWIFTC" -swift-version 5 -target "$TARGET" -sdk "$SDKROOT" \
    -import-objc-header Shared/FaceUnlockBrokerProtocol.h \
    -O -o build/faceunlockd Broker/main.swift

echo "==> Mechanism (FaceUnlock.bundle)"
BUNDLE="build/FaceUnlock.bundle"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Plugin/Info.plist "$BUNDLE/Contents/Info.plist"
xcrun clang -bundle -fobjc-arc -fmodules -Wall -Wextra -Werror \
    -isysroot "$SDKROOT" -target "$TARGET" -I Shared -O2 \
    -framework Foundation -framework CoreFoundation -framework Security \
    -o "$BUNDLE/Contents/MacOS/FaceUnlock" Plugin/FaceUnlockMechanism.m

echo "==> Stage-0 client (authprobe)"
"$SWIFTC" -swift-version 5 -target "$TARGET" -sdk "$SDKROOT" \
    -O -o build/authprobe Probe/authprobe.swift

echo "==> Signing with identity: $IDENTITY"
# The hardened runtime matches what the reference plugin on this Mac ships with
# and what notarisation will require later.
codesign --force --options runtime --timestamp=none \
    -i de.faceunlock.daemon --sign "$IDENTITY" build/faceunlockd
codesign --force --options runtime --timestamp=none \
    --sign "$IDENTITY" "$BUNDLE"
codesign --force -i de.faceunlock.probe.client --sign "$IDENTITY" build/authprobe

echo
echo "Built:"
echo "  build/faceunlockd        the root broker"
echo "  build/FaceUnlock.bundle  the authorization mechanism"
echo "  build/authprobe          stage-0 client"
echo
echo "Next: sudo ./install.sh        (stage 0 — the lock screen is not touched)"
