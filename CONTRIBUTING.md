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
cargo test -p omacy-engine
```

Vendored ttfx (after engine patches):

```bash
cargo test --manifest-path vendor/ttfx/Cargo.toml
```

Mac host and screensaver appex:

```bash
xcodebuild -project apps/Omacy/Omacy.xcodeproj -scheme Omacy \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build
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
- Default art and conversion fixtures are committed under `assets/`. Do not vendor a floating `ttfx` master; the pin is `vendor/ttfx/PIN`.
- `apps/Omacy/LICENSE` is the MIT license from [AppexSaverMinimal](https://github.com/AerialScreensaver/AppexSaverMinimal) (Guillaume Louel). Keep that copyright on files that still carry it.

## Releases

Maintainers ship a signed GitHub release with:

```bash
bundle exec fastlane release
```

That archives a Developer ID build, notarizes a DMG, signs a Sparkle appcast, tags, and publishes `Omacy.dmg` plus `appcast.xml` to GitHub Releases. Pass `version:0.1.1` to skip the version prompt. Pass `channel:beta` for a prerelease.

The Sparkle feed is `https://github.com/dedene/omacy/releases/latest/download/appcast.xml`. No extra host. The repo must stay public or Sparkle cannot fetch updates.

## Licensing Expectations

By contributing to Omacy, you are contributing to a project published under MIT.
