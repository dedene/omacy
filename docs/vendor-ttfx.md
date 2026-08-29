# ttfx vendor contract

`vendor/ttfx` is a checked-in, patched snapshot of
[`omacom-io/ttfx`](https://github.com/omacom-io/ttfx). It is not a submodule.
The authoritative provenance is `vendor/ttfx/PIN`:

- exact upstream repository, tag, full commit SHA, and import date;
- exact TTE repository, tag, and full commit SHA;
- the normalized Omacy patch path and its complete file allowlist.

## Local-change policy

The patch may expose engine seams needed by the screensaver: packed grid
snapshots, GUI terminal configuration, simulation advancement without ANSI,
and effect registry lookup. Its exact allowlist is recorded in `PIN`.

Do not modify individual implementations in `src/effects/*.rs`. Omacy relies on
upstream effect behavior and tests parity separately. `src/effects/mod.rs` is
allowed only as a registry seam.

## Verify the snapshot

Run:

```sh
scripts/verify-ttfx-vendor.sh
scripts/test-verify-ttfx-vendor.sh
```

The verifier clones the pinned upstream commit into a temporary directory,
applies the normalized patch, rejects individual effect-file changes, and
compares the reconstruction with the checked-in snapshot. It never modifies
the repository. It also checks the TTE repository and commit against ttfx's
pinned parity harness, and checks the TTE tag, commit, and MIT notice against
ttfx's `NOTICE`. This validates the metadata from the pinned ttfx source without
fetching a second upstream repository. For an offline/local mirror:

```sh
TTFX_UPSTREAM_SOURCE=/path/to/ttfx scripts/verify-ttfx-vendor.sh
```

## Update procedure

1. Clone the candidate upstream release into `/tmp` and verify its tag and full
   commit SHA.
2. Apply the existing Omacy patch. Resolve changes only in the allowlisted
   engine seams; never carry local changes into individual effects.
3. Run the ttfx tests and Omacy's parity/golden suites against the candidate.
4. Replace `vendor/ttfx` from the clean temporary checkout, excluding `.git`.
5. Regenerate `vendor/patches/ttfx-omacy.patch` with
   `git diff --binary` from the exact pinned commit.
6. Update `vendor/ttfx/PIN`, including repository, tag, full SHA, import date,
   TTE repository/tag/SHA, normalized patch path, and exact path allowlist.
7. Run the verifier and review the complete patch before accepting the update.

Rollback by restoring the previous snapshot, `PIN`, and patch together. These
three artifacts are one provenance unit.

## Licensing

ttfx and TerminalTextEffects are MIT-licensed. Preserve
`vendor/ttfx/LICENSE` and all upstream copyright and notice text when importing
or updating the snapshot. Before accepting a new snapshot, verify that its
license and notices still permit redistribution and that the checked-in copies
match the pinned upstream release.
