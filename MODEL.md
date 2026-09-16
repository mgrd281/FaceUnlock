# The bundled face-descriptor model

FaceUnlock ships one machine-learning model, `FaceDescriptorModel.mlpackage`,
in `FaceUnlock/Resources/`. This file records where it comes from, what it
does, how it was built, and under which licence it is redistributed — the
questions the project's own rules require answering before any model is
bundled.

## What it is

| | |
|---|---|
| Architecture | InceptionResnetV1 (FaceNet-style), 512-d output |
| Training data | VGGFace2 (weights tag `20180402-114759-vggface2`) |
| Origin | [facenet-pytorch](https://github.com/timesler/facenet-pytorch) by Tim Esler, itself a port of David Sandberg's [facenet](https://github.com/davidsandberg/facenet) TensorFlow weights |
| Input | 160 × 160 RGB face crop, exactly what `FaceAligner` produces. The FaceNet normalisation `(x − 127.5) / 128` is folded into the model input, so Swift hands over plain pixels. |
| Output | one 512-element `MLMultiArray`, L2-normalised |
| Format | Core ML *ML program*, fp16 activations, **int8 linear-quantised weights** (23.9 MB; fp16 would be ~48 MB, fp32 ~110 MB) |
| Deployment target | macOS 14 |
| Compute units | `.all` — Neural Engine on Apple silicon, GPU/CPU elsewhere |
| Model version (metadata) | `1.0.0` |
| SHA-256 of the package | `c7cdb426701e9b5fe4ea34fdba84e07a4776848ddf2dd6b92d695d05ff9dfa08` (see `FaceDescriptorModel.sha256.json` next to the package for the full manifest) |

The SHA-256 is computed over every file in the package (sorted relative
paths + contents) by `Scripts/convert-face-model.py`. Xcode compiles the
package to `FaceDescriptorModel.mlmodelc` at build time; the compiled bytes
depend on the Xcode release, which is why the app records the model's
**metadata version** (`CoreML:FaceDescriptorModel@1.0.0`), not the compiled
hash, in every stored descriptor's `producerVersion`. Bumping the version in
the converter is what invalidates old profiles.

## Why this model

`VNGenerateImageFeaturePrintRequest` — the only face-adjacent descriptor Apple
exposes publicly — is a general image descriptor. It answers "do these two
pictures look alike", not "is this the same person". In testing, unrelated
faces scored 0.80–0.86 on FaceUnlock's 0…1 scale against a same-person band of
0.90–0.97, which left the enrolment and calibration steps fighting for a few
hundredths of margin.

InceptionResnetV1/VGGFace2 is trained with a metric objective for identity:
the same person typically lands at cosine 0.6–0.85 and a different person at
−0.1–0.35. That is an order of magnitude more margin, and it is what makes
recognition fast (fewer consecutive frames needed) and tolerant of lighting,
glasses and moderate pose change. It is not Face ID: there is no depth sensor,
no secure enclave and no attention model. See `KNOWN_LIMITATIONS.md`.

## Licence

* **facenet-pytorch code**: MIT (Tim Esler).
* **The VGGFace2 weights distributed by facenet-pytorch**: released in the same
  repository under its MIT licence.
* **The VGGFace2 dataset** the weights were trained on is published by the
  Visual Geometry Group, Oxford, for research purposes. The dataset itself is
  not redistributed here and nothing in the model reproduces it, but if you
  ship FaceUnlock commercially you should have counsel confirm that a
  model *trained on* a research-licensed dataset is acceptable for your use.
  This is flagged rather than assumed.
* **The conversion** (this repository's `Scripts/convert-face-model.py` and the
  resulting `.mlpackage`) is MIT like the rest of FaceUnlock.

No MacGaze or other third-party proprietary assets are involved.

## Privacy and security properties

* Executes completely on-device. The model has no network capability and
  Core ML has no telemetry path.
* The input is a transient 160 × 160 crop that is overwritten by the next
  frame. The output is a 512-float vector, stored only inside the AES-GCM
  encrypted profile (`EncryptionService`). The vector is not reversible to a
  photograph, but it is still treated as biometric data (`PRIVACY.md`).
* The model is loaded once at launch and self-tested with a blank crop. If it
  fails to load or returns a non-finite vector, the app falls back to the
  Vision feature-print pipeline and says so in Diagnostics ("Engine").
* A profile enrolled with a different producer (the Vision pipeline, or a
  different model version) is refused before any frame is captured and the
  user is asked to enrol again. Descriptors are never compared across producers.

## Rebuilding it

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install --index-url https://download.pytorch.org/whl/cpu torch
pip install coremltools facenet-pytorch numpy pillow
python3 Scripts/convert-face-model.py            # writes FaceUnlock/Resources/FaceDescriptorModel.mlpackage
```

Conversion runs on Linux or macOS; running a prediction against the package
(`coremltools` `predict`) needs macOS. `FaceUnlockTests/CoreMLFaceEmbeddingServiceTests`
loads the bundled model in the app and checks its output shape and norm.

## Replacing it

Drop a differently trained model at
`~/Library/Application Support/de.faceunlock.mac/Models/FaceDescriptorModel.mlmodelc`
and it takes precedence over the bundled one. It must accept a 160 × 160 RGB
image and return one `MLMultiArray`. Score floors (`SensitivityPreset.scoreFloor(for:)`)
were tuned for the FaceNet cosine distribution; a model on a different scale
needs its own floors.
