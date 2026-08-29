#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
readonly SCRIPT_DIR
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
readonly REPO_ROOT
readonly VERIFIER="$SCRIPT_DIR/verify-ttfx-vendor.sh"
readonly BASE_PIN="$REPO_ROOT/vendor/ttfx/PIN"

fail() {
  printf 'ttfx verifier self-test failed: %s\n' "$*" >&2
  exit 1
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/omacy-ttfx-verifier-tests.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT HUP INT TERM

expect_pin_failure() {
  name=$1
  expected=$2
  pin=$3
  if TTFX_PIN_FILE="$pin" TTFX_VERIFY_PIN_ONLY=1 "$VERIFIER" >"$tmp_dir/$name.out" 2>"$tmp_dir/$name.err"; then
    fail "$name unexpectedly passed"
  fi
  grep -Fq "$expected" "$tmp_dir/$name.err" || {
    sed -n '1,80p' "$tmp_dir/$name.err" >&2
    fail "$name returned the wrong diagnostic"
  }
  printf '%s: PASS\n' "$name"
}

cp "$BASE_PIN" "$tmp_dir/duplicate.pin"
printf 'upstream_tag=v0.3.2\n' >>"$tmp_dir/duplicate.pin"
expect_pin_failure duplicate-key 'exactly one upstream_tag entry (found 2)' "$tmp_dir/duplicate.pin"

sed '/^tte_tag=/d' "$BASE_PIN" >"$tmp_dir/missing.pin"
expect_pin_failure missing-key 'exactly one tte_tag entry (found 0)' "$tmp_dir/missing.pin"

sed 's/^upstream_commit=.*/upstream_commit=not-a-sha/' "$BASE_PIN" >"$tmp_dir/malformed.pin"
expect_pin_failure malformed-sha 'commits must be lowercase hexadecimal SHAs' "$tmp_dir/malformed.pin"

sed 's#^local_patch=.*#local_patch=../patches/nested/../../ttfx-omacy.patch#' "$BASE_PIN" >"$tmp_dir/traversal.pin"
expect_pin_failure nested-traversal 'must be one safe .patch filename' "$tmp_dir/traversal.pin"

git init --quiet "$tmp_dir/upstream"
git -C "$tmp_dir/upstream" config user.name 'Omacy verifier test'
git -C "$tmp_dir/upstream" config user.email 'verifier@example.invalid'
git -C "$tmp_dir/upstream" commit --quiet --allow-empty -m fixture
fixture_commit=$(git -C "$tmp_dir/upstream" rev-parse HEAD)
git -C "$tmp_dir/upstream" tag aaa-other-tag "$fixture_commit"
git -C "$tmp_dir/upstream" tag zzz-configured-tag "$fixture_commit"
sed \
  -e "s#^upstream_repository=.*#upstream_repository=$tmp_dir/upstream#" \
  -e 's/^upstream_tag=.*/upstream_tag=zzz-configured-tag/' \
  -e "s/^upstream_commit=.*/upstream_commit=$fixture_commit/" \
  "$BASE_PIN" >"$tmp_dir/multi-tag.pin"
TTFX_PIN_FILE="$tmp_dir/multi-tag.pin" \
TTFX_UPSTREAM_SOURCE="$tmp_dir/upstream" \
TTFX_VERIFY_TAG_ONLY=1 \
  "$VERIFIER" >"$tmp_dir/multi-tag.out"
grep -Fq "ttfx tag verified: zzz-configured-tag ($fixture_commit)" "$tmp_dir/multi-tag.out" \
  || fail "multi-tag exact-ref test returned the wrong result"
printf 'multi-tag-exact-ref: PASS\n'

printf 'ttfx verifier self-tests: PASS\n'
