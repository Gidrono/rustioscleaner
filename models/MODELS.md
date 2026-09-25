# Models

All shipped and optional weights must be **Apache-2.0, MIT, or equivalently permissive**. Do not vendor Qwen (or other) checkpoints whose license forbids open redistribution without checking the specific size’s terms.

## Bundled (app binary)

| Artifact | Role | Approx size | License |
|---|---|---|---|
| `SigLIPAesthetic.mlmodelc` | Image embedding + aesthetic head | 100–200 MB palettized | Depends on base (prefer Apache SigLIP) |
| `junk_prompts.json` | Precomputed text embeddings for zero-shot junk labels | <1 MB | Same as embedding model |

Conversion: `models/scripts/convert_siglip_coreml.py`

Until a converted model is present, `EmbeddingAnalyzer` uses a deterministic stub so CI and simulators still exercise clustering.

## Optional download (Settings → VLM)

| Artifact | Role | Approx size | License gate |
|---|---|---|---|
| SmolVLM2 4-bit (MLX) | Tier-3 ephemeral utility classification | ~1–2 GB | Apache-2.0 preferred |

Pinned via `ios/App/Resources/vlm_manifest.json`:

```json
{
  "repo": "...",
  "revision": "<git sha>",
  "filename": "...",
  "sha256": "<hex>",
  "license": "Apache-2.0",
  "minRamGB": 6
}
```

The app refuses to install if SHA256 mismatches. Placeholder zeros in the committed manifest intentionally block accidental downloads until a real pin is published.

## Prompt set (zero-shot junk)

See `models/prompts/junk_prompts.txt`. Keep prompts concrete and visual (“a photo of a parking garage pillar”), not abstract.

## Checksums

Publish SHA256 for every binary artifact in release notes. Example:

```
# sha256sum SigLIPAesthetic.mlmodelc
```

## Training the aesthetic head

`models/scripts/train_aesthetic_head.py` sketches an MLP on frozen SigLIP embeddings using AVA / LAION-style scores. Keep the head tiny so Neural Engine latency stays low.
