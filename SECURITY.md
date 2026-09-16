# Security

## Summary

FaceUnlock is a convenience layer on top of macOS authentication. It never
replaces it, never weakens it, and never claims a security property it does not
have.

It is **not** equivalent to Apple's Face ID. Face ID matches against a depth map
produced by a dedicated infrared dot projector and camera, the template lives in
the Secure Enclave, and the match is performed there. FaceUnlock uses an ordinary
2D webcam, a descriptor computed in user space, and software liveness
heuristics. Anyone deciding whether FaceUnlock is appropriate for their threat
model should start from that difference.

---

## Threat model

### In scope

| Threat | Mitigation | Residual risk |
|---|---|---|
| **Photo spoofing** — a printed or on-screen still held to the camera | Liveness requires evidence across frames: a blink, natural pose variation, micro-motion inside a plausible band, and parallax (the nose/eye distance ratio must change as the head rotates, which a flat image does not do). | A photo attached to a rig that produces plausible motion could raise some signals, but not parallax or blink. |
| **Video replay** on a phone or tablet | On top of the above, the texture signal penalises the regular high-frequency structure a display panel's pixel grid adds. | **Realistic bypass.** A high-quality recording played on a large, matte, colour-accurate display at the right scale can satisfy every passive signal. Use `alwaysChallenge` liveness if this is in your threat model, and understand that a recorded blink defeats that too. |
| **Another person who resembles the enrolled user** | Per-user calibrated threshold that can only ever be stricter than the preset floor; the score is the mean of the best three enrolled samples, not the single best; several consecutive frames must match. | Identical twins and very close siblings are a genuine risk. The descriptor is a metric-learned 2-D face network (`MODEL.md`) without depth or infrared, so it cannot separate people who genuinely look alike the way Face ID's structured-light sensor can. |
| **Stale or replayed camera frames** | Hard disqualifier: three byte-identical consecutive frames, a non-advancing frame sequence number, or non-advancing timestamps abort the attempt with no score computed. | An attacker able to inject frames into the capture pipeline already has code execution in the session. |
| **Password leakage** | The password is stored only in the Keychain (`kSecClassGenericPassword`, data-protection keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`). It is never written to `UserDefaults`, a plist, a file, a log, an environment variable, or a diagnostics export. It is never rendered back on screen after saving. The in-memory `Data` is zeroed after use. | Swift `String` may retain an internal copy beyond the zeroing window; this narrows the exposure but cannot eliminate it. Anything with debugger access to the process can read it. |
| **Accidental password injection into the wrong window** | Five independent preconditions must all hold, and are re-checked immediately before the write: screen locked, this session owns the console, Accessibility trust granted, the frontmost process satisfies the code requirement `anchor apple and identifier "com.apple.loginwindow"`, and no secure input context is active. A bundle identifier alone is never trusted. Screen-coordinate clicking is never used. | None known; the provider refuses rather than degrading. |
| **Credential logging** | The password, descriptors, images and Keychain payloads are never passed to any logger, not even marked private. | — |
| **A malicious app impersonating the lock window** | The cryptographic code requirement above. `SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` against an Apple anchor. | — |
| **Corrupted or tampered enrolment data** | The profile is AES-GCM sealed, so tampering fails authentication and is reported as corruption. `BiometricProfile.isStructurallyValid` additionally rejects empty embedding sets, mismatched pose-tag counts, non-comparable descriptors, and thresholds outside `(0.5, 1]` — a truncated or edited template cannot lower the effective threshold. | — |
| **Unauthorised FaceUnlock settings changes or re-enrolment** | Sensitive actions (re-enrol, change or remove the saved password, forget the profile) go through `LAContext.deviceOwnerAuthentication` — Touch ID, Apple Watch, or the account password. Deliberately *not* FaceUnlock's own recognition, so a spoofed face can never authorise changes to FaceUnlock. | Off if the user disables "Protect FaceUnlock settings". |
| **Local filesystem inspection** | The profile is AES-GCM ciphertext under a 256-bit key in the Keychain, in a `0700` directory with `0600` permissions. Copying the file without the Keychain yields nothing. | Anything running as the user while the Mac is unlocked can ask the Keychain for the key. |
| **Hand-edited preferences** | `RecognitionSettings.sanitized()` clamps every numeric setting to a safe range on load. Thresholds are never in `UserDefaults` at all — they live inside the encrypted profile. | — |
| **Runaway unlock attempts** | `UnlockCoordinator` permits one attempt at a time and enforces a minimum interval between attempts. | — |

### Out of scope

- An attacker with root, with code execution as the user, or with a debugger
  attached to the process.
- Hardware attacks, and anything below the OS.
- Coercion.

---

## Credential storage

Nothing is stored outside the Keychain. The complete set of items is enumerated
in one place (`KeychainItem`) so that every write is auditable from a single
file:

| Item | Contents | When it exists |
|---|---|---|
| `profile-encryption-key` | 256-bit AES key | Created on first enrolment; destroyed by "Forget my face" |
| `account-password` | macOS account password | Only if the user explicitly saves one |
| `settings-master-password` | Optional FaceUnlock master password | Only if the user sets one |

All three use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
`kSecAttrSynchronizable = false`, and are stored in the data-protection keychain
(`kSecUseDataProtectionKeychain`).

The data-protection keychain is only open to code with an application
identifier — a build signed with a development team or a Developer ID. An
**ad-hoc signed build** (Xcode with no team selected, as in a fresh clone) gets
`errSecMissingEntitlement` (−34018) on every call. `KeychainService` probes
this once at launch and, only then, uses the user's **login keychain** instead:
still the Keychain, still encrypted at rest and ACL-bound to the app, but
without the per-item accessibility class. The fallback is logged, shown as
"Keychain: login keychain (ad-hoc build)" in Diagnostics, and never chosen for
any other error. Release builds are Developer ID-signed and never hit it; to
get the data-protection keychain in Debug, select your team under
Signing & Capabilities.

Before a password is stored it is verified against the system directory with
`ODRecord.verifyPassword` — the same public OpenDirectory mechanism `dscl` uses.
Note that failed verifications count towards the account's password policy
exactly as they would at the login window, which is why the app validates only
when Save is pressed, never on each keystroke.

## Biometric storage

`BiometricProfile` contains only what is needed to match a face or to explain the
profile to its owner: a version, two timestamps, the descriptors, their pose
tags, the calibrated threshold, the metric, the liveness configuration, and the
preset it was calibrated for. There is no name, no account identifier, no device
identifier, and no imagery.

A descriptor is not reversible into a photograph, but it is still biometric data,
so it is treated as a secret: AES-GCM encrypted at rest under a Keychain-held
key.

"Forget my face" overwrites the ciphertext, unlinks it, removes any enrolment
scratch directory, and **destroys the encryption key**. On APFS, overwriting a
file does not guarantee the old blocks are gone — destroying the key is what
actually makes any remaining ciphertext unrecoverable, and the two are always
done together.

## Liveness limitations

Stated plainly, because a false sense of security is worse than none:

- There is **no depth sensing**. Everything is inferred from a 2D image
  sequence.
- The texture signal is a heuristic. A high-resolution matte display can defeat
  it.
- The parallax signal needs the head to actually rotate. If you hold perfectly
  still it returns a neutral value rather than a pass, but it also cannot then
  prove anything.
- The blink signal can be satisfied by a recording of you blinking.
- Active challenges raise the bar but do not close it: a sufficiently prepared
  attacker with video of you blinking and turning your head can satisfy them.
- No single signal can carry the score. The weights are chosen so that at least
  three independent signals must agree before even the most permissive preset's
  floor is reached — this is asserted by `LivenessAnalyzerTests`.

**Recommendation:** treat FaceUnlock as a convenience comparable to a short
screen-lock grace period, not as a replacement for a strong password or Touch ID
on a machine holding sensitive data.

## macOS permission model

FaceUnlock works entirely inside TCC and the standard permission model:

- **Camera** — requested via `AVCaptureDevice.requestAccess(for: .video)`. macOS
  shows its own prompt, using `NSCameraUsageDescription` verbatim. One prompt
  only; after that the app links to System Settings.
- **Accessibility** — `AXIsProcessTrustedWithOptions` can only *ask*; macOS
  grants it in System Settings and nowhere else. FaceUnlock never attempts to
  write to the TCC database, never restarts itself to re-trigger a prompt, and
  never treats a denial as retryable.
- **Hardened Runtime** is enabled. The App Sandbox is not, because the
  Accessibility API, OpenDirectory verification and launching `/usr/bin/pmset`
  are incompatible with it; that is why FaceUnlock is distributed with a
  Developer ID signature and notarisation rather than through the Mac App Store.
  This is recorded with its reasoning in `Config/FaceUnlock.entitlements`.

## FaceUnlock versus Face ID

| | Face ID | FaceUnlock |
|---|---|---|
| Sensor | Infrared dot projector + IR camera, depth map | Ordinary 2D camera |
| Template storage | Secure Enclave | AES-GCM file, key in the Keychain |
| Matching | Inside the Secure Enclave | In the app's user-space process |
| Liveness | Hardware-assisted, attention detection | Software heuristics across frames |
| Apple's stated false-accept rate | ~1 in 1,000,000 | Not comparable; not measured, and not claimed |
| Can unlock the login window | Yes | **No** — see below |

## FileVault and reboot

- **FileVault pre-boot authentication is never touched.** It happens before the
  operating system that FaceUnlock runs on exists. There is no mechanism, public
  or otherwise, by which this app could participate in it, and it does not try.
- **After a restart or a logout,** normal macOS authentication is required.
  FaceUnlock is not running at that point.
- **At the login window** (a different user, or fast user switching), FaceUnlock
  is not in the session and does nothing.
- **A locked session** is the only state FaceUnlock engages with at all, and even
  there the automated path is refused by macOS. See
  [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).

## Reporting a vulnerability

Open an issue describing the impact and the steps to reproduce. Please do not
include credentials, biometric data or diagnostics containing either — the
built-in "Export Diagnostics" is designed to contain neither.
