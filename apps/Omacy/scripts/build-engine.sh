#!/bin/sh
# Xcode run script: build libomacy_engine.a for the active Mac architecture.
# Xcode script phases reset PATH to Apple's toolchain dirs, so rustup/cargo
# from the developer machine or GitHub Actions must be put back explicitly.
set -euo pipefail
CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin"
export PATH="${CARGO_BIN}:/opt/homebrew/bin:/usr/local/bin:${PATH}"
if [ -f "${HOME}/.cargo/env" ]; then
  # shellcheck source=/dev/null
  . "${HOME}/.cargo/env"
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found on PATH=${PATH}" >&2
  echo "error: install Rust 1.88.0 via rustup, then rebuild" >&2
  exit 1
fi
ROOT="${SRCROOT}/../.."
cd "$ROOT"
ARCHS_EFFECTIVE="${ARCHS:-arm64}"
case "$ARCHS_EFFECTIVE" in
  *arm64*) RUST_TARGET="aarch64-apple-darwin" ;;
  *x86_64*) RUST_TARGET="x86_64-apple-darwin" ;;
  *) RUST_TARGET="aarch64-apple-darwin" ;;
esac
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
if command -v rustup >/dev/null 2>&1; then
  rustup target add "$RUST_TARGET" >/dev/null 2>&1 || true
fi
cargo build --release --target "$RUST_TARGET" -p omacy-engine
mkdir -p "${BUILT_PRODUCTS_DIR}"
cp -f "target/${RUST_TARGET}/release/libomacy_engine.a" "${BUILT_PRODUCTS_DIR}/libomacy_engine.a"
