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

**What works fully, with public APIs and no special permission.** When the screen
saver starts — which is some time before the session locks, by whatever grace
period you configured — FaceUnlock spends a few seconds of camera time looking
for you. If it finds you, `PresenceUnlockProvider` declares user activity
(`IOPMAssertionDeclareUserActivity`), which wakes the display and resets the idle
timer, and takes a short `PreventUserIdleDisplaySleep` assertion to cover the
handover. The Mac then behaves as though you had moved the mouse.

**Its limits.** It cannot act on a session that is already locked, and it says so
rather than trying. It is not continuous presence detection either: the camera is
only used during the idle window, not all the time, which is what keeps FaceUnlock
at essentially zero CPU while you are working. And if your grace period is
"immediately", there is no window for it to act in at all — FaceUnlock falls back
to the manual provider.

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

## 7. The descriptor is a 2-D face network, not Face ID

The default descriptor is a metric-learned InceptionResnetV1 (VGGFace2) running
on-device through Core ML (`MODEL.md`). It is a strong 2-D identity model, but
it sees only a colour image: there is no depth map, no infrared, no Secure
Enclave and no attention detection. Identical twins and very close siblings can
score inside the genuine band, and heavy occlusion (mask, hand) or extreme
lighting still fails honestly rather than guessing.

If the model resource is missing or fails its launch self-test, the app falls
back to `VNGenerateImageFeaturePrintRequest` plus landmark geometry, which is
noticeably less discriminative; Diagnostics › Engine shows which pipeline is
active. A replacement model can be dropped at
`~/Library/Application Support/de.faceunlock.mac/Models/FaceDescriptorModel.mlmodelc`
(160×160 RGB input, single `MLMultiArray` output). Changing the model changes
the stored `producerVersion`, so you must re-enrol; profiles are never matched
across pipelines.

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

## 14. Lock-screen unlock judges liveness on the floor alone

**The restriction.** The interactive liveness challenge — "blink", "turn your
head slightly left" — is the part of liveness a photograph and a replayed video
cannot answer. Showing it needs somewhere to draw it, and the lock screen covers
every window FaceUnlock owns. There is no supported way for an app in your
session to put a prompt on top of the lock screen.

**What FaceUnlock does.** On the lock-screen path only, the marginal liveness
band is allowed through and the score is judged against the floor alone
(0.62 on the balanced preset) rather than against the band top (0.74) that would
otherwise trigger a prompt. Everywhere else in the app — the recognition test,
the pre-lock presence check — a marginal score still asks for a challenge and
still refuses without one.

Three checks are **not** relaxed, on any path:

- the liveness window must be full before any conclusion is reached, so a
  matching face can never be accepted before liveness has judged anything;
- the spoof disqualifiers still reject outright — a frozen feed, a repeated
  frame sequence, a stale image;
- the identity threshold is untouched.

**What this costs.** Unlocking a locked session is the highest-value target in
this app, and this is the one place where a check is relaxed rather than
reported honestly and refused. A high-quality video replay on a large matte
display was already a realistic bypass (§8); without the challenge it is a more
realistic one. This is a deliberate choice, not an oversight, and the residual
risk is recorded in [SECURITY.md](SECURITY.md).

Two honest alternatives exist and neither is implemented: giving the attempt a
longer budget so passive evidence can reach the band on its own, and drawing the
prompt inside SecurityAgent, where the lock screen itself lives.
