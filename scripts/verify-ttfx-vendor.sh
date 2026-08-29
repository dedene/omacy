#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
readonly SCRIPT_DIR
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
readonly REPO_ROOT
readonly VENDOR_DIR="$REPO_ROOT/vendor/ttfx"
PIN_FILE=${TTFX_PIN_FILE:-$VENDOR_DIR/PIN}
readonly PIN_FILE

fail() {
  printf 'ttfx vendor verification failed: %s\n' "$*" >&2
  exit 1
}

for tool in git diff cmp find grep mktemp sed sort uniq; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done

pin_value() {
  key=$1
  count=$(grep -c "^${key}=" "$PIN_FILE" || true)
  [ "$count" -eq 1 ] || fail "PIN must contain exactly one $key entry (found $count)"
  value=$(sed -n "s/^${key}=//p" "$PIN_FILE")
  [ -n "$value" ] || fail "PIN entry $key is empty"
  printf '%s\n' "$value"
}

UPSTREAM_URL=$(pin_value upstream_repository)
readonly UPSTREAM_URL
UPSTREAM_TAG=$(pin_value upstream_tag)
readonly UPSTREAM_TAG
UPSTREAM_COMMIT=$(pin_value upstream_commit)
readonly UPSTREAM_COMMIT
TTE_URL=$(pin_value tte_repository)
readonly TTE_URL
TTE_TAG=$(pin_value tte_tag)
readonly TTE_TAG
TTE_COMMIT=$(pin_value tte_commit)
readonly TTE_COMMIT
LOCAL_PATCH=$(pin_value local_patch)
readonly LOCAL_PATCH

case "$LOCAL_PATCH" in
  ../patches/*) patch_name=${LOCAL_PATCH#../patches/} ;;
  *) fail "PIN local_patch must name a .patch file in vendor/patches" ;;
esac
case "$patch_name" in
  ''|*/*|.|..|*[!A-Za-z0-9._-]*) fail "PIN local_patch must be one safe .patch filename in vendor/patches" ;;
  *.patch) ;;
  *) fail "PIN local_patch must name a .patch file in vendor/patches" ;;
esac
PATCH_FILE="$VENDOR_DIR/$LOCAL_PATCH"
readonly PATCH_FILE
[ -f "$PATCH_FILE" ] || fail "PIN patch does not exist: $LOCAL_PATCH"

case "$UPSTREAM_COMMIT:$TTE_COMMIT" in
  *[!0-9a-f:]*) fail "PIN commits must be lowercase hexadecimal SHAs" ;;
esac
[ "${#UPSTREAM_COMMIT}" -eq 40 ] || fail "upstream_commit must be a full 40-character SHA"
[ "${#TTE_COMMIT}" -eq 40 ] || fail "tte_commit must be a full 40-character SHA"

if [ "${TTFX_VERIFY_PIN_ONLY:-0}" = 1 ]; then
  printf 'ttfx PIN verified: %s\n' "$PIN_FILE"
  exit 0
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/omacy-ttfx-vendor.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT HUP INT TERM

# A local mirror may be supplied for offline checks. It is cloned, never modified.
source_repo=${TTFX_UPSTREAM_SOURCE:-$UPSTREAM_URL}
git clone --quiet --no-checkout -- "$source_repo" "$tmp_dir/ttfx" || fail "could not clone $source_repo"
git -C "$tmp_dir/ttfx" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null \
  || fail "pinned commit is absent from $source_repo"
tag_commit=$(git -C "$tmp_dir/ttfx" rev-parse --verify "refs/tags/$UPSTREAM_TAG^{commit}" 2>/dev/null) \
  || fail "configured tag does not exist: $UPSTREAM_TAG"
[ "$tag_commit" = "$UPSTREAM_COMMIT" ] || fail "tag $UPSTREAM_TAG resolves to $tag_commit, not $UPSTREAM_COMMIT"
git -C "$tmp_dir/ttfx" checkout --quiet --detach "$tag_commit"

resolved_commit=$(git -C "$tmp_dir/ttfx" rev-parse HEAD)
[ "$resolved_commit" = "$UPSTREAM_COMMIT" ] || fail "checkout resolved to $resolved_commit"

