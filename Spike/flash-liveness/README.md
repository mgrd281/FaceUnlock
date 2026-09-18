# Active flash liveness — investigated, not shipped

The idea: flash the screen, and tell a face from a phone by *how* the light
comes back. A face is rounded and matte, so the flash falls off across it — nose
and forehead gain more than cheeks and edges. A phone is flat and glossy: it
brightens almost uniformly, or throws one specular hotspot. Those are different
spatial signatures, which matters because overall brightness is the one thing an
attacker can trivially match. Best of all, the user does nothing but look.

It is not shipped, and the reason is not that the physics is wrong.

## Why it cannot be delivered

**There is no way to flash the screen at the lock screen using public API.**

- Display brightness has no public interface. `IODisplayConnect` — the classic
  IOKit route — does not exist on Apple silicon; this was checked on the machine
  rather than assumed. `DisplayServices` and `CoreDisplay` can do it and are
  private: `CoreDisplay.framework` ships zero public headers.
- A white window cannot be drawn over the lock screen, for the same reason a
  "blink now" prompt cannot: the lock screen admits no window belonging to a
  user-session app, and SecurityAgent renders no UI for a third-party
  authorisation plugin.

FaceUnlock does not use private APIs, so that is the end of it. `flash-probe`
here flashes with an ordinary window and therefore only runs unlocked; any
result it produces does not transfer to the lock screen.

## What the probe does

Locks camera exposure and white balance — left automatic, the camera erases the
very signal being measured within a frame or two — then alternates a black and
white fullscreen window and compares the two, reporting:

* **mean gain** — whether the flash reached the subject at all
* **centre/edge** — above 1 for a solid, about 1 for a plane
* **structure** — spatial detail surviving normalisation by overall gain

```
./flash-probe live 12
./flash-probe phone 12
```

## Status

Incomplete. In trials the flash never registered above noise (peak gain 0.0014,
against a 0.002 threshold) and camera permission for the terminal proved
unstable between runs, so no comparison between a face and a phone was ever
obtained. The delivery problem above made finishing it moot.

Kept so that the next person to have this idea finds the blocker in five minutes
rather than five hours. If Apple ever exposes brightness publicly, or a
mechanism gains a way to draw, start here.
