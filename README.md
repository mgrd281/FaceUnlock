# FaceUnlock

A native macOS menu-bar app that recognises you with your Mac's built-in camera,
entirely on-device, and uses that to make unlocking your session less tedious.

FaceUnlock is an original implementation. It uses no third-party trademarks,
icons, models, assets or branding.

---

## What FaceUnlock is

- A **menu-bar utility** (SwiftUI, Swift 6) that watches for session-lock events.
- A **local face-recognition pipeline**: AVFoundation → Vision face detection →
  quality gating → aligned crop → on-device descriptor → matching against your
  enrolled profile → multi-frame liveness analysis.
- A **presence keeper**: when your Mac starts to go idle, it spends a few seconds
  of camera time checking whether you are still there, and resets the idle timer
  if you are — so the lock never happens in the first place.
- An **honest reporter**: where macOS does not allow something, FaceUnlock says
  so in plain words instead of pretending.

## What FaceUnlock is not

**It is not Face ID.** Face ID authenticates against a depth map produced by
dedicated infrared hardware and is anchored in the Secure Enclave. A Mac's camera
is a plain 2D sensor. FaceUnlock's spoof resistance comes from software
heuristics alone and is meaningfully weaker. It raises the cost of the easy
attacks; it does not make them impossible. See [SECURITY.md](SECURITY.md).

**It does not weaken macOS.** No SIP change, no TCC bypass, no Gatekeeper
change, no private API, no FileVault involvement, no privileged helper, no kext.
After a restart or a logout, macOS authentication is required exactly as before,
and FileVault pre-boot authentication is untouched. See
[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).

---

## Requirements

| | |
|---|---|
| macOS | 14.0 (Sonoma) or later |
| Hardware | Apple silicon recommended (M1 and newer); Intel Macs work with higher CPU use |
| Camera | Built-in camera; an external or Continuity camera is used if there is no built-in one |
| Xcode | 16.0 or later (the project uses synchronized file groups, `objectVersion` 77) |
| Swift | 6.0 language mode |

---

## How to build

```sh
xcodebuild -project FaceUnlock.xcodeproj -scheme FaceUnlock -configuration Debug build
xcodebuild -project FaceUnlock.xcodeproj -scheme FaceUnlock -configuration Debug test
```

Full instructions, including signing, notarisation and building a DMG, are in
[BUILDING.md](BUILDING.md).

---

## How enrolment works

The setup assistant walks through six guided head positions — straight ahead,
slightly left, slightly right, slightly up, slightly down, and a neutral
expression — capturing three accepted samples each.

A frame is only accepted when it passes the quality gate: exactly one face, large
enough in frame, adequately lit, sharp, unoccluded, not moving too fast, and
within the pose tolerance for the current step. Near-duplicate samples within one
step are rejected, so three copies of a single instant cannot pass as three
samples.

Each accepted frame becomes a **descriptor** — a fixed-length vector — and the
frame is then discarded. **No photograph is ever written to disk.** The resulting
profile is encrypted with AES-GCM under a 256-bit key held in the Keychain and
written to
`~/Library/Application Support/de.faceunlock.mac/profile.bin` with `0600`
permissions.

Enrolment is followed by a **calibration** pass: live frames are matched against
the fresh descriptors to measure how tightly your own scores cluster, and your
personal threshold is derived from that. Calibration can only make recognition
*stricter* than the preset you chose — never more permissive.

## How recognition works

1. Either the screen saver starts (the grace period before the session locks) or
   the session locks outright. After a short configurable delay, the camera starts.
2. Each frame is detected, quality-gated, aligned and turned into a descriptor.
3. The descriptor is compared against every enrolled sample. The score is the
   mean of the best three similarities, not the single best — one lucky frame or
   one over-general enrolment sample must not be enough.
4. A configurable number of *consecutive* matching frames is required.
5. In parallel, the liveness analyser accumulates evidence across frames: blink,
   natural head movement, micro-motion in the right band, absence of display-panel
   texture, and the parallax a real 3D head shows when it rotates.
6. If, and only if, both the match and the liveness thresholds are met, the
   camera is stopped and the safest available unlock provider runs. Before the
   lock that is the presence provider, which resets the idle timer; after it, the
   manual provider, which tells you that you were recognised.
7. If nothing is found before the timeout, the camera stops and FaceUnlock waits
   for the next wake event rather than polling.

There is **virtually no sustained CPU use while idle**: the capture session is
not merely paused between attempts, it is torn down, so the camera indicator is
off and nothing is being processed.

---

## Permissions

| Permission | Required? | Why |
|---|---|---|
| **Camera** | Yes | To see your face. Requested through `AVCaptureDevice`; macOS shows its own prompt. |
| **Accessibility** | No — optional | Used only by the opt-in assisted lock-screen provider, which current macOS refuses anyway. FaceUnlock works fully without it. |
| **Notifications** | No — optional | Only to tell you that you were recognised when macOS requires you to finish the unlock yourself. |
| **Login item** | No — optional | `SMAppService.mainApp.register()` for "Open FaceUnlock at login". |

FaceUnlock never asks for a permission it is not about to use, and never
re-prompts: once macOS has recorded your answer, the app sends you to System
Settings instead of nagging.

---

## Privacy

- Camera frames are analysed in memory and discarded. None are written to disk.
- Recognition runs on-device (Vision / Core ML, Neural Engine where available).
- No biometric data, password or telemetry ever leaves the Mac.
- No cloud account, no face database, no advertising or analytics SDK is linked
  into the app at all.
- The only network request FaceUnlock can make is an optional, unauthenticated
  update check that is **off by default** and carries no identifier.
- "Forget my face" destroys the profile *and* its encryption key.

Full details in [PRIVACY.md](PRIVACY.md).

---

## Limitations

The short version — the full list is in
[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md):

- **Automatic lock-screen unlock is not possible with public APIs.** macOS puts
  the lock-screen password field into a secure input context that no application
  can type into, and `loginwindow`'s accessibility tree is not available to apps
  in your session. FaceUnlock implements the interaction properly, verifies every
  precondition, and refuses when they are not met. It does not fake success.
- What FaceUnlock *can* do without touching any security boundary: keep the
  session from locking while you are present, lock it when you leave (respecting
  your own grace-period setting), and confirm at the lock screen that it
  recognised you so you can finish with Touch ID or your password.
- FileVault pre-boot authentication, the login window after restart or logout,
  and fast-user-switching are all out of reach by design.
- A high-quality video replay on a large matte display remains a realistic
  bypass of the liveness heuristics.

---

## Documentation

| Document | Contents |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Module layout, concurrency model, state machine, data flow |
| [SECURITY.md](SECURITY.md) | Threat model, storage, liveness limits, the macOS permission model |
| [PRIVACY.md](PRIVACY.md) | What is stored, where, and what leaves the Mac |
| [BUILDING.md](BUILDING.md) | Build, sign, notarise, package |
| [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) | Every restriction, and what was done instead |

## Licence

MIT. See [LICENSE](LICENSE).
