# Omacy Mac host

Public product docs live in the [repo root README](../../README.md). This file is the host/appex build notes.

Xcode project for the host app and `com.apple.screensaver` appex.

Build on macOS 15+ (deployment target 15.0). PaperSaver 0.2.0 needs Swift 6.2, so resolving packages wants Xcode 26. The appex target’s “Build Rust engine” phase runs `scripts/build-engine.sh` once; the host depends on the appex and links the same `libomacy_engine.a`.

## Run

1. Team is `25TVW8MSGJ` (Zenjoy). Sync Developer ID profiles with `bundle exec fastlane mac generate_signing` (once) or `mac sync_signing` (readonly).
2. Build the Omacy scheme.
3. For iteration, stay in DerivedData **or** copy the app to `/Applications` — not both.
4. Use the host to register (`pluginkit`) and enable (PaperSaver). Registration from a random path is refused.
5. Preview in the host. Idle / System Settings listing is the canary gate: see `docs/macos-gates.md` in the repo root.

Force the asymmetric fixture (no engine) with UserDefaults `omacy.forceCanary`.

App Group: `group.be.zenjoy.omacy` (`screensaver.txt`, `settings.json`).
