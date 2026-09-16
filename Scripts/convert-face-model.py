#!/usr/bin/env python3
"""
Convert the facenet-pytorch InceptionResnetV1 (VGGFace2) face-embedding network
into the Core ML package that FaceUnlock bundles as `FaceDescriptorModel`.

The result is a Core ML *ML program* that:

  * accepts a 160x160 RGB face crop (the same crop `FaceAligner` produces),
  * folds the FaceNet input normalisation ((x - 127.5) / 128) into the model
    input so Swift can hand over a plain pixel buffer,
  * emits a 512-dimensional embedding (L2-normalised by the network),
  * carries 8-bit linear-quantised weights (~24 MB instead of ~110 MB),
  * runs entirely on-device on the Neural Engine, GPU or CPU.

Everything downloaded here is MIT licensed (facenet-pytorch code and the
converted weights). See Resources/MODEL.md for the full provenance and the
licence discussion.

Usage:
    python3 -m venv .venv && source .venv/bin/activate
    pip install --index-url https://download.pytorch.org/whl/cpu torch
    pip install coremltools facenet-pytorch numpy pillow
    python3 Scripts/convert-face-model.py [--output FaceUnlock/Resources]

Conversion works on Linux and macOS; *validating* the package (running a
prediction) needs macOS because Core ML itself is macOS-only. The script
therefore validates the PyTorch side and leaves the on-device check to
`FaceUnlockTests`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
)
from facenet_pytorch import InceptionResnetV1

MODEL_NAME = "FaceDescriptorModel"
MODEL_VERSION = "1.0.0"
INPUT_SIZE = 160
EMBEDDING_SIZE = 512
WEIGHTS_TAG = "20180402-114759-vggface2"


class NormalisedFaceNet(torch.nn.Module):
    """InceptionResnetV1 with the output L2-normalised (facenet-pytorch already
    does this in eval mode, we make it explicit so the contract is visible)."""

    def __init__(self) -> None:
        super().__init__()
        self.net = InceptionResnetV1(pretrained="vggface2", classify=False).eval()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        embedding = self.net(x)
        return torch.nn.functional.normalize(embedding, p=2, dim=1)


def sha256_of_tree(root: Path) -> str:
    """Deterministic SHA-256 over every file in the package (sorted paths)."""
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="FaceUnlock/Resources")
    parser.add_argument("--no-quantize", action="store_true",
                        help="keep fp16 weights (larger, marginally more accurate)")
    args = parser.parse_args()

    torch.manual_seed(0)
    model = NormalisedFaceNet().eval()

    example = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE) * 2 - 1
    with torch.no_grad():
        reference = model(example).numpy()
        norm = float(np.linalg.norm(reference))
        assert reference.shape == (1, EMBEDDING_SIZE), reference.shape
        assert abs(norm - 1.0) < 1e-3, norm
        traced = torch.jit.trace(model, example)

    # (pixel - 127.5) / 128  ==  pixel * (1/128) + (-127.5/128)
    image_input = ct.ImageType(
        name="face",
        shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
        color_layout=ct.colorlayout.RGB,
        scale=1.0 / 128.0,
        bias=[-127.5 / 128.0] * 3,
    )
    mlmodel = ct.convert(
        traced,
        inputs=[image_input],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )

    if not args.no_quantize:
        config = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
        )
        mlmodel = linear_quantize_weights(mlmodel, config=config)

    mlmodel.author = "FaceUnlock (converted from facenet-pytorch)"
    mlmodel.license = "MIT (facenet-pytorch, Tim Esler). See MODEL.md."
    mlmodel.short_description = (
        "InceptionResnetV1 face-descriptor network (VGGFace2 weights). "
        "160x160 RGB face crop -> 512-d L2-normalised embedding."
    )
    mlmodel.version = MODEL_VERSION
    mlmodel.user_defined_metadata["de.faceunlock.model.source"] = (
        "https://github.com/timesler/facenet-pytorch"
    )
    mlmodel.user_defined_metadata["de.faceunlock.model.weights"] = WEIGHTS_TAG
    mlmodel.user_defined_metadata["de.faceunlock.model.embedding_size"] = str(EMBEDDING_SIZE)
    mlmodel.user_defined_metadata["de.faceunlock.model.input_size"] = str(INPUT_SIZE)
    mlmodel.user_defined_metadata["de.faceunlock.model.normalisation"] = "(x-127.5)/128, folded in"

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    package = output_dir / f"{MODEL_NAME}.mlpackage"
    if package.exists():
        import shutil
        shutil.rmtree(package)
    mlmodel.save(str(package))

    size = sum(p.stat().st_size for p in package.rglob("*") if p.is_file())
    sha = sha256_of_tree(package)
    manifest = {
        "name": MODEL_NAME,
        "version": MODEL_VERSION,
        "weights": WEIGHTS_TAG,
        "source": "https://github.com/timesler/facenet-pytorch",
        "license": "MIT",
        "input": f"{INPUT_SIZE}x{INPUT_SIZE} RGB, normalisation folded in",
        "output": f"{EMBEDDING_SIZE}-d L2-normalised float embedding",
        "quantized": not args.no_quantize,
        "size_bytes": size,
        "sha256": sha,
        "torch": torch.__version__,
        "coremltools": ct.__version__,
    }
    (output_dir / f"{MODEL_NAME}.sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
