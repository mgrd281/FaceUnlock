# Spike: can anything see your face while the screen is locked?

FaceUnlock's most valuable missing feature is the obvious one — come back
after ten minutes and have the Mac recognise you and open. Everything about
whether that can be built at all rests on two questions, and neither can be
answered from documentation. Apple neither guarantees nor forbids the
behaviour, and it has changed between releases.

**Question 1 — the camera.** When the screen is locked, does macOS keep
delivering camera frames to an ordinary process in the user's session, and can
Vision still find a face in them?

**Question 2 — the unlock.** Can a login-window authorisation plugin
(`/Library/Security/SecurityAgentPlugins`, registered against
`system.login.screensaver`) take a "yes, it is them" answer from FaceUnlock and
satisfy the authentication? This is Apple's documented extension point for
adding an authentication method — the same one enterprise SSO products use. It
is not a bypass of anything: the plugin runs *inside* SecurityAgent rather than
poking at it from outside, and the password always remains as the fallback.

This directory answers **question 1 only**. That is deliberate. Question 1 is
free to test — nothing is installed, no administrator rights are involved, no
system state is touched — and a "no" there makes question 2 irrelevant, so
there is no reason to take the heavier risk first.

## Running it

```bash
./Spike/lock-screen-probe/run.sh
```

1. Leave the Terminal window running.
2. Lock the screen (⌃⌘Q) and stay in front of the Mac.
3. Wait about 30 seconds, then unlock.
4. Press Ctrl-C. The probe prints a verdict and writes
   `~/faceunlock-lock-probe.log`.

Each line looks like:

```
[14:03:12] locked=YES frames= 60 analysed=12 faces=11 | totals: frames=421 whileLocked=180 facesWhileLocked=95
```

`locked=YES` with `frames` above zero is the answer. Camera permission is
attributed to Terminal, so approve the prompt for Terminal the first time.

## What each outcome means

| Result | Meaning | Next step |
|---|---|---|
| Frames arrive while locked, faces found | The hard part is only the unlock side | Build question 2: the authorisation plugin |
| Frames arrive, no faces found | Not an API problem — lighting, the screen being dark, or the crop | Tune, then question 2 |
| No frames while locked | macOS suspends capture at the lock screen | Real unlock is not possible this way; say so plainly and focus on lock-on-absence |

## Note on question 2, when we get there

An authorisation plugin is installed as root and participates in login. A bug
there can make signing in awkward, so it will ship with an uninstall script, a
documented Recovery-mode removal path, and the password fallback left intact at
every step. None of that work starts before question 1 says it is worth doing.
