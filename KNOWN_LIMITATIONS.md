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

## 14. Lock-screen unlock asks for a blink, and a video replay can still answer it

**What it does.** Unlocking the lock screen requires a blink: a full eye closure
followed by a reopening, observed during that unlock attempt. You do not have to
be told when — you look at the camera and blink once, which most people do
within a second or two anyway.

**Why a blink and not passive analysis.** This was tried the other way first.
Passive signals — texture isotropy, shading curvature, specular concentration —
were implemented, weighted and measured against a real attack. The results were
not close:

| signal | live face | same face on a phone |
|---|---|---|
| texture isotropy | 0.98 | **0.74 … 0.95** |
| specular concentration | 0.32 | **0.73** |
| shading curvature | 0.00 | 0.00 |
| micro-motion | 0.93 | 0.45 |

Isotropy gave 0.74 when the camera resolved the phone's pixel grid and 0.95 when
it did not — the same attack, the same phone, a different distance. Specular
concentration scored the *attack* higher than the real face, because a phone's
glass throws one sharp reflection while skin scatters. Shading read zero for
everything. With those weights a photograph on a phone unlocked a real Mac
**three times out of three, in under a second**.

A blink is not a better-tuned version of those signals; it is a different kind of
evidence. A still image cannot produce a closure and a reopening at any distance,
in any lighting, at any angle.

**What it does not stop.** A *video* of you blinking will satisfy it. Defeating
that needs the blink demanded at a moment the attacker cannot predict, and
demanding anything needs somewhere to display the demand. macOS provides no way
for a third-party authorisation plugin to draw on the lock screen: the only hints
SecurityAgent renders are `prompt` and `icon`, and only for Apple's own built-in
mechanisms.

An active screen flash — lighting the face and measuring how a rounded surface
reflects it, versus a flat glossy one — was investigated as a replacement that
would need nothing from the user. It cannot be delivered either: there is no
public API for display brightness (`IODisplayConnect` is gone on Apple silicon,
and `DisplayServices` and `CoreDisplay` are private), and a white window cannot
be drawn over the lock screen for the same reason a prompt cannot. FaceUnlock
does not use private APIs, so the approach is recorded as investigated and
rejected rather than shipped.

**So, plainly:** lock-screen face unlock resists a printed photograph and a
still image on a screen. It does not resist a video replay of you blinking.
Your password remains available at all times as a separate branch of the same
authorisation rule, and if that threat is in your model, leave lock-screen
unlock uninstalled and use FaceUnlock for presence only.
