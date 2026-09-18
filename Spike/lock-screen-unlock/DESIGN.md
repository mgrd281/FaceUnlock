# Question 2: satisfying the lock screen

`Spike/lock-screen-probe/` answered question 1 on 2026-09-17: the camera keeps
running at the lock screen, unchanged frame rate, a face found in 200 of 200
analysed frames. Nothing has to be invented to *see* the user while the session
is locked. What is missing is a sanctioned way to tell macOS that the
recognition succeeded.

This document is the design for that. It is question 2 from the probe's README,
and it is deliberately the heavier half: it installs a `root` LaunchDaemon and a
bundle that SecurityAgent loads during authentication. Every decision below is
made in favour of the machine staying usable when something goes wrong.

---

## 1. The one thing that makes this safe

macOS authorization rights are a graph, not a script. `system.login.screensaver`
is a **container rule** that holds a list of sub-rules and a `k-of-n` count.
With `k-of-n = 1`, any single sub-rule that succeeds grants the right; a
sub-rule that fails is not fatal, the container simply moves to the next one.

That is not a theory. It is the live state of this Mac, already:

```
system.login.screensaver          class = rule,  k-of-n = 1
├── com.openai.sky.CUAService.AuthorizationPlugin.remote    class = evaluate-mechanisms
│     └── mechanisms: [ CodexComputerUseAuthorizationPlugin:allow ]   tries = 1
└── use-login-window-ui                                     class = user  → password prompt
```

Another vendor's authorization plugin is *already* installed here
(`/Library/Security/SecurityAgentPlugins/CodexComputerUseAuthorizationPlugin.bundle`,
Developer ID: OpenAI OpCo, LLC), composed with the ordinary password prompt in
exactly this shape. FaceUnlock adds a third branch alongside it.

**The consequence is the central safety property of this design: the password
fallback is structural.** It is a property of the rule graph, not of FaceUnlock
behaving well. If our mechanism denies, crashes, is deleted, or was never
signed, the container falls through to `use-login-window-ui` and the user types
their password exactly as before. There is no code path of ours that can remove
the password branch, because our code does not own the container.

Two corollaries worth stating plainly:

- A **deleted plugin bundle with the rule still in place** is a safe state, not
  a brick. The sub-rule fails to load, the container falls through. This is what
  makes the Recovery-mode removal path (§9) a `rm -rf` and nothing more.
- Breaking `system.login.screensaver` outright would still not lock you out of
  the Mac. The login window after a restart is `system.login.console`, a
  different right with a different mechanism list, which this design never
  touches.

---

## 2. Four processes, three trust boundaries

| Process | Runs as | Session | Role |
|---|---|---|---|
| `FaceUnlock.app` | you | Aqua (your GUI session) | Owns the camera, the profile and the whole recognition stack. Answers challenges. |
| `faceunlockd` | `root` | system | LaunchDaemon. The broker. Holds no biometric data. |
| `FaceUnlock.bundle` mechanism | `_securityagent` | SecurityAgent | Asks "is it them, right now?" and returns Allow or Deny. |
| `loginwindow` / SecurityAgent | Apple's | — | Owns the right evaluation. We are a guest inside it. |

### Why a root broker exists at all

The app registers its Mach service in the **Aqua** bootstrap domain, which is
per-user and per-session. SecurityAgent runs in a different session and cannot
look that name up. A LaunchDaemon's `MachServices` entry is registered in the
**system** domain, which both sides can reach. The broker exists for exactly
that reason and does exactly that much.

It is a relay with a policy check. **No image, no descriptor, no profile and no
password ever crosses it.** The entire payload in either direction is a nonce, a
uid, and a boolean.

```
SecurityAgent (_securityagent)        faceunlockd (root)            FaceUnlock.app (you)
        │                                    │                              │
   MechanismInvoke                           │                              │
        │  1. beginChallenge(uid)            │                              │
        │───────────────────────────────────►│                              │
        │                         mints nonce N, stamps t0                  │
        │                                    │  2. challenge(N, uid)        │
        │                                    │─────────────────────────────►│
        │                                    │                     fresh recognition
        │                                    │                     (camera already alive)
        │                                    │  3. answer(N, verdict)       │
        │                                    │◄─────────────────────────────│
        │  4. verdict (blocking, ≤ 6 s)      │                              │
        │◄───────────────────────────────────│                              │
   Allow / Deny                              │                              │
```

