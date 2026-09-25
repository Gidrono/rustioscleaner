#!/usr/bin/env python3
"""Export junk prompt text embeddings to junk_prompts.json for the app bundle."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--prompts",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "prompts" / "junk_prompts.txt",
    )
    p.add_argument("--model", default="google/siglip-base-patch16-224")
    p.add_argument("--out", type=Path, default=Path("junk_prompts.json"))
    args = p.parse_args()

    labels = [
        ln.strip()
        for ln in args.prompts.read_text().splitlines()
        if ln.strip() and not ln.startswith("#")
    ]

    try:
        import torch
        from transformers import AutoModel, AutoTokenizer
    except ImportError:
        # Offline stub vectors so the pipeline can be tested without HF.
        payload = [
            {"label": lab, "vector": [1.0 if i == (idx % 64) else 0.0 for i in range(64)]}
            for idx, lab in enumerate(labels)
        ]
        args.out.write_text(json.dumps(payload, indent=2))
        print("Wrote stub", args.out)
        return

    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModel.from_pretrained(args.model).eval()
    payload = []
    with torch.no_grad():
        for lab in labels:
            inputs = tok([lab], padding=True, return_tensors="pt")
            feats = model.get_text_features(**inputs)[0]
            feats = feats / feats.norm()
            payload.append({"label": lab, "vector": feats.tolist()})
    args.out.write_text(json.dumps(payload))
    print("Wrote", args.out, "prompts=", len(payload))


if __name__ == "__main__":
    main()
