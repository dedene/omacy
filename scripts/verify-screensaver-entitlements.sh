#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_ENTITLEMENTS=${1:-"$ROOT/apps/Omacy/OmacyScreensaver/OmacyScreensaver.entitlements"}
BUILT_BINARY=${2:-}

verify_plist() {
  /usr/bin/ruby -rjson - "$1" <<'RUBY'
path = ARGV.fetch(0)
plist = JSON.parse(IO.popen(["plutil", "-convert", "json", "-o", "-", path], &:read))

expected_paths = [
  "/.config/omacy/screensaver.txt",
  "/.config/omacy/settings.json"
]
read_key = "com.apple.security.temporary-exception.files.home-relative-path.read-only"

abort "FAIL: #{path} must not contain com.apple.security.app-groups" if plist.key?("com.apple.security.app-groups")

write_home_keys = plist.keys.select do |key|
  key.include?(".files.home-relative-path.") && key != read_key
end
unless write_home_keys.empty?
  abort "FAIL: #{path} contains write-capable home exceptions: #{write_home_keys.join(", ")}"
end

actual_paths = plist[read_key]
unless actual_paths == expected_paths
  abort "FAIL: #{path} read-only paths must equal #{expected_paths.inspect}; got #{actual_paths.inspect}"
end
RUBY
}

verify_plist "$SOURCE_ENTITLEMENTS"
echo "screensaver source entitlement contract: PASS"

if [ -n "$BUILT_BINARY" ]; then
  EXTRACTED=$(mktemp /tmp/omacy-built-entitlements.XXXXXX)
  if ! codesign -d --entitlements :- "$BUILT_BINARY" >"$EXTRACTED" 2>/dev/null; then
    echo "FAIL: could not inspect built binary entitlements: $BUILT_BINARY" >&2
    exit 1
  fi
  if [ -s "$EXTRACTED" ]; then
    if ! plutil -lint "$EXTRACTED" >/dev/null; then
      echo "FAIL: codesign returned malformed entitlements for signed binary: $BUILT_BINARY" >&2
      exit 1
    fi
    verify_plist "$EXTRACTED"
    echo "screensaver built entitlement contract: PASS"
  else
    echo "screensaver built entitlement contract: SKIP (binary is unsigned or has no extractable entitlements)"
  fi
fi
