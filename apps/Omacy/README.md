# Omacy Mac host

Xcode project for the host app and `com.apple.screensaver` appex.

Build on macOS 15+ (deployment target 15.0). PaperSaver 0.2.0 needs Swift 6.2, so resolving packages wants Xcode 26. The “Build Rust engine” phase runs `scripts/build-engine.sh` and links `libomacy_engine.a` into both targets.

## Run

1. Set a Development Team on both targets.
2. Build the Omacy scheme.
3. For iteration, stay in DerivedData **or** copy the app to `/Applications` — not both.
4. Use the host to register (`pluginkit`) and enable (PaperSaver). Registration from a random path is refused.
5. Preview in the host. Idle / System Settings listing is the canary gate: see `docs/macos-gates.md` in the repo root.

Force the asymmetric fixture (no engine) with UserDefaults `omacy.forceCanary`.

App Group: `group.be.zenjoy.omacy` (`screensaver.txt`, `settings.json`).
