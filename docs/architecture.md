# Omacy Screensaver

macOS screensaver that replays Omarchy’s ASCII text-effects loop: a logo (or any text), animated by the 37 Terminal Text Effects, hosted as a real System Settings screensaver.

Stack: **patched `ttfx` → C ABI cell grid → Metal renderer → host app + `.appex`.**

Revision 2 of this design. Implementation starts only after this revision is accepted.

Companion contracts: [ffi.md](ffi.md) (ABI, threading, occupancy, origin) and [parity.md](parity.md) (pins, clock, 37-effect matrix).

## Goal

When the Mac idles, every connected display runs a `ttfx` effect on a centered ASCII/Braille logo against a black field, then the next effect. Speed is the same on a 60 Hz display and a 120 Hz ProMotion display.

Configuration lives in the **host app**: paste art, generate art from a PNG/SVG, pick an effect or random, restore the default wordmark. System Settings shows the saver, its thumbnail, and (later) a thin sheet for effect choice — not the image converter. The converter needs `NSOpenPanel`; the appex sandbox did not present that panel.

Fidelity is **measured**, not vibed. Motion is cell-grid identity against pinned `ttfx` for all 37 effects. Image conversion is byte identity against goldens produced by pinned Omarchy `omarchy-transcode-ascii`. Font rasterization is allowed to differ. See [parity.md](parity.md).

## Non-goals (MVP)

- Wrapping a terminal or spawning the `ttfx` CLI.
- Reimplementing the 37 effects.
- Legacy `.saver` as the shipping format.
- Wallpaper-continuity / lock-screen stills.
- Python TTE, ImageMagick at runtime, effect exclude-lists, per-effect knobs.
- Filesystem watchers. Settings reload at session start and at effect boundaries only.
- A separate `omacy-ascii` crate. Conversion stays an internal engine module until a second consumer exists.
- A worker-thread renderer. Tick stays on the display-link thread until Instruments says otherwise.

## Locked decisions

| Decision | Choice | Why |
|---|---|---|
| Host | Host `.app` + `com.apple.screensaver` `.appex` | Aerial 4 path; `.saver` is rotting on Tahoe |
| Canary | Signed appex with a fixed grid, before the engine | Private API is the product risk; a preview app is not the product |
| Engine | Vendor `ttfx`, patch, don’t rewrite | Byte-identical to TTE v0.15.0; already builds on macOS |
| Frame contract | C ABI, packed cells, no UniFFI | Zero-copy upload; UniFFI would serialize every cell |
| Occupancy | Background and glyph are independent flags | A blank glyph can still carry a background |
| Origin | Top-left, rows increase downward | Terminal-internal order is not the ABI |
| Simulation | Fixed 60 Hz steps, vsync presents | Speed must not track the display |
| Draw path | Metal glyph atlas + instanced quads | Core Text per cell per frame would dominate CPU |
| Display link | `NSView.displayLink(target:selector:)` | AppKit API; not a UIKit window-scene link |
| Settings | App Group; reload at start + effect boundary | Host and appex are different processes; no kqueue |
| Image convert | Internal engine module, host-only UI | One consumer; `NSOpenPanel` is in the app |
| Effect pool | All 37, no excludes | Matches current Omarchy `omarchy-screensaver` |
| OS floor | macOS 15; develop on 26 | Appex since Sonoma; Peter is on Tahoe |
| Displays | One session per saver view | Omarchy launches one `ttfx` per monitor |

Private API is accepted and **gated**. If the canary does not appear in System Settings, activate on idle, and paint every display on macOS 26 (and 15 when we have a box), we stop. The host preview remains a fallback product, not a substitute for the gate.

## System shape

```
Omacy.app  (SwiftUI chrome: preview, install/enable, config)
  Preview:  NSView  ──► OmacyRenderer
  PlugIns/Omacy.appex
    ScreenSaverView ──► OmacyRenderer ──► ScreenSaverEngine / WallpaperAgent

OmacyRenderer
  layout → session.step(elapsed) → Metal upload
       │
       ▼
libomacy_engine.a   (serialized session, 60 Hz accumulator)
       ├─ vendored ttfx
       └─ ascii module (PNG/SVG → text; host config only)
```

