# Architecture

## Layout

```
FaceUnlock/
  App/          FaceUnlockApp, AppDelegate, AppEnvironment (composition root)
  Models/       AppStatus, BiometricProfile, FaceEmbedding, RecognitionSettings,
                FaceQuality, FacePose, FaceUnlockError, DiagnosticsSnapshot
  Logging/      AppLogger — one os.Logger per category
  Security/     KeychainService, EncryptionService, BiometricProfileStore,
                CredentialStore, SecurityValidator, LocalAuthenticationService
  System/       PermissionManager, LoginItemManager, SystemCompatibility,
                Preferences, SystemSettingsLinks, Atomic
  Camera/       CameraManager, CameraDevice, CameraFrame, CameraPreview,
                PreviewRenderer
  Recognition/  FaceDetector, FaceQualityAnalyzer, FaceAligner,
                FaceGeometryDescriptor, FaceEmbeddingService, FaceMatcher,
                LivenessAnalyzer, LivenessSample, GrayscaleGrid,
                RecognitionStateMachine, RecognitionCoordinator,
                EnrollmentCoordinator
  Unlock/       LockStateMonitor, UnlockProvider, PresenceUnlockProvider,
                AccessibilityUnlockProvider, ManualConfirmationUnlockProvider,
                UnlockCoordinator, SessionLocker
  Update/       UpdateChecker — the only component allowed to use the network
  UI/           MenuBar, Onboarding, Settings, Recognition, Diagnostics, Components
  Resources/    Assets.xcassets
Config/         Info.plist, FaceUnlock.entitlements
FaceUnlockTests/
```

## Dependency rule

`AppEnvironment` is the only place that constructs anything. Everything below it
receives its collaborators through protocols (`CameraManaging`, `FaceDetecting`,
`FaceEmbeddingProviding`, `FaceMatching`, `LivenessAnalyzing`,
`BiometricProfileStoring`, `KeychainServicing`, `CredentialStoring`,
`SecurityValidating`, `LockStateMonitoring`, `UnlockProvider`,
`PermissionManaging`, `LoginItemManaging`, `LocalAuthenticating`,
`UpdateChecking`). There are no singletons in the app's own code, which is why
the whole recognition and unlock stack can be exercised in tests without a
camera, a lock screen or a Keychain.

Every protocol ships with a stub or in-memory implementation in the same file, so
a test double is never further away than the type it stands in for.

## Concurrency model

Swift 6 language mode, strict concurrency.

| Kind | Types | Why |
|---|---|---|
| **Actors** | `CameraManager`, `RecognitionCoordinator`, `EnrollmentCoordinator`, `UnlockCoordinator`, `PresenceUnlockProvider`, `AccessibilityUnlockProvider`, `ManualConfirmationUnlockProvider` | Everything that owns mutable state a race could corrupt: the capture session, the attempt state machine, the in-flight-unlock flag, the power assertion. |
| **`@MainActor`** | `AppEnvironment`, `Preferences`, `OnboardingModel`, `WindowPresenter`, `AppDelegate`, all SwiftUI views | UI state, `UserDefaults` mirroring, AppKit window handling. |
| **Value types** | `RecognitionStateMachine`, all models | No identity, no sharing, trivially `Sendable`. |
| **`@unchecked Sendable`** | `CameraFrame`, `PreviewImage`, `RecognitionProgress`, `FaceDetector`, `FaceQualityAnalyzer`, `LivenessAnalyzer`, the lock-protected stubs | Each one wraps either an immutable Core Foundation / Core Graphics object that is uniquely owned by one consumer, or mutable state guarded by an `NSLock`. Every occurrence carries a comment saying which. |

Background `@Sendable` closures never reach into main-actor state. Where one
needs a value that lives on the main actor, the value is mirrored into an
`Atomic` box or read from `UserDefaults`, which is thread-safe. Using
`MainActor.assumeIsolated` from a background context would trap, so it is not
used.

## State machine

`RecognitionStateMachine` is a plain `struct` with no dependencies, owned by
`RecognitionCoordinator` and mutated nowhere else. It maps
`RecognitionEvent` → `AppStatus` under these rules:

- Structural preconditions outrank activity. A missing profile, a missing
  permission or an unavailable camera always wins, so the UI can never show
  "monitoring" when there is nothing to match against.
- `paused` absorbs every activity event until `resumed`.
- `unlockStarted` is only reachable from `recognized`.
- `unlocked` and `rejected` are terminal for one attempt and are cleared by
  `attemptFinished`, which is posted after a short delay so the menu-bar icon and
  the animation have time to show the outcome.

