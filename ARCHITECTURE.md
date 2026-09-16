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
| **Actors** | `RecognitionCoordinator`, `EnrollmentCoordinator`, `UnlockCoordinator`, `PresenceUnlockProvider`, `AccessibilityUnlockProvider`, `ManualConfirmationUnlockProvider` | Everything that owns mutable state a race could corrupt: the attempt state machine, the in-flight-unlock flag, the power assertion. |
| **Queue-confined class** | `CameraManager` | Almost nothing in AVFoundation is `Sendable`. Making the capture session actor state would force non-`Sendable` values across every isolation hop; confining them all to one serial queue keeps them on a single thread — which AVFoundation wants anyway — and makes the `@unchecked Sendable` conformance a real, checkable invariant. |
| **`@MainActor`** | `AppEnvironment`, `Preferences`, `OnboardingModel`, `WindowPresenter`, `AppDelegate`, all SwiftUI views | UI state, `UserDefaults` mirroring, AppKit window handling. |
| **Value types** | `RecognitionStateMachine`, all models | No identity, no sharing, trivially `Sendable`. |
| **`@unchecked Sendable`** | `CameraFrame`, `PreviewImage`, `RecognitionProgress`, `FaceDetector`, `FaceQualityAnalyzer`, `LivenessAnalyzer`, the lock-protected stubs | Each one wraps either an immutable Core Foundation / Core Graphics object that is uniquely owned by one consumer, or mutable state guarded by an `NSLock`. Every occurrence carries a comment saying which. |

Background `@Sendable` closures never reach into main-actor state. Where one
needs a value that lives on the main actor, the value is mirrored into an
`Atomic` box or read from `UserDefaults`, which is thread-safe. Calling
`MainActor.assumeIsolated` from a genuinely background context would trap, so it
appears only inside `DispatchQueue.main.async`, where the assumption is true by
construction.

Two places deliberately hop to the main actor because AppKit lives there:
`SecurityValidator.verifyLockScreen()` reads the frontmost application's bundle
identifier and pid — and returns only those two `Sendable` values, never the
`NSRunningApplication` — and `LockStateMonitor` registers and removes its
`NSWorkspace` observers there.

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

### Head pose comes from the landmarks, not from the observation

`VNFaceObservation.yaw` is quantised to steps of π/4. The only values it ever
reports are 0, ±0.785 and ±1.57, so any rule of the form "turn slightly — between
0.2 and 0.6 rad" is unsatisfiable: a slight turn reads as 0 and the first non-zero
reading is already an extreme pose. `LandmarkPoseEstimator` derives a continuous
estimate from the nose tip's offset relative to the eye midpoint (after removing
in-plane roll from the eye line), and `FaceDetector` substitutes it whenever
landmarks resolved. Enrolment compares it only against the same person's own
straight-ahead baseline, so the estimate's absolute scale never matters.

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

## The notch panel

`NotchPanelController` owns one borderless `NSPanel` that hangs from the top
edge of the screen, flush with the camera housing on Macs that have one
(`NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea` give its geometry; on other
Macs it hangs from the top edge). It is black with rounded bottom corners, forced
to the dark appearance, and tinted green.

One panel, one occupant at a time, with a priority order: the setup assistant and
the recognition test are foreground clients the user opened deliberately; the
recognition overlay (`RecognitionOverlayView`, driven by `AppEnvironment` from
status changes) is a background client that only fills the panel when it is
otherwise unused and can never displace the others.

Because the lock screen and screen saver cover every user-session window, the
overlay is in practice visible during a recognition test, during the pre-lock
presence check, and for the two seconds after a successful unlock.

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