`OmacyRenderer` is a controller, not a view. It owns the Metal stack, the session pointer, layout math, and the display-link target. Two views compose it:

- `OmacyHostView: NSView` — in-app preview.
- `OmacySaverView: ScreenSaverView` — appex.

They do not share a view subclass. They share the renderer.

Three drawing contexts:

1. **Host preview** — ordinary window. Always works. Engine development surface.
2. **System Settings preview** — appex, small bounds. Same font size as fullscreen, so fewer cells; presentation capped at 30 Hz.
3. **Idle fullscreen** — one saver view per display, vsync, full quality.

## Repo layout

```
omacy-screensaver/
  apps/Omacy/              Xcode: host + appex + OmacyRenderer
  crates/omacy-engine/     session, FFI, ascii module, links ttfx
  vendor/ttfx/             git submodule, pinned commit + our patches
  assets/
    branding/screensaver.txt
    fonts/                 OFL monospace with full Braille
    fixtures/              conversion + grid-parity goldens
  docs/
    architecture.md
    ffi.md
    parity.md
```

Xcode does not compile Rust ad hoc in the appex. A build phase runs `cargo build --release --target aarch64-apple-darwin` and links `libomacy_engine.a`. `cbindgen` emits the header in [ffi.md](ffi.md).

## Simulation clock

`ttfx` advances one effect step per `advance`/`next_frame`. Its `--frame-rate` only sleeps. Calling `advance` once per display callback therefore runs most effects at the display’s Hz.

**Contract:** simulation is 60 Hz, the TTE/ttfx default, independent of presentation.

Omarchy’s screensaver passes `--frame-rate 120`. That is a recorded divergence: we will not run twice as fast on ProMotion, and we will not run half speed on a 60 Hz panel. Wall-clock-gated effects (`matrix`, `thunderstorm`) keep `Clock::real()`.

The accumulator lives **in the engine**, not in Swift:

- `step(elapsed_seconds)` adds `elapsed` to an accumulator.
- While accumulator ≥ 1/60 s and steps this call < 4: `advance` once, subtract 1/60 s.
- If the cap is hit, drop leftover accumulator (no spiral after a stall).
- Publish the current grid even when zero advances ran (120 Hz presents the same step twice).
- Negative, NaN, or infinite `elapsed` is `OMACY_ERR_INVALID_ARG`.
- `ttfx` tty sleep and SIGWINCH are off. Canvas size is explicit (`ignore_terminal_dimensions`, centered anchors).

## Engine patches (`vendor/ttfx`)

Small, upstreamable, parity suites stay green.

1. `Terminal::fill_grid` — occupancy + glyph + RGBA from `render_cells`. No SGR. Map ttfx’s terminal row order into ABI top-left (see [ffi.md](ffi.md)).
2. `Effect::advance` — tick without formatting. `next_frame` = `advance` + `get_formatted_output_string`.
3. GUI construction path: no tty pacing, no SIGWINCH.
4. `from_name("beams")` with struct defaults; no argv.

Do not fork effect files. Do not change RNG, easing, or painter order.

On effect completion the session starts the next effect (random from all 37, or the pinned name) **before** `step` returns. Swift always receives a grid on success. Completion is not an FFI return code.

## Renderer

Layout, from view bounds in **points** and the backing scale factor:

- Cell height = configured font size (default 18 pt, Omarchy’s screensaver override).
- Cell width = advance of `M` in the bundled font.
- `cols = floor(viewWidth / cellWidth)`, `rows = floor(viewHeight / cellHeight)`, both ≥ 1, both capped (see Limits).
- `cols * rows` uses checked multiplication; overflow is a failed resize, last grid kept.
- Remainder is black margin; the grid is centered.
- If `cols,rows` change after a 50 ms debounce, `resize` (invalidates the frame pointer).

Preview uses the **same 18 pt**. Smaller bounds ⇒ fewer cells. Do not shrink the preview font: that would increase cell count.

Tahoe may hand backing pixels as the view’s `bounds`. Compare `convertToBacking` / `backingScaleFactor` and treat an exact 2× jump as scale, not a giant canvas.