---

## 3. Why it is a challenge, not an assertion

The obvious design — the app publishes "the user is present" and the plugin
reads it — is wrong, and the reason is worth recording so nobody simplifies it
back later.

A free-running presence flag is a **replayable token**. It is minted before the
authorization request exists, so nothing binds it to that request. A flag
written the moment before you stood up is indistinguishable from one written
while you are sitting there. Shortening its TTL narrows the window but never
closes it, and a short TTL on a flag that is refreshed continuously is not short
at all.

So the broker mints the nonce, *after* the request arrives, and the verdict is
only accepted for the challenge it was minted for. The app cannot pre-compute an
answer, because it does not know `N` until the lock screen asks.

Broker rules, all of them enforced in the broker rather than trusted to a peer:

- One outstanding challenge at a time. A second `beginChallenge` cancels the first.
- The app registers itself as the answering agent, and re-registers whenever the
  components are installed or the daemon restarts underneath a running app. That
  repair is driven by the ordinary refresh the app already does, not by a timer;
  without it, installing while the app is running leaves it silently unregistered.
- `N` is 32 bytes from `SecRandomCopyBytes`, single-use, erased the moment it is answered.
- Challenge TTL **10 seconds**, measured with `mach_continuous_time` so that
  sleeping the Mac cannot stretch it. The TTL follows the recognition budget
  rather than leading it: passive liveness needs frames, and starving the
  attempt to keep the lock screen responsive made the verdict a coin toss (§7).
- The answering peer must be running as the uid named in the challenge.
- After **5** consecutive denials the broker refuses all challenges for **60 seconds**.
  The mechanism then simply denies and the password branch takes over.

---

## 4. Authenticating both peers

Neither peer is trusted by position. Both are pinned with
`xpc_connection_set_peer_code_signing_requirement()` — public API, available on
the macOS 14 deployment target, and the supported replacement for hand-rolled
`audit_token_t` inspection.

**Two things about this were wrong in the first version of this document, and
both were found by running it.** They are recorded here because the corrected
shape only makes sense against them.

*A peer requirement validates the process, not the code loaded inside it.* The
mechanism is a bundle loaded into Apple's `SecurityAgentHelper-arm64`
(`identifier "com.apple.SecurityAgentHelper.arm64"`, Apple-signed, no team ID).
It never appears as a peer in its own right, so pinning the asker to
`de.faceunlock.mac.mechanism` could never match, and every challenge was refused
before the broker logged anything at all. The asker must be pinned to the
**host**, which is Apple's SecurityAgent.

*The two callers cannot be told apart by uid.* `SecurityAgentHelper` is an XPC
service of type `Application`, so it runs as the very same user as the app it is
asking about. Any rule of the form "the asker is root or `_securityagent`" is
simply false.

So the role is carried by **which service the peer reached**, and a peer's
identity can only be pinned per listener. The broker therefore publishes two:

| Service | Pinned to | May |
|---|---|---|
| `de.faceunlock.broker.agent` | our app, `de.faceunlock.mac` | register, and answer challenges |
| `de.faceunlock.broker.asker` | `anchor apple` and one of `com.apple.SecurityAgentHelper.arm64` / `.x86_64` / `com.apple.SecurityAgent` / `com.apple.authd` | begin a challenge |

Which socket a message arrived on *is* its role, enforced cryptographically
rather than by a uid comparison. The app cannot reach the asker service, so it
cannot mint a challenge for itself to answer; SecurityAgent cannot reach the
agent service, so it cannot answer one. `install.sh` verifies the host
requirement actually matches SecurityAgent on this macOS version before
installing, rather than letting a mismatch surface at the lock screen, and a
test asserts that the app's sources never so much as name the asker service.

