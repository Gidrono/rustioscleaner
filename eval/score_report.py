#!/usr/bin/env python3
"""Compute precision/recall from labels.json vs predictions.json."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("labels")
    p.add_argument("predictions")
    args = p.parse_args()

    labels = {row["file"]: set(row.get("labels", [])) for row in json.loads(Path(args.labels).read_text())}
    preds = {row["file"]: set(row.get("labels", [])) for row in json.loads(Path(args.predictions).read_text())}

    cats = sorted({c for s in labels.values() for c in s} | {c for s in preds.values() for c in s})
    print(f"{'category':20} {'P':>6} {'R':>6} {'F1':>6}  support")
    for cat in cats:
        tp = fp = fn = 0
        for f, gold in labels.items():
            pred = preds.get(f, set())
            g, pr = cat in gold, cat in pred
            if g and pr:
                tp += 1
            elif pr and not g:
                fp += 1
            elif g and not pr:
                fn += 1
        prec = tp / (tp + fp) if tp + fp else 0.0
        rec = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
        print(f"{cat:20} {prec:6.2f} {rec:6.2f} {f1:6.2f}  {tp+fn}")


if __name__ == "__main__":
    main()
