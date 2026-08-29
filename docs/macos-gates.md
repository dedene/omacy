# macOS canary and idle gates

The engine is proven with `cargo test`. Host `.app` + screensaver `.appex` **compile** on Xcode 26 (unsigned arm64 Release) and via GitHub Actions `macos.yml` on `macos-26`. Idle / System Settings listing remains a **signed-install Mac gate** and is not claimed by CI.

Host sources include public-file writes, independent last-known-good caching, host-only legacy App Group migration, stop-before-start lifecycle, Metal→CALayer canary fallback, dead-session recreation, and missing/unelected appex recovery. The extension has read-only exceptions for the two canonical files and no App Group entitlement. Those paths still need a signed run inside ScreenSaverEngine.

| Check | Status here |
|---|---|
| Host + appex compile (Xcode, ad-hoc) | **Pass** — local Xcode 26.6 `xcodebuild` Release arm64 `BUILD SUCCEEDED`; nested `OmacyScreensaver.appex` (`be.zenjoy.omacy.screensaver`, `com.apple.screensaver`) |
| Release install: signed/notarized DMG → `/Applications` | Unverified |
| Development build: DerivedData compile/preview, kept separate from installed registration | Compile passes; runtime preview unverified |
| Discover: listed with first-party savers in System Settings | Unverified |
| Thumbnail 107×65 / 214×130 | Landscape brand PNGs present; System Settings listing unverified |
| Enable via PaperSaver `setScreensaverEverywhere` and Settings | Sources present; unverified |
| Idle activation on macOS 26 | Unverified |
| Canonical config: saved art appears at next effect boundary | Unverified |
| Privacy: ten launches/reloads without a recurring file-access prompt | Unverified |
| Extension sandbox: reads canonical files; writes only its own private cache | Entitlements/source reviewed; signed runtime unverified |
| Multi-display paints the fixture / engine | Code waits for ScreenSaverEngine’s per-window screen migration and uses per-window backing scale; idle paint still unverified |
| Teardown: `willstop` / window-nil; no leak after Settings open/close | Unverified |
| Uninstall: host unregisters; does not delete the bundle | Unverified |
| Recovery: missing/unelected appex | Unverified |
| macOS 15 repeat | Deferred until a box exists |

If the canary does not appear in System Settings, activate on idle, and paint every display, stop putting the engine in the appex. The host preview remains the fallback product.

Force the fixture grid (no engine) with UserDefaults key `omacy.forceCanary`.

CI cannot close these gates: unsigned builds do not exercise the installed extension's sandbox, TCC decisions, PlugInKit registration, or idle process. Record the signed app version/build and macOS version when performing them.
