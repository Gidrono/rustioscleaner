#!/usr/bin/env bash
# Build CleanerCore.xcframework + Swift UniFFI bindings for the iOS app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
OUT="$ROOT/ios/Frameworks"
GEN="$ROOT/ios/Generated"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$CORE/target}"

mkdir -p "$OUT" "$GEN"
cd "$CORE"

echo "==> Building cleaner-ffi (host + iOS device + simulator)"
cargo build -p cleaner-ffi --release
cargo build -p cleaner-ffi --release --target aarch64-apple-ios
cargo build -p cleaner-ffi --release --target aarch64-apple-ios-sim

HOST_LIB="$CARGO_TARGET_DIR/release/libcleaner_ffi.dylib"
DEVICE_LIB="$CARGO_TARGET_DIR/aarch64-apple-ios/release/libcleaner_ffi.a"
SIM_LIB="$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libcleaner_ffi.a"

echo "==> Generating Swift bindings"
rm -rf "$GEN"
mkdir -p "$GEN"
cargo run -p cleaner-ffi --bin uniffi-bindgen --release -- \
  generate --library "$HOST_LIB" --language swift --out-dir "$GEN"

echo "==> Packaging CleanerCore.xcframework"
rm -rf "$OUT/CleanerCore.xcframework"
STAGE="$OUT/_stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/ios-arm64/Headers" "$STAGE/ios-arm64-simulator/Headers"
cp "$DEVICE_LIB" "$STAGE/ios-arm64/libcleaner_ffi.a"
cp "$SIM_LIB" "$STAGE/ios-arm64-simulator/libcleaner_ffi.a"
cp "$GEN/cleaner_ffiFFI.h" "$STAGE/ios-arm64/Headers/"
cp "$GEN/cleaner_ffiFFI.h" "$STAGE/ios-arm64-simulator/Headers/"
cat > "$STAGE/ios-arm64/Headers/module.modulemap" <<'MM'
module cleaner_ffiFFI {
    header "cleaner_ffiFFI.h"
    export *
}
MM
cp "$STAGE/ios-arm64/Headers/module.modulemap" "$STAGE/ios-arm64-simulator/Headers/"

xcodebuild -create-xcframework \
  -library "$STAGE/ios-arm64/libcleaner_ffi.a" \
  -headers "$STAGE/ios-arm64/Headers" \
  -library "$STAGE/ios-arm64-simulator/libcleaner_ffi.a" \
  -headers "$STAGE/ios-arm64-simulator/Headers" \
  -output "$OUT/CleanerCore.xcframework"

rm -rf "$STAGE"
echo "==> Done"
ls -la "$OUT/CleanerCore.xcframework"
ls -la "$GEN"
