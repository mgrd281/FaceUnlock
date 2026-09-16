# Known limitations

Every restriction below is a consequence of macOS security working as designed.
FaceUnlock does not attempt to defeat any of them. Where a capability is
unavailable, this document states the restriction, then what FaceUnlock does
instead.

---

## 1. Automatic lock-screen unlock is not possible with public APIs

**The restriction.** Two independent mechanisms block it, and either alone would
be sufficient:

- **Secure event input.** When `loginwindow`'s password field has focus, macOS
  enables a secure input context. This exists specifically to prevent any other
  process from delivering synthetic keystrokes to that field. It is enforced by
  the window server, not by TCC, so no permission grants an exception.
- **Accessibility isolation.** The lock screen belongs to `loginwindow`, running
  in a different security context. Accessibility trust granted to an app in your
  session does not extend to it; its accessibility tree is either empty or not
  writable from your session.

**What FaceUnlock does.** `AccessibilityUnlockProvider` implements the
interaction properly rather than approximating it — it locates the field by its
`AXSecureTextField` subrole through a bounded breadth-first walk, sets its value
through the accessibility API, and performs the field's own confirm action. It
never clicks at screen coordinates and never synthesises a Return keystroke.
Before doing any of that it requires five preconditions to hold, re-checked
immediately before the write:

1. the screen is genuinely locked,
2. this session owns the console,
3. Accessibility trust is granted,
4. the frontmost process satisfies the code requirement
   `anchor apple and identifier "com.apple.loginwindow"` — a bundle identifier
   alone is never trusted,
5. no secure input context is active.

On current macOS, condition 5 fails, so the provider refuses and reports exactly
why. The password is never read from the Keychain on a refused attempt.

**What FaceUnlock does instead.** `ManualConfirmationUnlockProvider` posts a
notification saying you were recognised, and leaves the final step to macOS —
Touch ID on Macs that have it, otherwise your password. The capability is
reported as `limited` throughout the UI. FaceUnlock does not describe this as an
unlock.

## 2. The genuinely supported workflow is presence, not unlocking

**What works fully, with public APIs and no special permission.**
`PresenceUnlockProvider` declares user activity
(`IOPMAssertionDeclareUserActivity`) and holds a
`PreventUserIdleDisplaySleep` assertion while it can see you, so the Mac does not
reach the idle lock in the first place. The assertion carries a timeout and is
released the moment you are no longer recognised, when FaceUnlock is paused, and
when it quits — at which point macOS resumes exactly the behaviour you
configured.

**Its limit.** It cannot act on a session that is already locked, and it says so
rather than trying.

## 3. Locking on absence respects your settings, and cannot shorten them

macOS has no public API that locks a session directly. The optional "lock this
Mac when I am no longer there" feature runs `/usr/bin/pmset displaysleepnow`;
macOS then locks according to *your* "Require password after screen saver begins
or display is turned off" setting. If you chose a five-minute grace period,
FaceUnlock does not shorten it. The feature is off by default.

## 4. FileVault pre-boot authentication is untouchable, and untouched

FileVault authentication happens before macOS — and therefore before FaceUnlock —
exists. There is no public or private mechanism by which a normal application
could participate, and FaceUnlock does not try.

## 5. After a restart or a logout, macOS authentication is required

FaceUnlock is not running at the login window. It cannot be, and it is not
designed to be. Only a *locked session* of an already-logged-in user is in scope.

## 6. Fast user switching

When the session resigns active, FaceUnlock releases the camera immediately and
does nothing until the session becomes active again. It never operates in another
user's session.

## 7. The descriptor is not a purpose-trained face network

The default pipeline is `VNGenerateImageFeaturePrintRequest` — a general-purpose
image descriptor — combined with a landmark-geometry descriptor. This is public,
on-device, requires no bundled model and carries no licence obligations, but it
is less discriminative than a metric-learned face embedding. It is compensated
for with tight alignment, a per-user calibrated threshold, top-k aggregation and
a consecutive-frame requirement, but the underlying limit remains.

**Mitigation available to you.** Drop a compiled Core ML face embedding model at
`~/Library/Application Support/de.faceunlock.mac/Models/FaceEmbedding.mlmodelc`
(160×160 BGRA input, single `MLMultiArray` output) and FaceUnlock uses it
instead. No model is bundled, because redistributing third-party weights means
honouring each model's licence, which has to be checked per model rather than
assumed. Changing the model changes the stored `producerVersion`, so you must
re-enrol; profiles are never matched across pipelines.

## 8. Liveness is software-only

No depth sensor means no hardware-backed liveness. A high-quality video replay on
a large matte display remains a realistic bypass. Identical twins are a genuine
risk. See the residual-risk column in [SECURITY.md](SECURITY.md).

## 9. Not sandboxed, and therefore not a Mac App Store app

The App Sandbox is incompatible with the Accessibility API, with OpenDirectory
password verification, and with launching `pmset`. FaceUnlock therefore ships as
a Developer ID-signed, notarised app with the Hardened Runtime enabled. The
reasoning is recorded in `Config/FaceUnlock.entitlements`.

## 10. External and Continuity cameras

The built-in camera is always preferred. An external or Continuity camera is used
only when there is no built-in one, and the compatibility report marks that as
"Attention" rather than "Supported": image quality, placement and availability are
outside FaceUnlock's control, and a Continuity camera can disconnect mid-attempt.

## 11. Intel Macs

Supported, but recognition runs on the CPU and GPU instead of the Neural Engine,
so it uses more power and takes longer. The compatibility report says so rather
than reporting a clean pass.

## 12. Calibration cannot rescue poor conditions

Calibration measures only *genuine* scores — there is no impostor set to measure
against on a personal machine. It is therefore used only to make the threshold
stricter than the preset floor, never more permissive. Enrolling in bad lighting
produces a wide spread and a threshold pinned to the floor, which shows up in the
UI as "clamped to the preset floor". Re-enrol in better light rather than
lowering the preset.

## 13. The camera indicator light

The green camera indicator is hardware-controlled and will light whenever
FaceUnlock is looking for you. This is intentional and cannot — and should not —
be suppressed. It is also a useful check: if it is on when FaceUnlock is idle,
something is wrong.
