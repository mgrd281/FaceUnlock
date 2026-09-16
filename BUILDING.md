# Building FaceUnlock

## Requirements

- macOS 14.0 or later
- Xcode 16.0 or later — the project uses synchronized file-system groups
  (`objectVersion = 77`), so Xcode 15 cannot open it
- Swift 6.0 language mode (set in the project, not per-file)
- No package manager, no Homebrew, no Python, no external dependency of any kind

## Build and test

```sh
git clone https://github.com/mgrd281/FaceUnlock.git
cd FaceUnlock

xcodebuild -project FaceUnlock.xcodeproj -scheme FaceUnlock -configuration Debug build
xcodebuild -project FaceUnlock.xcodeproj -scheme FaceUnlock -configuration Debug test
```

Or open `FaceUnlock.xcodeproj` and press ⌘R / ⌘U.

The project signs ad-hoc (`CODE_SIGN_IDENTITY = "-"`) out of the box, so it
builds and runs locally without a developer account. Signing settings for
distribution are supplied on the command line by the release script rather than
being baked into the project.

### Running the tests

The unit tests need no camera, no Keychain and no lock screen: every collaborator
is behind a protocol with an in-memory or stub implementation, and descriptors are
synthesised with a known angular relationship. They exercise matching and
calibration policy, profile storage and encryption, the recognition state machine,
lock-event delivery, the lock-screen verification matrix, unlock provider
selection, the liveness heuristics against synthetic live/photo/replay/frozen
sequences, preference clamping, and the diagnostics privacy boundary.

### Adding or removing source files

Do not edit `project.pbxproj`. The app and test targets use
`PBXFileSystemSynchronizedRootGroup`, so any `.swift` file placed under
`FaceUnlock/` or `FaceUnlockTests/` is picked up automatically on the next build.

`Config/Info.plist` and `Config/FaceUnlock.entitlements` live *outside* those
directories on purpose: they are referenced by the `INFOPLIST_FILE` and
`CODE_SIGN_ENTITLEMENTS` build settings, and keeping them out of the synchronized
group stops Xcode from also copying them in as bundle resources.

### Syntax checking without Xcode

`Scripts/syntax-check.sh` runs `swiftc -frontend -parse` over every Swift file.
It validates syntax only — it does not type-check and does not resolve imports —
so it is a smoke test for environments without Xcode, never a substitute for
`xcodebuild build`.

```sh
SWIFTC=/path/to/swiftc ./Scripts/syntax-check.sh
```

## Producing a signed .app

You need an Apple Developer account and a **Developer ID Application**
certificate in your login keychain. FaceUnlock cannot ship on the Mac App Store —
it is not sandboxed, for the reasons in
[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md#9-not-sandboxed-and-therefore-not-a-mac-app-store-app).

```sh
export DEVELOPMENT_TEAM="ABCDE12345"
export SIGNING_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"

./Scripts/build-release.sh
```

This archives, exports with the `developer-id` method, and verifies the result.
The output is `build/export/FaceUnlock.app`.

Check the identity you have with:

```sh
security find-identity -v -p codesigning
```

The Hardened Runtime is enabled in the project, which is required for
notarisation. `com.apple.security.device.camera` is in the entitlements because
the Hardened Runtime requires it for camera access even outside the sandbox.

## Notarising

First store credentials once, so no password ends up in your shell history:

```sh
xcrun notarytool store-credentials "faceunlock-notary" \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "app-specific-password"
```

Then:

```sh
export NOTARY_PROFILE="faceunlock-notary"
./Scripts/notarize.sh build/export/FaceUnlock.app
```

The script zips the bundle with `ditto` (which preserves the bundle structure and
extended attributes, unlike `zip`), submits it, waits for the result, staples the
ticket and re-validates it, then runs a Gatekeeper assessment.

If notarisation is rejected, read the log rather than guessing:

```sh
xcrun notarytool log <submission-id> --keychain-profile "faceunlock-notary"
```

The usual causes are a missing Hardened Runtime, a missing secure timestamp, or a
nested binary that was not signed with the same identity.

## Creating a distributable DMG

```sh
export SIGNING_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"
./Scripts/make-dmg.sh build/export/FaceUnlock.app
```

This stages the app with an `/Applications` symlink and the user-facing
documents, builds a compressed UDZO image named after the app's version, and
signs the image when `SIGNING_IDENTITY` is set.

Notarise the DMG as well, so Gatekeeper trusts the container a user actually
downloads:

```sh
./Scripts/notarize.sh build/FaceUnlock-1.0.0.dmg
```

### Verifying what a user will see

```sh
spctl --assess --type open --context context:primary-signature -v FaceUnlock-1.0.0.dmg
xcrun stapler validate FaceUnlock-1.0.0.dmg
```

## Full release sequence

```sh
export DEVELOPMENT_TEAM="ABCDE12345"
export SIGNING_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"
export NOTARY_PROFILE="faceunlock-notary"

xcodebuild -project FaceUnlock.xcodeproj -scheme FaceUnlock -configuration Debug test
./Scripts/build-release.sh
./Scripts/notarize.sh build/export/FaceUnlock.app
./Scripts/make-dmg.sh build/export/FaceUnlock.app
./Scripts/notarize.sh build/FaceUnlock-1.0.0.dmg
```

## Optional: supplying a Core ML embedding model

FaceUnlock bundles no face-recognition model, because redistributing third-party
weights means honouring each model's licence, which has to be checked per model.
If you have one you are licensed to use, compile it and drop it at:

```
~/Library/Application Support/de.faceunlock.mac/Models/FaceEmbedding.mlmodelc
```

It must take a 160×160 BGRA image and return a single `MLMultiArray`. FaceUnlock
detects it at launch, records its identity in the descriptor's `producerVersion`
(file name plus a SHA-256 prefix), and uses it instead of the Vision pipeline.
Because the `producerVersion` changes, **you must re-enrol** — profiles are never
matched across pipelines.

To bundle one instead, add it to `FaceUnlock/Resources/` and it will be picked up
by the synchronized group automatically.
