# Contributing to Omacy

Thanks for your interest in contributing.

## Before You Start

- Read [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
- Read [`TRADEMARKS.md`](TRADEMARKS.md).

## Contribution Process

1. Open an issue or pull request that explains the problem or change.
2. Keep changes focused and reviewable.
3. Add or update tests when the change affects engine or conversion behavior.
4. Run the relevant build and test commands before asking for review.

## Build and Test

Engine:

```bash
cargo test --workspace --all-targets
cargo xtask header check
```

Vendored ttfx (after engine patches):

```bash
cargo test --manifest-path vendor/ttfx/Cargo.toml
scripts/verify-ttfx-vendor.sh
scripts/test-verify-ttfx-vendor.sh
```

Mac host and screensaver appex:

```bash
xcodebuild -project apps/Omacy/Omacy.xcodeproj -scheme Omacy \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build
```

Swift unit tests:

```bash
xcodebuild -project apps/Omacy/Omacy.xcodeproj -scheme Omacy \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  test
```

CI runs those same checks: `.github/workflows/engine.yml` on Ubuntu, `.github/workflows/macos.yml` on `macos-26`.

## Code Signing

The Xcode project commits `DEVELOPMENT_TEAM = 25TVW8MSGJ`, which is Zenjoy’s Apple Developer team. The team ID itself is not a secret — it ships inside every signed macOS binary — but only Zenjoy can sign with it.

External contributors building locally should override it with their own team, or skip signing:

```bash
xcodebuild -project apps/Omacy/Omacy.xcodeproj -scheme Omacy \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=YOURTEAMID CODE_SIGN_STYLE=Automatic build
```

Do not commit a local change to `DEVELOPMENT_TEAM`.

Official Developer ID profiles live in a private match repo. Maintainers hydrate Fastlane env from 1Password; contributors do not need that. See `fastlane/.env.example` if you are doing a release.

## Project Notes

- Omacy is a native macOS app plus a `com.apple.screensaver` appex.
- The appex uses undocumented ScreenSaver.framework classes. See `apps/Omacy/OmacyScreensaver/PrivateHeaders/ScreenSaverPrivate.h` and `apps/Omacy/BACKGROUND.md`.
- Put the built app in `/Applications` before registering the extension. The host refuses random paths.
- Public configuration lives at `~/.config/omacy/{screensaver.txt,settings.json}`. Swift owns validation, private last-good caching, and legacy migration; Rust must remain free of configuration I/O.
- The extension is read-only for those two public files and must not regain an App Group entitlement or a canonical/shared-file write path. Each process may keep a private cache inside its own sandbox; host and extension caches are never shared. Repeated signed launches must not produce a file-access prompt.
- `screensaver.txt` and `settings.json` are independent replacement units. Preserve valid new data from either file when the other is missing or invalid.
- Configuration is sampled at effect boundaries, with no filesystem watcher. Keep boundary updates atomic through `omacy_session_begin_next_with_config`.
- `OmacyEngineSession`, `OmacyMetalGridRenderer`, and `OmacyDisplayLinkDriver` own the FFI, Metal, and clock/lifecycle boundaries respectively. Keep `OmacyRenderer` focused on orchestration.
- The generated header is committed at `crates/omacy-engine/include/omacy.h`. Change ABI declarations in Rust/cbindgen config, run `cargo xtask header write`, and include the generated diff; never hand-edit it.
- Default art and conversion fixtures are committed under `assets/`. `vendor/ttfx` is a checked-in patched snapshot, not a submodule. Update `PIN`, the normalized patch, and the snapshot together, then run both vendor verifier scripts.
- Shipping targets Apple silicon only. Do not add `x86_64` or universal output without an explicit architecture decision.
- `apps/Omacy/LICENSE` is the MIT license from [AppexSaverMinimal](https://github.com/AerialScreensaver/AppexSaverMinimal) (Guillaume Louel). Keep that copyright on files that still carry it.

## Releases

Maintainers ship a signed GitHub release with:

```bash
bundle exec fastlane release
```

That archives an arm64 Developer ID build, notarizes a DMG, signs a Sparkle appcast, tags, and publishes `Omacy.dmg` plus `appcast.xml` to GitHub Releases. Sparkle presents signed updates for user approval; it is not a silent install. Pass `version:0.1.1` to skip the version prompt. Pass `channel:beta` for a prerelease.

The Sparkle feed is `https://github.com/dedene/omacy/releases/latest/download/appcast.xml`. No extra host. The repo must stay public or Sparkle cannot fetch updates.

## Licensing Expectations

By contributing to Omacy, you are contributing to a project published under MIT.
