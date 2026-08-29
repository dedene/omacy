#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BUILD_SCRIPT="$SCRIPT_DIR/build-engine.sh"
FIXTURE=$(mktemp -d /tmp/omacy-build-engine-contract.XXXXXX)
# CI and macOS clean their temporary roots. Leaving this tiny fixture avoids a
# platform-specific trash dependency and keeps repository deletes out of tests.

cat > "$FIXTURE/cargo" <<'EOF'
#!/bin/sh
touch "$CARGO_WAS_INVOKED"
exit 99
EOF
chmod +x "$FIXTURE/cargo"

assert_rejected() {
  value=$1
  label=$2
  marker="$FIXTURE/cargo-$label"
  output="$FIXTURE/output-$label"
  if env ARCHS="$value" CARGO_HOME="$FIXTURE" CARGO_WAS_INVOKED="$marker" \
    SRCROOT="$SCRIPT_DIR/.." BUILT_PRODUCTS_DIR="$FIXTURE/products" \
    PATH="$FIXTURE:/usr/bin:/bin" "$BUILD_SCRIPT" >"$output" 2>&1; then
    echo "FAIL: ARCHS='$value' was accepted" >&2
    exit 1
  fi
  if [ -e "$marker" ]; then
    echo "FAIL: cargo was invoked for ARCHS='$value'" >&2
    exit 1
  fi
  if ! grep -q "supports exactly ARCHS=arm64" "$output"; then
    echo "FAIL: ARCHS='$value' did not produce the actionable architecture error" >&2
    cat "$output" >&2
    exit 1
  fi
}

assert_rejected "" empty
assert_rejected "x86_64" x86_64
assert_rejected "arm64 x86_64" multi

echo "build-engine architecture contract: PASS"