The app pins the broker in turn, so an impostor daemon cannot harvest
challenges. The uid is still taken from the connection's effective uid, never
from the message body — it identifies *which user* is being answered for, which
is a separate question from which role the peer plays.

---

## 5. `IdentityService` — the new app-side component

The recognition stack is already built and tested: `RecognitionCoordinator`,
`FaceMatcher`, `BiometricProfileStore`, `LivenessAnalyzer`. None of it is
reachable from a SecurityAgent context, and none of it should be reshaped to
become so.

`IdentityService` is the narrow layer between the two. It is the *only* part of
the app the broker can address, and its entire vocabulary is one question:

```swift
public protocol IdentityServing: Sendable {
    /// Runs one fresh recognition attempt, bounded by `deadline`, and returns
    /// whether the enrolled owner of this session is in front of the camera now.
    /// Never returns a cached verdict.
    func answerChallenge(_ nonce: ChallengeNonce, deadline: Duration) async -> IdentityVerdict
}

public struct IdentityVerdict: Sendable {
    public let recognized: Bool
    /// Why not, for the log. Never a score, never a descriptor.
    public let refusal: RefusalReason?
}
```

It sits in `FaceUnlock/Identity/`, follows the existing dependency rule
(constructed only by `AppEnvironment`, collaborators injected as protocols,
stub in the same file), and is an `actor` because it serialises challenges.

What it deliberately does **not** do:

- It never returns a cached or extrapolated result. A challenge always costs a
  real recognition attempt, with liveness, against the stored profile.
- It never exposes a score, a threshold, a descriptor or a frame. The broker and
  the plugin learn one bit.
- It refuses when `unlockEnabled` is off, when no profile is enrolled, or when
  the profile's `producerVersion` does not match the active pipeline — the same
  preconditions `RecognitionCoordinator.refreshPreconditions` already enforces.

`UnlockCoordinator` gains a fourth provider, `LockScreenUnlockProvider`, at
`safetyRank` 25 — below `AccessibilityUnlockProvider`, above
`PresenceUnlockProvider`, because it is genuinely safer than driving the
Accessibility API but still less safe than never locking in the first place.
It reports `.supported` only when the daemon is installed, the rule is composed,
and the broker answers a handshake; otherwise `.unsupported`, honestly, as
everything else in that chain already does.

---

## 6. What the mechanism may return, and what it means

Under `class = evaluate-mechanisms`, a mechanism's result applies to **its own
sub-rule**, not to the whole right:

| Result | Effect on our sub-rule | Effect on the lock screen |
|---|---|---|
| `kAuthorizationResultAllow` | satisfied | screen unlocks, no password asked |
| `kAuthorizationResultDeny` | failed | container falls through to `use-login-window-ui` |
| `kAuthorizationResultUndefined` | failed, not retried | same fall-through |
| `kAuthorizationResultUserCanceled` | failed | same fall-through |

The mechanism therefore has exactly one dangerous failure mode, and it is not
returning the wrong answer — it is **not returning at all**. A hung mechanism
hangs the authorization, and no fall-through helps. Three things guard it:

1. A hard internal deadline. The XPC call to the broker is a
   `xpc_connection_send_message_with_reply` on a timeout, never a synchronous
   blocking send. On timeout the mechanism denies.
2. `tries = 1` on our sub-rule, copying the reference implementation, so the
   face branch gets exactly one attempt per unlock and then gets out of the way.
3. `MechanismDeactivate` always calls `DidDeactivate`, and `MechanismDestroy`
   tears the connection down, so an abandoned evaluation leaks nothing.

The mechanism is written in Objective-C against `AuthorizationPlugin.h`,
exporting the single symbol `AuthorizationPluginCreate`, linking only
Foundation, CoreFoundation and Security — the same shape as the reference
bundle already on this Mac. Swift is not used here: this code is loaded into
Apple's authentication process, and a Swift runtime dependency inside
SecurityAgent is a risk with no upside.

---

## 7. Staged rollout

### Stage 0 — a right that opens nothing