Metal:

1. Atlas once per font size: printable ASCII, Braille `U+2800…U+28FF`, block drawing used by conversion. Extra glyphs from effects rasterize lazily up to the atlas cap; beyond that, draw background only.
2. Each presented frame: walk cells. If `has_background`, instance a bg quad. If `has_glyph` and the glyph has coverage, instance a fg quad. `SPACE` with a background draws bg only. Unoccupied cells are skipped (clear color shows). Reverse swaps fg/bg.
3. Clear color = session background (`#000000`).
4. Triple-buffered instance storage. Upload **during** `step`’s return, before any other session call.

Display link: `NSView.displayLink(target:selector:)` scheduled on the current run loop. Appex `SSENeedsAnimationTimer = false`. Start when the view has a window (`viewDidMoveToWindow`, `startAnimation`); invalidate on nil window, `stopAnimation`, `deinit`, and `com.apple.screensaver.willstop`. Preferred frame rate: fullscreen max (60–120), Settings preview 30 Hz.

`CAMetalDisplayLink` is a measured alternative, not the default.

No SwiftUI in the grid. Chrome and the config sheet may use SwiftUI. The sheet is not inside the saver view.

## Appex canary (go / no-go)

Before vendoring `ttfx` into the appex, ship a signed minimal host+appex derived from [AppexSaverMinimal](https://github.com/AerialScreensaver/AppexSaverMinimal).

The canary renderer draws a **fixed** grid (asymmetric fixture: a known glyph in the top-right cell, a colored blank in the bottom-left). No `ttfx`, no config, no image loader.

Acceptance, all required:

| Check | Pass |
|---|---|
| Install | Host copies/registers the app; one location (`/Applications` or DerivedData, never both) |
| Discover | Listed with first-party savers in System Settings, not only under Other |
| Thumbnail | Landscape 107×65 / 214×130 |
| Enable | PaperSaver `setScreensaverEverywhere` and Settings both work |
| Idle | Activates on idle on the development Mac (macOS 26) |
| Multi-display | Every connected display paints the fixture |
| Teardown | `willstop` / window-nil drops Metal; no leak after open/close Settings ten times |
| Uninstall | `pluginkit -r`, app removed, saver gone from Settings after relaunch |
| Recovery | Host reports a missing/unelected appex and offers re-register |
| Version | Repeat idle + Settings on macOS 15 when a box exists; document if deferred |

Fail the gate: do not spend further effort on engine-in-appex. Keep the host preview path.

## Install, update, failure

- **Install:** `/Applications/Omacy.app`. `pluginkit -a` on the embedded appex. Host “Install” button. Ad-hoc sign for local canary; Developer ID + notarize before any other machine.
- **Enable:** PaperSaver + a Settings instruction. Record which displays were set.
- **Update:** replace the app in the same path, re-register. PlugInKit sticks to `/Applications` if both copies exist.
- **Uninstall:** unregister, delete the app. Offer to wipe the App Group.
- **Failure:** last-known-good `settings.json` + `screensaver.txt` (write temp, `rename`). Invalid files fall back to bundled defaults and surface an error in the host. A dead session (`OMACY_ERR_PANIC`) is destroyed and recreated with last-known-good.

## Settings

App Group `group.be.zenjoy.omacy`:

```
screensaver.txt
settings.json
```

```json
{
  "effect": "random",
  "fontSize": 18,
  "asciiMode": "braille",
  "threshold": 50,
  "invert": false,
  "background": "#000000"
}
```

No `exclude` key in MVP. `effect` is `"random"` or a `ttfx` name.

The session is created with a config directory path. It reads and validates those files at **create** and when an effect completes, before starting the next. Failed reads keep the in-memory last-known-good. No dispatch source, no `NSFileCoordinator` watcher.

Image import, threshold, invert, mode, and paste-from-text run in the host app. Saving writes the App Group and, if a preview session exists, `set_next_config` / recreate. The System Settings sheet, when added, can change `effect` and restore default art only.

## Image → ASCII

Internal module of `omacy-engine`. Host config UI calls it through the FFI text allocators in [ffi.md](ffi.md). The appex never sees image bytes.

Pipeline matches pinned `omarchy-transcode-ascii`: alpha-or-luma, invert, trim, resize (braille `w*2 × h*4`, block `w × h*2`), threshold, pack. Goldens are byte-identical to that script on `assets/fixtures/` — not a “visual match.”

SVG: `resvg` with **no** external resources, scripts, network, file references, or external fonts.

## Resource limits

All checked with `checked_mul` / explicit length tests. Breach → `OMACY_ERR_LIMIT`, no allocation of the huge object, last-known-good kept.

| Resource | Cap |
|---|---|
| ASCII input bytes | 64 KiB |
| ASCII lines | 128 |
| ASCII columns (longest line) | 256 |
| Grid width or height | 512 |
| Grid cells (`cols * rows`) | 32_768 |
| PNG / SVG file bytes | 8 MiB / 2 MiB |
| Decoded pixels | 4_194_304 (2048²) |
| SVG elements | 8_192 |
| Atlas glyphs beyond preload | 256 |

Preload is ASCII `0x20–0x7E` + Braille block + conversion block characters. Particle glyphs that miss the atlas after the cap draw background only.

## Lifecycle

- `stopAnimation` may not run on Tahoe. Also stop in `deinit`, nil window, and `com.apple.screensaver.willstop`.
- Settings preview can leak views. `OmacyRenderer.stop` drops Metal and `omacy_session_destroy`.
- After a rebuild, re-register; `killall ScreenSaverEngine` is a documented dev hammer.

Multi-display: independent sessions, independent random picks, shared App Group files.

## Testing

| Layer | Gate |
|---|---|
| Canary | Acceptance table above, macOS 26 (15 when available) |
| `vendor/ttfx` | Upstream parity suite green after patches |
| `fill_grid` | Asymmetric fixture: top-right glyph, bottom-left colored blank; origin + occupancy |
| Engine | [parity.md](parity.md) matrix, all 37 effects |
| ASCII | Goldens vs pinned Omarchy script |
| FFI | Null, panic, limit, use-after-step pointer (Swift tests must not retain) |
| Host | Preview still runs if the appex is uninstalled |

Rust tests run on CI without a Mac. Canary and saver idle tests are local until a macOS runner exists.

## Licensing

Omacy: MIT (Peter Dedene). `ttfx` / TTE / Omarchy branding and transcode rules: MIT; keep `NOTICE`. Bundled font: SIL OFL beside the font.

About screen: “Effects by Terminal Text Effects (ChrisBuilds), Rust engine `ttfx`.”

## Delivery phases

0. **This spec** (revision 2).
1. **Appex canary.** Signed host+appex, fixed asymmetric grid, install/enable/idle/uninstall. **Go/no-go.**
2. **Engine in the host.** Vendored `ttfx`, 60 Hz `step`, Metal renderer, default wordmark, random effects, parity matrix.
3. **Engine in the canary.** Same renderer as the host, still no image UI.
4. **Host config.** Paste, PNG/SVG, threshold/invert/mode, restore default, App Group reload at boundaries.
5. **Polish.** Instruments, ProMotion present-vs-sim check, notarization, Settings sheet if still wanted.

## Risks

| Risk | Mitigation |
|---|---|
| Private appex API | Phase 1 gate; AppexSaverMinimal is the template |
| Tick-on-vsync speed bug | 60 Hz accumulator inside Rust |
| Colored blanks dropped | Occupancy flags; fixture test |
| Vertical flip | ABI origin + asymmetric golden |
| FFI races / panics | Serialized session, `catch_unwind`, no retained pointers |
| Resource bombs | Caps in the table above |
| 60 Hz vs Omarchy 120 | Recorded in parity.md; consistent across Macs |
| Braille looks wrong | Bundled OFL font, not SF Mono |
| Tahoe bounds units | Backing-scale handling |

## Out of scope until someone asks

Per-effect knobs. Exclude lists. Multiple saved logos. Color themes beyond the engine. Intel/universal. `.saver` fallback. `CAMetalDisplayLink`. Worker-thread publish buffers (if ever: immutable snapshots only; see [ffi.md](ffi.md)).
