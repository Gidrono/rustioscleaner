#!/usr/bin/env python3
"""Train a tiny aesthetic MLP on frozen SigLIP embeddings.

Expect a CSV with columns: path,score  (score in 1..10 or 0..1).
"""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--csv", type=Path, required=True)
    p.add_argument("--dim", type=int, default=768)
    p.add_argument("--out", type=Path, default=Path("aesthetic_head.pt"))
    args = p.parse_args()

    try:
        import torch
        import torch.nn as nn
    except ImportError as e:
        raise SystemExit("torch required: " + str(e))

    class Head(nn.Module):
        def __init__(self, dim: int):
            super().__init__()
            self.net = nn.Sequential(
                nn.Linear(dim, 256),
                nn.ReLU(),
                nn.Linear(256, 64),
                nn.ReLU(),
                nn.Linear(64, 1),
                nn.Sigmoid(),
            )

        def forward(self, x):
            return self.net(x).squeeze(-1)

    model = Head(args.dim)
    # Placeholder: real training loop loads embeddings from CSV-referenced files.
    print(f"Initialized head dim={args.dim}. Wire your dataset loader before training.")
    print(f"Would write to {args.out} after fit. CSV={args.csv}")
    torch.save(model, args.out)


if __name__ == "__main__":
    main()
