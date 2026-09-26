# Contributing

Thanks for helping build a trustworthy, open-source photo cleaner.

## Principles

- Privacy is non-negotiable — no analytics, no photo upload paths.
- Prefer on-device, explainable signals over opaque scores.
- Keep the cascade: cheap first, expensive last.
- Only Apache-2.0 / MIT (or compatible) model weights.

## Dev setup

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
brew install xcodegen
./scripts/build-xcframework.sh
cd ios && xcodegen generate && open RustCleaner.xcodeproj
```

## Rust workflow

```bash
cd core
cargo fmt
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo run -p cleaner-cli -- fuse path/to/record.json
```

Tune fusion without code changes by editing TOML weights and calling `setWeightsToml`.

## Swift workflow

- `PhotoBridge` — PhotosKit only
- `Analyzers` — Vision, Core ML, background scan helpers
- `VLM` — optional MLX runner + verified download
- App target owns UI + orchestration (`AppModel`)

After changing UniFFI exports:

```bash
./scripts/build-xcframework.sh
cd ios && xcodegen generate
```

## Pull requests

- Keep PRs focused (one milestone concern when possible).
- Include tests for Rust logic; UI changes should note VoiceOver impact.
- Update `MODELS.md` when model pins or licenses change.
- Never commit large weight files — document download + SHA256 instead.

## Code of conduct

Be respectful. This project exists to give people a free alternative to dark-pattern cleaners — keep that spirit in reviews and issues.
