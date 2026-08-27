# macOS canary and idle gates

This Linux environment cannot compile Swift, sign an appex, or run ScreenSaverEngine. The engine is proven here with `cargo test`. GitHub Actions `macos.yml` compiles the host `.app` and screensaver `.appex` (unsigned/ad-hoc). The following architecture acceptance table remains a **Mac gate** and is not claimed by this change.

Host sources now include last-known-good App Group writes, stop-before-start lifecycle, Metal→CALayer canary fallback, occupancy constants, atlas white-pixel UVs, dead-session recreate, pending-config on save, uninstall “move Omacy to Trash” copy, About credit, and missing/unelected appex recovery. Those still need a Mac to execute.

| Check | Status here |
|---|---|
| Host + appex compile (Xcode, ad-hoc) | `macos-26` + PaperSaver + cargo got to Swift. Failed on `displayLink` (non-optional) and `Int(omacy_status)`. Fix pending this run |
| Install: DMG → `/Applications` or Xcode DerivedData | Unverified |
| Discover: listed with first-party savers in System Settings | Unverified |
| Thumbnail 107×65 / 214×130 | Landscape canary fixture PNGs present; System Settings listing unverified |
| Enable via PaperSaver `setScreensaverEverywhere` and Settings | Sources present; unverified |
| Idle activation on macOS 26 | Unverified |
| Multi-display paints the fixture / engine | Unverified |
| Teardown: `willstop` / window-nil; no leak after Settings open/close | Unverified |
| Uninstall: host unregisters; does not delete the bundle | Unverified |
| Recovery: missing/unelected appex | Unverified |
| macOS 15 repeat | Deferred until a box exists |

If the canary does not appear in System Settings, activate on idle, and paint every display, stop putting the engine in the appex. The host preview remains the fallback product.

Force the fixture grid (no engine) with UserDefaults key `omacy.forceCanary`.
