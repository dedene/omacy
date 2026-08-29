#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
VERIFY="$ROOT/scripts/verify-screensaver-entitlements.sh"
SOURCE="$ROOT/apps/Omacy/OmacyScreensaver/OmacyScreensaver.entitlements"
FIXTURE=$(mktemp -d /tmp/omacy-entitlement-contract.XXXXXX)

expect_rejected() {
  plist=$1
  reason=$2
  if "$VERIFY" "$plist" >"$FIXTURE/$reason.output" 2>&1; then
    echo "FAIL: entitlement fixture '$reason' was accepted" >&2
    exit 1
  fi
}

"$VERIFY" "$SOURCE" >/dev/null

cp "$SOURCE" "$FIXTURE/app-groups.plist"
plutil -insert 'com\.apple\.security\.app-groups' -array "$FIXTURE/app-groups.plist"
expect_rejected "$FIXTURE/app-groups.plist" app-groups

cp "$SOURCE" "$FIXTURE/home-write.plist"
plutil -insert 'com\.apple\.security\.temporary-exception\.files\.home-relative-path\.read-write' -array "$FIXTURE/home-write.plist"
expect_rejected "$FIXTURE/home-write.plist" home-write

cp "$SOURCE" "$FIXTURE/wrong-paths.plist"
plutil -replace 'com\.apple\.security\.temporary-exception\.files\.home-relative-path\.read-only.0' \
  -string '/.config/omacy/other.txt' "$FIXTURE/wrong-paths.plist"
expect_rejected "$FIXTURE/wrong-paths.plist" wrong-paths

echo "screensaver entitlement contract regressions: PASS"