A custom right, `de.faceunlock.probe`, is created in the authorization database
pointing at our mechanism. It guards nothing; the only thing that requests it is
a throwaway CLI (`authprobe`) calling `AuthorizationCopyRights`.

This exercises the entire machinery — bundle loads inside SecurityAgent, broker
is reachable from that context, challenge round-trips to the app, verdict comes
back, timeouts and lockout behave — with **zero** effect on login. The lock
screen is untouched. If stage 0 cannot be made to pass, stage 1 never happens.

Stage 0 also establishes the two failure states empirically rather than by
assertion: delete the bundle and confirm the right fails cleanly; stop the
daemon and confirm the mechanism denies on its deadline instead of hanging.

### Measured result

Run on 2026-09-18, same Mac as the camera probe, with `de.faceunlock.probe`
installed and the lock screen untouched:

```
Broker    Agent registered for uid 501
Broker    Challenge requested by a SecurityAgent host running as uid 501
Broker    Challenge minted for uid 501
App       Attempt finished: purpose=challenge verdict=failed (profile.missing)
App       Answered a lock-screen challenge: not recognised
Broker    Verdict: not recognised (noProfileEnrolled)
Mechanism Not recognised (noProfileEnrolled); the password branch takes over
```

**Every hop works.** The bundle loads inside SecurityAgent, the broker is
reachable from that context, the challenge round-trips to the app, a fresh
recognition attempt runs, and the verdict comes back inside the deadline — about
180 ms for the first attempt and 10 ms for each one after it.

The denial is the honest answer to the question asked: the Mac it ran on has a
`profile.bin` that no longer decrypts, so there was no profile to match against.
That is the correct outcome for that state, and the right refused cleanly rather
than hanging or granting. A grant needs an enrolled profile, which is a
prerequisite of the feature rather than a step in it.

Two design errors were found by this run and only by this run; both are recorded
in §4, because neither was visible from reading the code.

### What running it actually cost, and found

Stage 0 took six rounds against the real system, and every round found something
no amount of reading would have:

1. **The peer pin could never match.** `xpc_connection_set_peer_code_signing_requirement`
   validates the *process*, and our mechanism is a bundle inside Apple's
   SecurityAgent (§4).
2. **The two callers could not be told apart by uid.** SecurityAgentHelper is an
   XPC service of type `Application`, so it runs as the same user as the app
   (§4). Hence two services rather than one.
3. **The app never re-registered.** Installing while it was running left it
   silently unregistered; registration is now self-maintaining (§3).
4. **The deadline bounded nothing.** `withTaskGroup` awaits every child, so the
   verdict was decided at 5.5 s and delivered at 15.1 s — after the broker had
   given up. Replaced with a continuation claimed by whichever task finishes
   first.
5. **A pre-existing Keychain bug was eating enrolments.** The fallback to the
   login keychain fired only on `errSecMissingEntitlement`, so an
   `errSecItemNotFound` read left the app believing no encryption key existed;
   the next enrolment minted a fresh key over the real one. It also meant
   `destroyKey()` deleted from one keychain and left the key in the other. Both
   fixed in `KeychainService`.
6. **Liveness was judged on a quarter-full window** and the resulting challenge
   was latched permanently, so the lock screen waited for a blink prompt it
   could never draw.

The last of these exposed the design's real constraint, which is not a bug and
has no clean answer: **the interactive liveness challenge cannot be shown at the
lock screen.** The chosen resolution is to judge liveness on the floor alone on
that path, accepting a weaker anti-spoof posture there than anywhere else in the
app. That decision, its cost, and the two alternatives not taken are recorded in
`KNOWN_LIMITATIONS.md` §14 and in the residual-risk table in `SECURITY.md` —
deliberately in the user-facing documents, not only here.

### Stage 1 — the real right

Only after stage 0 is green. Our sub-rule is **added to** the existing array in
`system.login.screensaver`, preserving every entry already there:

```
system.login.screensaver          class = rule,  k-of-n = 1
├── de.faceunlock.screensaver                         ← added
├── com.openai.sky.CUAService.AuthorizationPlugin.remote   ← preserved
└── use-login-window-ui                                    ← preserved, always last
```

