# Context Cleaner

Privacy-first, on-device photo culling for iOS 18+. Evaluates **human intent** behind a photo — not just pixel similarity — and helps you toss utility junk, social misses, and weaker shots in a burst.

**MIT licensed · no accounts · no analytics · deletes go to Recently Deleted**

## Why this exists

Apple’s native duplicate finder is pixel-matching. Proprietary “cleaner” apps are predatory freemium. Context Cleaner runs a cascade of local models so heavy work only happens while charging, and every suggestion explains *why*.

| Capability | How |
|---|---|
| Utility junk | Vision text/barcode/document + SigLIP zero-shot + optional VLM |
| Social misses | Face landmarks (blink, looking away; mouth-open experimental) |
| Best-of-burst | Aesthetic + face quality + sharpness − miss penalty |
| Keep / Toss UI | Swipe cards with reason chips and batched delete |

## Architecture

```
SwiftUI shell  →  PhotosKit / Vision / Core ML / MLX
       ↕ UniFFI
Rust core      →  signals, fusion, clustering, ranking, SQLite, scheduler
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the analysis cascade and thermal policy.

## Requirements

- macOS with Xcode 16+
- Rust stable (`rustup`)
- iOS 18+ device or simulator (A15+ recommended; VLM needs ≥6 GB RAM)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build

```bash
# 1. Rust core + XCFramework + Swift bindings
./scripts/build-xcframework.sh

# 2. Generate & open the iOS project
cd ios && xcodegen generate
open ContextCleaner.xcodeproj
```

Select your Development Team in Xcode, then Run on a device (PhotoKit needs a real library for a meaningful demo).

### Rust-only (fast iteration)

```bash
cd core
cargo test --workspace
cargo run -p cleaner-cli -- weights
```

## Privacy

Photos never leave the device. The **only** network path is an **opt-in**, checksum-verified VLM weight download. Details: [PRIVACY.md](PRIVACY.md).

## Models

Bundled Core ML (SigLIP + aesthetic head) and optional VLM weights are documented in [models/MODELS.md](models/MODELS.md). Conversion scripts live under `models/scripts/`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Fusion weights are TOML-tunable without touching Rust:

```bash
cargo run -p cleaner-cli -- weights > my-weights.toml
# edit, then load via CleanerEngine.setWeightsToml in the app
```

## License

[MIT](LICENSE) © 2026 Gidi Hanoch
