# Omacy

A macOS screensaver that plays Omarchy’s ASCII text-effects loop: your logo (or any art), animated by the 37 Terminal Text Effects.

Rust `ttfx` engine, Swift/Metal view, Aerial-style host app + screensaver extension.

**Status:** engine tested (`cargo test -p omacy-engine`). Host `.app` + `com.apple.screensaver` `.appex` compile on Xcode 26.6. Idle / System Settings listing remains a Mac gate: [docs/macos-gates.md](docs/macos-gates.md).

Spec: [docs/architecture.md](docs/architecture.md), [docs/ffi.md](docs/ffi.md), [docs/parity.md](docs/parity.md).

## Engine

```
cargo test -p omacy-engine
```

Pins: `vendor/ttfx/PIN` is ttfx v0.3.2 (`7203e354498462064b7c0a89375051f65cf2ce99`). Default art is `assets/branding/screensaver.txt`.

## Mac host

Open `apps/Omacy/Omacy.xcodeproj` on macOS 15+. The Xcode build phase runs `apps/Omacy/scripts/build-engine.sh`, which builds `libomacy_engine.a` for `aarch64-apple-darwin` and links it into the app and the appex.

CI compiles that same scheme on `macos-26` (unsigned; deployment target 15.0). Idle / System Settings listing remains a machine gate: [docs/macos-gates.md](docs/macos-gates.md).

Put `Omacy.app` in `/Applications`, then use the host to register the extension (`pluginkit`) and enable it (PaperSaver). The host will not register from a random path.

Configuration (paste art, PNG/SVG conversion, effect, restore default) lives in the host and writes App Group `group.be.zenjoy.omacy`.

## Signing

Developer ID uses Zenjoy team `25TVW8MSGJ` and the same match repo as Zentty (`zentty-certificates`). Profiles:

- `match Direct be.zenjoy.omacy macos`
- `match Direct be.zenjoy.omacy.screensaver macos`

```
bundle exec fastlane mac generate_signing   # once, or to renew
bundle exec fastlane mac sync_signing       # readonly install
bundle exec fastlane mac archive            # Developer ID export
bundle exec fastlane mac notarize_app
```

Env: copy `fastlane/.env.example` or reuse Zentty’s 1Password item (`Zentty Release Environment`).

## Credits

The motion is [Terminal Text Effects](https://github.com/ChrisBuilds/terminaltexteffects) by ChrisBuilds, running on [ttfx](https://github.com/omacom-io/ttfx), the Rust port Omarchy ships. Both are MIT. The Linux wrapper this copies is [Omarchy](https://github.com/basecamp/omarchy), also MIT. The bundled font is Fairfax HD by Kreative Software, SIL OFL.

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Font: [assets/fonts/OFL.txt](assets/fonts/OFL.txt).
