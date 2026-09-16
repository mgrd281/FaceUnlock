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

One consequence: an ad-hoc build has no application identifier, so macOS
refuses it the data-protection keychain (`errSecMissingEntitlement`, −34018).
FaceUnlock detects this at launch and stores its secrets in the login keychain
instead (see SECURITY.md); Diagnostics shows which one is in use. To get the
data-protection keychain in a Debug build, select your team under
Signing & Capabilities — a free personal team is enough.

### Running the tests

The unit tests need no camera, no Keychain and no lock screen: every collaborator
is behind a protocol with an in-memory or stub implementation, and descriptors are
synthesised with a known angular relationship. They exercise:

- matching and calibration policy (`FaceMatcherTests`),
- profile storage, encryption and corruption handling
  (`BiometricProfileStoreTests`, `KeychainServiceTests`),
- the recognition state machine (`RecognitionStateMachineTests`),
- the whole coordinator end to end against a fake camera, detector, matcher and
  unlock chain (`RecognitionCoordinatorTests`, `PipelineFakes.swift`),
- lock-event delivery (`LockStateMonitorTests`),
- the lock-screen verification matrix and every provider's refusal behaviour
  (`SecurityValidationTests`),
- unlock provider selection and rate limiting (`UnlockCoordinatorTests`),
- the liveness heuristics against synthetic live / photo / screen-replay / frozen
  sequences (`LivenessAnalyzerTests`),
- the pixel statistics the quality gate rests on (`ImageAnalysisTests`),
- credential validation and removal (`CredentialStoreTests`),
- preference clamping and the diagnostics privacy boundary
  (`PreferencesAndDiagnosticsTests`).

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

Two further heuristics catch compiler errors that are slow to diagnose by hand:

```sh
python3 Scripts/check-viewbuilder-limits.py    # SwiftUI's ten-child ViewBuilder limit
python3 Scripts/check-weak-self-captures.py    # concurrent closures reading an unbound [weak self]
python3 Scripts/check-noasync-locks.py         # blocking noasync APIs called from an async context
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

## The Core ML embedding model

`FaceUnlock/Resources/FaceDescriptorModel.mlpackage` is committed to the
repository and picked up by the synchronized group; Xcode compiles it to
`FaceDescriptorModel.mlmodelc` inside the app bundle. `COREML_CODEGEN_LANGUAGE`
is set to `None` because the app loads the model by URL rather than through a
generated class. Provenance, licence and SHA-256 are in `MODEL.md`.

To rebuild the package from the upstream weights:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install --index-url https://download.pytorch.org/whl/cpu torch
pip install coremltools facenet-pytorch numpy pillow
python3 Scripts/convert-face-model.py
```

To try a different model without rebuilding, compile it and drop it at:

```
~/Library/Application Support/de.faceunlock.mac/Models/FaceDescriptorModel.mlmodelc
```

It must take a 160×160 RGB image and return a single `MLMultiArray`. Changing
the model changes the `producerVersion` stored in every descriptor, so **you
must re-enrol** — profiles are never matched across pipelines, and the app
tells you so at launch.