if [ "${TTFX_VERIFY_TAG_ONLY:-0}" = 1 ]; then
  printf 'ttfx tag verified: %s (%s)\n' "$UPSTREAM_TAG" "$UPSTREAM_COMMIT"
  exit 0
fi

# Validate TTE metadata against the pinned ttfx parity harness and notice.
parity_fetch="$tmp_dir/ttfx/tools/parity/fetch_reference.sh"
notice="$tmp_dir/ttfx/NOTICE"
[ -f "$parity_fetch" ] || fail "pinned ttfx has no TTE parity fetch script"
reference_url=$(sed -n 's/^REF_REPO="\([^"]*\)".*/\1/p' "$parity_fetch")
reference_commit=$(sed -n 's/^REF_COMMIT="\([0-9a-f]*\)".*/\1/p' "$parity_fetch")
[ "$reference_url" = "${TTE_URL%.git}" ] || fail "TTE repository disagrees with pinned ttfx parity harness"
[ "$reference_commit" = "$TTE_COMMIT" ] || fail "TTE commit disagrees with pinned ttfx parity harness"
grep -Fq "$TTE_COMMIT ($TTE_TAG)" "$notice" || fail "TTE tag/commit disagrees with pinned ttfx NOTICE"
grep -Fq 'MIT License' "$notice" || fail "pinned ttfx NOTICE no longer records the TTE MIT license"

# The documented allowlist must be exactly the set of paths in the patch.
sed -n 's/^allow=//p' "$PIN_FILE" | sort -u >"$tmp_dir/pinned-paths"
duplicate_allow=$(sed -n 's/^allow=//p' "$PIN_FILE" | sort | uniq -d | sed -n '1p')
[ -z "$duplicate_allow" ] || fail "PIN contains duplicate allow entry: $duplicate_allow"
sed -n 's#^diff --git a/[^ ]* b/##p' "$PATCH_FILE" | sort -u >"$tmp_dir/patched-paths"
cmp -s "$tmp_dir/pinned-paths" "$tmp_dir/patched-paths" || fail "PIN allowlist does not match patch paths"

# Omacy may add a registry seam in effects/mod.rs, but never fork an effect.
sed -n 's#^diff --git a/[^ ]* b/##p' "$PATCH_FILE" | while IFS= read -r path; do
  case "$path" in
    src/effects/mod.rs) ;;
    src/effects/*.rs) fail "patch modifies effect implementation: $path" ;;
  esac
done

git -C "$tmp_dir/ttfx" apply --check "$PATCH_FILE" || fail "recorded patch does not apply to the pin"
git -C "$tmp_dir/ttfx" apply "$PATCH_FILE"

# Re-emitting the working-tree diff must reproduce the committed patch byte-for-byte.
git -C "$tmp_dir/ttfx" diff --binary >"$tmp_dir/reconstructed.patch"
cmp -s "$PATCH_FILE" "$tmp_dir/reconstructed.patch" || fail "patch is not normalized against the pin"

# The PIN is local provenance metadata. Everything else must equal upstream + patch.
(
  cd "$tmp_dir/ttfx"
  find . -type f ! -path './.git/*' ! -path './PIN' -print | sort
) >"$tmp_dir/reconstructed-files"
(
  cd "$VENDOR_DIR"
  find . -type f ! -path './.git/*' ! -path './PIN' -print | sort
) >"$tmp_dir/vendor-files"
cmp -s "$tmp_dir/reconstructed-files" "$tmp_dir/vendor-files" || fail "checked-in snapshot file list differs from reconstruction"

if ! diff -ruN --exclude=.git --exclude=PIN "$tmp_dir/ttfx" "$VENDOR_DIR" >"$tmp_dir/vendor.diff"; then
  sed -n '1,240p' "$tmp_dir/vendor.diff" >&2
  fail "checked-in snapshot contains unrecorded differences"
fi

printf 'ttfx vendor verified: %s (%s) + vendor/%s\n' "$UPSTREAM_TAG" "$UPSTREAM_COMMIT" "${LOCAL_PATCH#../}"
