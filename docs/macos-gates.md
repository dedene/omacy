# macOS canary and idle gates

The engine is proven with `cargo test`. Host `.app` + screensaver `.appex` **compile** on Xcode 26 (unsigned arm64 Release) and via GitHub Actions `macos.yml` on `macos-26`. Idle / System Settings listing remains a **signed-install Mac gate** and is not claimed by CI.

Host sources include last-known-good App Group writes, stop-before-start lifecycle, Metal→CALayer canary fallback, occupancy constants, atlas white-pixel UVs, dead-session recreate, pending-config on save, uninstall “move Omacy to Trash” copy, About credit, and missing/unelected appex recovery. Those still need a signed run to execute in ScreenSaverEngine.

| Check | Status here |
|---|---|
| Host + appex compile (Xcode, ad-hoc) | **Pass** — local Xcode 26.6 `xcodebuild` Release arm64 `BUILD SUCCEEDED`; nested `OmacyScreensaver.appex` (`be.zenjoy.omacy.screensaver`, `com.apple.screensaver`) |
| Install: DMG → `/Applications` or Xcode DerivedData | Unverified |
| Discover: listed with first-party savers in System Settings | Unverified |
| Thumbnail 107×65 / 214×130 | Landscape canary fixture PNGs present; System Settings listing unverified |
| Enable via PaperSaver `setScreensaverEverywhere` and Settings | Sources present; unverified |
| Idle activation on macOS 26 | Unverified |
| Multi-display paints the fixture / engine | Code waits for ScreenSaverEngine’s per-window screen migration and uses per-window backing scale; idle paint still unverified |
| Teardown: `willstop` / window-nil; no leak after Settings open/close | Unverified |
| Uninstall: host unregisters; does not delete the bundle | Unverified |
| Recovery: missing/unelected appex | Unverified |
| macOS 15 repeat | Deferred until a box exists |

If the canary does not appear in System Settings, activate on idle, and paint every display, stop putting the engine in the appex. The host preview remains the fallback product.

Force the fixture grid (no engine) with UserDefaults key `omacy.forceCanary`.
