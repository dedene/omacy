#!/bin/sh
# Xcode run script: build libomacy_engine.a for the active Mac architecture.
set -euo pipefail
ROOT="${SRCROOT}/../.."
cd "$ROOT"
ARCHS_EFFECTIVE="${ARCHS:-arm64}"
case "$ARCHS_EFFECTIVE" in
  *arm64*) RUST_TARGET="aarch64-apple-darwin" ;;
  *x86_64*) RUST_TARGET="x86_64-apple-darwin" ;;
  *) RUST_TARGET="aarch64-apple-darwin" ;;
esac
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
rustup target add "$RUST_TARGET" >/dev/null 2>&1 || true
cargo build --release --target "$RUST_TARGET" -p omacy-engine
mkdir -p "${BUILT_PRODUCTS_DIR}"
cp -f "target/${RUST_TARGET}/release/libomacy_engine.a" "${BUILT_PRODUCTS_DIR}/libomacy_engine.a"