The full transition table is covered by `RecognitionStateMachineTests`.

## Recognition data flow

```
AVCaptureVideoDataOutput
  └─ FrameDelegate            throttles to the configured fps on the capture queue
      └─ AsyncStream<CameraFrame>
          └─ RecognitionCoordinator (actor)
              ├─ FaceDetector           VNDetectFaceLandmarksRequest (76 points)
              ├─ FaceQualityAnalyzer    48×48 GrayscaleGrid → luminance, sharpness, motion
              ├─ LivenessSampleBuilder  → LivenessSample → LivenessAnalyzer
              ├─ FaceAligner            eye-line alignment → 160×160 BGRA crop
              ├─ FaceEmbeddingProviding VNGenerateImageFeaturePrint + geometry
              ├─ FaceMatcher            top-k mean similarity vs. BiometricProfile
              └─ UnlockCoordinator      safest provider that can act
```

Cost is spent in increasing order: quality gating is the cheapest stage and runs
first, so a blurry or empty frame never reaches the feature-print request.

## Descriptor design

Apple ships no public face-recognition embedding API. Three options were weighed:

1. **`VNGenerateImageFeaturePrintRequest`** — public, on-device, Neural Engine
   accelerated, nothing to bundle and no licence to honour. It is a
   general-purpose visual descriptor, so it is more sensitive to lighting and
   background than a purpose-trained face network, and needs a tightly aligned
   crop plus a per-user calibrated threshold.
2. **A bundled third-party Core ML face network** — stronger for identity, but
   redistribution licences differ per model and would each have to be audited.
3. **Training a network** — out of scope.

Option 1 was chosen as the default, paired with an explicit
**geometric descriptor**: the pairwise distances between twelve stable landmark
centroids, normalised by inter-ocular distance. That half is invariant to
brightness and scale and carries identity information the general descriptor is
weak on. The two halves are L2-normalised separately, then weighted 0.72 / 0.28
and concatenated, so neither can drown out the other.

Option 2 is supported but not shipped: if a compiled `FaceEmbedding.mlmodelc` is
found in the app bundle or in
`~/Library/Application Support/de.faceunlock.mac/Models/`, it is used instead,
and its identity (file name plus a SHA-256 prefix of the compiled model) becomes
part of the descriptor's `producerVersion`. Because `producerVersion` is stored
with every descriptor and checked before scoring, a profile enrolled with one
pipeline can never be matched against descriptors from another — the mismatch is
an honest rejection, not a meaningless number.

## Unlock provider chain

`UnlockCoordinator` sorts providers by `safetyRank` and uses the first one that
reports it can act on the current session state. There is no scoring and no user
preference that can promote a less safe provider.

| Rank | Provider | Capability | What it does |
|---|---|---|---|
| 0 | `PresenceUnlockProvider` | `supported` | Declares user activity and holds a `PreventUserIdleDisplaySleep` assertion while you are recognised, so the idle lock never happens. Refuses once the session is locked. |
| 50 | `AccessibilityUnlockProvider` | `limited` / `unsupported` | Opt-in. Verifies the lock state, console ownership, Accessibility trust, that the frontmost process satisfies `anchor apple and identifier "com.apple.loginwindow"`, and that no secure input context is active — then, and only then, sets the secure field's value and performs its confirm action. On current macOS the secure-input check fails and it refuses. |
| 100 | `ManualConfirmationUnlockProvider` | `limited` | Posts a notification saying you were recognised, and leaves the final step to macOS. |

`SessionUnlockCapability` (`supported` / `limited` / `unsupported`) is reported
honestly throughout the UI. Nothing claims `supported` for a workflow macOS does
not permit.

## Power behaviour

- The `AVCaptureSession` is created on demand and fully torn down in `stop()` —
  inputs and outputs removed, delegate cleared. There is no idling session.
- Frames are throttled in the capture callback, before any work is done, so a
  dropped frame costs one timestamp comparison.
- Capture runs at 640×480 and at 6 fps for unlock monitoring (12 fps during
  enrolment, where the user is present and waiting).
- `alwaysDiscardsLateVideoFrames` prevents queue growth.
- Retries are event-driven — screen wake, system wake, screen-saver stop — never
  polled.
- The camera is released *before* the unlock provider runs, not after.

## Logging

One `os.Logger` per category: `AppLifecycle`, `Camera`, `Recognition`,
`Liveness`, `Permissions`, `Unlock`, `Security`, `Keychain`, `Update`. Values
that are safe to read in a log are marked `privacy: .public` explicitly; the
password, any descriptor, any image and any Keychain payload are never passed to
a logger at all, not even as private data.