`use-login-window-ui` stays last so that the password branch is the final word.

---

## 8. Install and uninstall

`install.sh` requires root and refuses to do anything out of order:

1. Read the **current** `system.login.screensaver` and write it verbatim to
   `/Library/Application Support/FaceUnlock/authdb-backup-<ISO8601>.plist`.
   This happens before any write, every time, and a failure here aborts.
2. Verify the plugin bundle's signature against the expected Team ID with
   `codesign --verify --deep --strict -R`. An unsigned or foreign bundle is
   never installed.
3. Copy the bundle to `/Library/Security/SecurityAgentPlugins/`, install the
   LaunchDaemon plist, `launchctl bootstrap system`.
4. Compose the rule by **reading, appending and writing back** — never by
   writing a literal. The OpenAI entry on this Mac is the standing proof that
   overwriting would break somebody else's product.

`uninstall.sh` is surgical and is the mirror image:

- Remove **only** the `de.faceunlock.screensaver` entry from the array; leave
  every other sub-rule exactly as found.
- If the array is not in a shape it recognises, restore the newest backup
  instead of guessing.
- `launchctl bootout`, remove the daemon plist, remove the bundle, remove the
  custom `de.faceunlock.probe` right.
- It is idempotent, and it works when the app is already gone.

---

## 9. When it goes wrong

The password branch (§1) covers the ordinary cases. The rest is for the day
something worse happens.

**The screen unlocks with the password but FaceUnlock misbehaves.** Log in and
run `sudo ./uninstall.sh`. Nothing else is needed.

**The lock screen hangs on the face branch.** Ctrl-Cmd-Q to re-lock, or switch
to a text console, or SSH in from another machine and run `uninstall.sh`. The
daemon can also be stopped alone — `sudo launchctl bootout system/de.faceunlock.daemon`
— which makes the mechanism deny on its deadline.

**Nothing works and you cannot log in at all.** Restart. The login window is
`system.login.console`, which this design never modifies, so a restart returns
you to a normal password login. From there, uninstall.

**Even that fails.** Boot to Recovery (hold the power button), open Terminal,
and delete two paths from the mounted volume:

```
/Volumes/Macintosh HD/Library/Security/SecurityAgentPlugins/FaceUnlock.bundle
/Volumes/Macintosh HD/Library/LaunchDaemons/de.faceunlock.daemon.plist
```

The stale rule left behind is harmless — a sub-rule whose plugin is missing
fails, and the container falls through to the password (§1). Restoring the rule
itself is optional cleanup, done later from a working session with the backup
written in step 1 of the install.

Recovery also has a blunter instrument, which puts the *whole* authorization
database back to Apple's defaults:

```
security authorizationdb reset <data volume UUID>
```

It is the last resort rather than the first, because it discards every change
anyone has made — including the other vendor's plugin already registered on this
Mac (§1). Prefer deleting the two paths above and letting the fall-through do
its work.

---

## 10. What this does not do, and will not

- **It does not touch FileVault pre-boot.** `KNOWN_LIMITATIONS.md` §4 stands
  unchanged. Authentication before macOS starts is out of reach and untouched.
- **It does not touch the login window.** `system.login.console` is not
  modified. After a restart or a logout you type your password, as before
  (`KNOWN_LIMITATIONS.md` §5).
- **It does not store or replay your password.** The `k-of-n` composition is
  what makes this possible: the face branch satisfies its own sub-rule rather
  than feeding credentials into `builtin:authenticate`. `CredentialStore` is not
  involved in this feature at all.
- **It does not make the descriptor stronger.** Everything in
  `KNOWN_LIMITATIONS.md` §7 and §8 still applies — 2-D, software-only liveness,
  identical twins a genuine risk. Unlocking a locked session is a materially
  higher-value target than resetting an idle timer, and the honest position is
  that this feature raises what a successful spoof is worth without changing how
  hard it is. That belongs in `SECURITY.md` before stage 1 ships, not after.
- **It is off by default,** installed by a script the user runs deliberately,
  and removable by a script that is tested before the feature is enabled.
