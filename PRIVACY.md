# Privacy

FaceUnlock has no server, no account, no analytics backend and no advertising
code. This document says exactly what exists on your Mac and what — if anything —
can leave it.

## What leaves this Mac

Nothing, with one exception you control:

- **Update checks.** Off by default. When you switch them on, FaceUnlock performs
  an unauthenticated `GET` of a JSON version file. The request carries no
  identifier: no machine ID, no account, no install UUID, no serial number, no
  hardware UUID. The session is ephemeral with cookies, caching and credential
  storage disabled, so a version check cannot become a tracking channel.

That is the entire network surface. The update checker is deliberately isolated
from everything else, so **a recognition failure can never cause a network
request**. Recognition itself never needs the network at all.

## What is stored, and where

| What | Where | Protection |
|---|---|---|
| Face descriptors, threshold, liveness configuration, two timestamps | `~/Library/Application Support/de.faceunlock.mac/profile.bin` | AES-GCM, key in the Keychain; directory `0700`, file `0600` |
| Profile encryption key | Keychain (`de.faceunlock.mac`, account `profile-encryption-key`) | Data-protection keychain, `WhenUnlockedThisDeviceOnly`, non-syncing |
| Account password (only if you save one) | Keychain, account `account-password` | Same |
| Preferences — presets, toggles, timings | `UserDefaults` | Non-secret by construction; no threshold, no credential, no biometric data |
| Log messages | Unified logging, on this Mac | No password, descriptor, image or Keychain payload is ever passed to a logger |

## What is never stored

- **No photographs.** Camera frames are analysed in memory and discarded. The
  enrolment flow turns each accepted frame into a descriptor and drops the frame;
  nothing is written to disk at any point.
- **No name, account identifier, device identifier or serial number** in the
  biometric profile.
- **No usage history** beyond a handful of in-memory counters that reset when the
  app quits.

## Descriptors are still biometric data

A descriptor cannot be turned back into a picture of you, but it identifies you,
so FaceUnlock treats it as a secret rather than as ordinary data: encrypted at
rest, never logged, never exported, and destroyed together with its key when you
choose "Forget my face".

## Forget my face

"Forget my face" — from the menu, from Settings › Face Recognition, or from
Settings › Privacy — does all of this:

1. Overwrites the profile ciphertext, then unlinks the file.
2. Removes any enrolment scratch directory.
3. **Destroys the AES key in the Keychain.**

Step 3 is the one that matters: on a copy-on-write filesystem such as APFS,
overwriting a file does not guarantee the old blocks are gone, so destroying the
key is what makes any remaining ciphertext unrecoverable. The action is gated
behind system authentication when "Protect FaceUnlock settings" is on.

Removing the saved password is a separate, immediate action and takes effect at
once.

## Analytics

Off, and not implemented. There is no analytics SDK linked into the app, so there
is nothing the switch could send. It is shown in Settings, disabled, so you can
see for yourself that it is off rather than having to take this document's word
for it.

## Diagnostics export

"Export Diagnostics" writes a plain-text file. It is constrained by the
`DiagnosticsSnapshot` type, which has no field capable of holding a password, an
image, a descriptor or any part of one — so the export cannot leak them even by
accident. It contains: OS and hardware description, app version, permission
states, login-item status, the recognition engine identifier, the descriptor
*dimension* (a count, not values), the number of enrolled samples, the numeric
threshold, the preset names, the last result and error text, the average latency,
the unlock capability and provider availability, whether a password exists (not
what it is), whether analytics are enabled, and the network-usage description.

This is asserted by the test suite, not just by this document.

## Permissions and why

| Permission | Purpose | Consequence of refusing |
|---|---|---|
| Camera | Seeing your face | FaceUnlock cannot work; it says so and stops |
| Accessibility | Only the opt-in assisted lock-screen provider | Everything else keeps working |
| Notifications | Only telling you that you were recognised when macOS requires you to finish the unlock | The menu-bar icon still shows the result |

FaceUnlock never asks for a permission it is not about to use, and never
re-prompts after macOS has recorded your answer.
