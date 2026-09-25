#!/usr/bin/env python3
"""Convert a SigLIP image tower (+ tiny aesthetic head) to palettized Core ML.

Example (after installing torch, transformers, coremltools):

  python convert_siglip_coreml.py \
    --model google/siglip-base-patch16-224 \
    --aesthetic-head aesthetic_head.pt \
    --out SigLIPAesthetic.mlpackage

This script is a template — pin exact versions in a requirements lock before release.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="google/siglip-base-patch16-224")
    parser.add_argument("--aesthetic-head", type=Path, default=None)
    parser.add_argument("--out", type=Path, default=Path("SigLIPAesthetic.mlpackage"))
    parser.add_argument("--bits", type=int, default=6, help="palettization bits")
    args = parser.parse_args()

    try:
        import coremltools as ct
        import torch
        from transformers import AutoModel, AutoProcessor
    except ImportError as e:
        raise SystemExit(
            "Install torch, transformers, coremltools before converting.\n" + str(e)
        )

    print(f"Loading {args.model}…")
    processor = AutoProcessor.from_pretrained(args.model)
    model = AutoModel.from_pretrained(args.model).eval()

    # Trace image tower only (get_image_features).
    class ImageTower(torch.nn.Module):
        def __init__(self, m, head=None):
            super().__init__()
            self.m = m
            self.head = head

        def forward(self, pixel_values):
            feats = self.m.get_image_features(pixel_values=pixel_values)
            if self.head is not None:
                aesthetic = self.head(feats)
                return feats, aesthetic
            return feats

    head = None
    if args.aesthetic_head and args.aesthetic_head.exists():
        head = torch.load(args.aesthetic_head, map_location="cpu")
        head.eval()

    tower = ImageTower(model, head)
    example = torch.randn(1, 3, 224, 224)
    traced = torch.jit.trace(tower, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
    )

    # Optional palettization for size / ANE friendliness.
    try:
        op_config = ct.optimize.coreml.OpPalettizerConfig(nbits=args.bits)
        config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
        mlmodel = ct.optimize.coreml.palettize_weights(mlmodel, config)
    except Exception as exc:  # noqa: BLE001
        print("palettize skipped:", exc)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.out))
    print("Wrote", args.out)
    _ = processor  # reserved for text-embedding export of junk prompts


if __name__ == "__main__":
    main()
