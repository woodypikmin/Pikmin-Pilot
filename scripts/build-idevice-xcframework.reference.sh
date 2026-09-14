#!/bin/bash
set -euxo pipefail

# Reference recipe for the iPhone-only Stage 7.1.3 build.
PIN="${IDEVICE_PIN:-c65dfbf}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
CACHE="$ROOT/.build/idevice"
OUT="$ROOT/Vendor/IDevice/IDevice.xcframework"
HEADERS="$ROOT/Vendor/IDevice/include"

rm -rf "$CACHE" "$OUT" "$HEADERS"
mkdir -p "$ROOT/.build" "$HEADERS"

git clone https://github.com/jkcoxson/idevice.git "$CACHE"
cd "$CACHE"
git checkout "$PIN"
rustup target add aarch64-apple-ios

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$SDK" \
IPHONEOS_DEPLOYMENT_TARGET=17.4 \
cargo build \
  -p idevice-ffi \
  --release \
  --locked \
  --target aarch64-apple-ios \
  --no-default-features \
  --features "obfuscate,ring,core_device,tunnel_tcp_stack,dvt"

LIB="target/aarch64-apple-ios/release/libidevice_ffi.a"
test -f "$LIB"
cp ffi/idevice.h "$HEADERS/idevice.h"

xcodebuild -create-xcframework \
  -library "$LIB" \
  -headers "$HEADERS" \
  -output "$OUT"
