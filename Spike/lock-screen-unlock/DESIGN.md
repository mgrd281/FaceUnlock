# Recognising the user at the lock screen — design

## Status

Not built. This is the design the two open questions resolved into, written down
so the build is a matter of following it rather than re-deciding it.

* **Question 1 — can anything see the user while the screen is locked?**
  Answered **yes**, measured: `../lock-screen-probe/README.md`. A user-session
  process keeps receiving camera frames at full rate while locked, and Vision
  finds faces in them.
* **Question 2 — can a third party add an authentication method to the macOS
  lock screen?** Answered **yes**. A shipping product (MacGaze) appears as an
  entry on the lock screen next to "Enter Password", which is what the
  authorisation-plugin mechanism looks like from the outside. That is existence
  proof of the mechanism only — none of its code, assets, branding or naming is
  used or referenced here.

## The mechanism

macOS lets a bundle in `/Library/Security/SecurityAgentPlugins/` register as a
*mechanism* against an authorisation right (`system.login.screensaver` for the
lock screen). The bundle is loaded inside `SecurityAgent`, the process that
draws the lock screen, and each mechanism returns allow / deny / undefined.
This is Apple's documented extension point — the same one enterprise sign-on
products use. Nothing here disables, patches or works around a macOS security
control; the password remains available at every step.

## Why three processes, not two

The obvious design — plugin asks the app directly over a socket — has a hole.
SecurityAgent runs as `_securityagent`, the app as the logged-in user, so the
socket must be reachable across uids. If the user's own account can create that
socket, then **any** process running as that user can delete it, bind its own,
and answer "yes" to the lock screen. Malware with ordinary user access would be
able to unlock the screen, which is precisely the boundary the lock screen
exists to defend.

So the privileged side owns the namespace:

```
  SecurityAgent                    root LaunchDaemon              FaceUnlock.app
  ┌──────────────┐   asks         ┌──────────────────┐  relays   ┌────────────┐
  │ FaceUnlock   │ ─────────────▶ │ faceunlockd      │ ────────▶ │ recognition│
  │ mechanism    │ ◀───────────── │ owns the socket  │ ◀──────── │ pipeline   │
  └──────────────┘   allow/undef  └──────────────────┘  verdict  └────────────┘
     _securityagent                      root                      logged-in user
```

* `faceunlockd` runs as root, creates the socket in a root-owned directory, and
  is the only thing that can bind that path. It holds no camera and no
  biometric data — it is a broker.
* The app connects **out** to the daemon and registers as the responder. The
  daemon accepts the registration only after checking the connecting process's
  code signature against FaceUnlock's designated requirement.
* The daemon likewise accepts questions only from a caller whose code signature
  is Apple's, i.e. SecurityAgent.
* The camera and the enrolled profile stay in the user session, where the TCC
  grant and the Keychain item already live. The daemon never sees a frame, a
  descriptor or a key.

## Rules the build must keep

1. **The mechanism returns `allow` or `undefined`, never `deny`.** `undefined`
   lets the chain fall through to the password. A bug must cost the user a face
   unlock, never their way in.
2. **No answer is trusted without a fresh challenge.** The daemon issues a
   random nonce per request; the app's verdict is only accepted for that nonce,
   once, within a few seconds. A recorded "yes" is worth nothing later.
3. **Identity, not presence.** The verdict comes from the same matcher, model,
   threshold and liveness analysis the app already uses — "the enrolled user is
   here", never "a face is here". No code path answers on mere face presence.
4. **Every install step is reversible**, and the uninstall script plus the
   Recovery-mode removal path ship with the first version, tested before the
   plugin is registered against any right.
5. **Staged registration.** The plugin is first exercised against a private
   right that grants nothing, so a load failure or crash cannot affect login.
   `system.login.screensaver` is only touched once that passes, and the original
   right is backed up first.

## What it needs that the repo does not have yet

* A Developer ID signature. Ad-hoc bundles are not loaded into SecurityAgent,
  and the daemon's code-signature checks need stable identities to check against.
* The plugin itself is C against `Security/AuthorizationPlugin.h`; the daemon
  and the app changes are Swift.
