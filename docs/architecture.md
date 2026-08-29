# Omacy Screensaver

macOS screensaver that replays Omarchy’s ASCII text-effects loop: a logo (or any text), animated by the 37 Terminal Text Effects, hosted as a real System Settings screensaver.

Stack: **patched `ttfx` → C ABI cell grid → Metal renderer → host app + `.appex`.**

Companion contracts: [ffi.md](ffi.md) (ABI, threading, occupancy, origin) and [parity.md](parity.md) (pins, clock, 37-effect matrix).

## Goal

When the Mac idles, every connected display runs a `ttfx` effect on a centered ASCII/Braille logo against the configured background (black by default), then the next effect. Speed is the same on a 60 Hz display and a 120 Hz ProMotion display.

Configuration lives in the **host app**: paste art, generate art from a PNG/SVG, tick the idle shuffle, live-preview a highlighted effect, restore the default wordmark. System Settings shows the saver, its thumbnail, and a thin sheet — not the image converter. The converter needs `NSOpenPanel`; the appex sandbox did not present that panel.

Fidelity is **measured**, not vibed. Motion is cell-grid identity against an **independent ANSI oracle** over pinned `ttfx`, for all 37 effects. Image conversion is identity against **committed fixtures**, not a live ImageMagick replay. Font rasterization is allowed to differ. See [parity.md](parity.md).

## Non-goals (MVP)

- Wrapping a terminal or spawning the `ttfx` CLI.
- Reimplementing the 37 effects.
- Legacy `.saver` as the shipping format.
- Wallpaper-continuity / lock-screen stills.
- Python TTE, ImageMagick at runtime, per-effect knobs.
- Filesystem watchers. Settings reload at session start and at effect boundaries only.
- A separate `omacy-ascii` crate. Conversion stays an internal engine module until a second consumer exists.
- A worker-thread renderer. Production sessions live on the main thread only.
- Self-install, in-app updater, or self-delete from `/Applications`.

## Locked decisions

| Decision | Choice | Why |
|---|---|---|
| Host | Host `.app` + `com.apple.screensaver` `.appex` | Aerial 4 path; `.saver` is rotting on Tahoe |
| Canary | Signed appex with a fixed grid, before the engine | Private API is the product risk; a preview app is not the product |
| Engine | Vendor `ttfx`, patch, don’t rewrite | Byte-identical to TTE v0.15.0; already builds on macOS |
| Frame contract | C ABI, packed cells, no UniFFI | Zero-copy upload; UniFFI would serialize every cell |
| Occupancy | Background and glyph are independent flags | A blank glyph can still carry a background |
| Reverse | Resolved inside `fill_grid` | Glyph-only reverse must emit a background quad |
| Origin | Top-left, rows increase downward | Terminal-internal order is not the ABI |
| Simulation | Fixed 60 Hz steps, vsync presents | Speed must not track the display |
| Threading | Main thread / `@MainActor` only | A display link is not a dispatch queue |
| Geometry | `create` + `resize`; apply in wait | Mid-effect `resize` is `pending_geometry`; no live remapping |
| Font size | Swift / renderer only | Engine must not start the next effect on an old canvas |
| Session states | `RUNNING` / `WAITING_FOR_BEGIN` / `DEAD` | Display `step` while waiting republishes; it does not error |
| Callback order | `step` → upload → font/`resize`/`begin_next` | Waiting `resize` and `begin_next` invalidate `cells` |
| Frame clear | `OmacyFrame.clear_*` | Selected next background is not the presented clear |
| Draw path | Metal glyph atlas + instanced quads | Core Text per cell per frame would dominate CPU |
| Display link | `NSView.displayLink` on the **main** run loop | Callback is main-thread; destroy before invalidate |
| Settings | App Group; pending **content** or disk at boundary | No `cols`/`rows` in replaceable config |
| Install | DMG → drag to `/Applications` | Sandboxed app cannot copy/update/delete itself |
| Image convert | Internal engine module, host-only UI | One consumer; `NSOpenPanel` is in the app |
| Effect pool | Include-list in `settings.json` (`effects`); missing or all 37 → every ttfx name | Art window checkboxes; default is still all 37 |
| OS floor | macOS 15; develop on 26 | Appex since Sonoma; current development is on macOS 26 |
| Displays | One session per saver view | Omarchy launches one `ttfx` per monitor |

Private API is accepted and **gated**. If the canary does not appear in System Settings, activate on idle, and paint every display on macOS 26 (and 15 when we have a box), we stop. The host preview remains a fallback product, not a substitute for the gate.

## System shape

```
Omacy.app  (SwiftUI chrome: preview, install/enable, config)
  Preview:  NSView  ──► OmacyRenderer
  PlugIns/Omacy.appex
    ScreenSaverView ──► OmacyRenderer ──► ScreenSaverEngine / WallpaperAgent

OmacyRenderer  (@MainActor)
  displayLink (main run loop)
    → step(elapsed)                    // WAITING: republish last frame
    → Metal upload/copy of that frame  // cells + clear_*; before invalidate
    → if needs_begin_next:
         apply font, resize (apply pending_geometry), begin_next
         // new effect publishes on the next callback
       │
       ▼
libomacy_engine.a   (main-thread session, 60 Hz accumulator)
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
omacy/
  apps/Omacy/              Xcode: host + appex + OmacyRenderer
  crates/omacy-engine/     session, FFI, ascii module, links ttfx
  vendor/ttfx/             git submodule, pinned commit + our patches
  assets/
    branding/screensaver.txt
    fonts/                 OFL monospace with full Braille
    fixtures/              conversion goldens + ansi-oracle/
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
- When the effect ends, reset the accumulator to 0 as the session enters `WAITING_FOR_BEGIN`. Do not carry remainder into the next effect. `begin_next` leaves it at 0.
- Negative, NaN, or infinite `elapsed` is `OMACY_ERR_INVALID_ARG`.
- `ttfx` tty sleep and SIGWINCH are off. Canvas size is explicit (`ignore_terminal_dimensions`, centered anchors).

## Engine patches (`vendor/ttfx`)

Small, upstreamable, parity suites stay green.

1. `Terminal::fill_grid` — occupancy + glyph + RGBA from `render_cells`. Reverse is applied here (final colors + final occupancy). No SGR. Map ttfx’s terminal row order into ABI top-left (see [ffi.md](ffi.md)).
2. `Effect::advance` — tick without formatting. `next_frame` = `advance` + `get_formatted_output_string`.
3. GUI construction path: no tty pacing, no SIGWINCH.
4. `from_name("beams")` with struct defaults; no argv.

Do not fork effect files. Do not change RNG, easing, or painter order.

On effect completion `step` fills and caches the last frame (old background as `clear_*`, old `cols`/`rows`), resets the accumulator, writes pending/disk **content** into `selected_next` without rewriting that cache or applying `pending_geometry`, enters `WAITING_FOR_BEGIN`, and stops. It does **not** construct the next effect. Further `step`s republish that cache (`needs_begin_next = 1`) and do not consume a later `set_pending_config`. Swift uploads or copies that frame first, then applies font size, `resize`s (this is when `pending_geometry` / new cell counts apply), and calls `begin_next`. Present the completed effect this callback; the new effect’s first frame is the next callback. Completion is not an error status. `begin_next` is atomic: success applies leftover `pending_geometry`, installs, promotes `selected_next.background`, and increments `generation`; recoverable failure stays waiting and may be retried; a pending content packet queued during wait applies at the *next* boundary.

## Renderer

Layout, from view bounds in **points** and the backing scale factor:

- Cell height = configured font size (default 18 pt, Omarchy’s screensaver override).
- Cell width = advance of `M` in the bundled font.
- `cols = floor(viewWidth / cellWidth)`, `rows = floor(viewHeight / cellHeight)`, both ≥ 1, both capped (see Limits).
- `cols * rows` uses checked multiplication; overflow is a failed resize, last grid kept.
- Remainder is margin; it shows `frame.clear_*`. The grid is centered. Origin is snapped to backing pixels.
- If `cols,rows` change after a 50 ms debounce, call `resize`. In `RUNNING` that stores `pending_geometry`; the live effect keeps its construction size; `cells` stay valid. Center the published grid in the view; extra area is `frame.clear_*`; clip if the grid is larger than the view. Font-size changes that alter cell counts use the same path. Apply the new size only in `WAITING_FOR_BEGIN` (after uploading the completed frame), then `begin_next`. Mid-effect remapping is out of scope.

Preview uses the **same 18 pt**. Smaller bounds ⇒ fewer cells. Do not shrink the preview font: that would increase cell count.

Tahoe may hand backing pixels as the view’s `bounds`. Compare `convertToBacking` / `backingScaleFactor` and treat an exact 2× jump as scale, not a giant canvas. `drawableSize` and the vertex viewport use that treated point size, never `bounds * scale` blindly.

Metal:

1. Atlas once per font size: printable ASCII, Braille `U+2800…U+28FF`, block drawing used by conversion. Glyphs are rasterized at backing scale with a 1 px gutter, baseline = `CTFontGetDescent`, sampled `nearest`. Extra glyphs from effects rasterize lazily up to the atlas cap (slot `replace` only); beyond that, draw background only. The bundled font is loaded once and cached by size.
2. When `steps_taken > 0` (or layout/atlas changed): walk cells into the next ring `MTLBuffer`. If `has_background`, instance a bg quad. If `has_glyph` and the glyph has coverage, instance a fg quad. Unoccupied cells are skipped (`frame.clear_*` shows). Do not interpret `reverse` — it is already resolved. Do not read `flags` (always 0). When `steps_taken == 0`, skip the walk and re-encode the last instance buffer.
3. Clear color = `frame.clear_*` (the published frame’s background). Not `selected_next.background`, and not a hardcoded `#000000` once settings can change it.
4. Triple-buffered instance storage with `DispatchSemaphore(3)`. Never skip a present because buffers are busy. Upload **immediately after** `step` returns, **before** a waiting `resize` or `begin_next`. A `RUNNING` `resize` does not invalidate the pointer. Disable implicit CALayer actions when setting `frame` / `drawableSize` / `contentsScale`.

Display link: `NSView.displayLink(target:selector:)` added to the **main** run loop (`.common`). Appex `SSENeedsAnimationTimer = false`. Create the session on the main thread **after the saver window has settled on its real display** (`NSWindow.didChangeScreenNotification`, a bounds match against `window.screen`, or a 250 ms fallback). ScreenSaverEngine first places every window on the main display and may keep the main display’s size for tens of milliseconds; starting at the first `viewDidMoveToWindow` would size every session to `NSScreen.main`. Backing scale is the view’s own window/screen, never `NSScreen.main`. If bounds still change before the first present, pending geometry applies immediately. Stop on the main thread in this order: `omacy_session_destroy`, then invalidate the link, then drop Metal. Triggers: `stopAnimation`, nil window, `com.apple.screensaver.willstop`. `deinit` asserts if the session is still alive and only then attempts destroy — it is not the primary path. Preferred frame rate: fullscreen max (60–120), Settings preview 30 Hz. Recreate the display link if the window moves to another screen.

`CAMetalDisplayLink` is a measured alternative, not the default.

No SwiftUI in the grid. Chrome and the config sheet may use SwiftUI. The sheet is not inside the saver view.

## Appex canary (go / no-go)

Before vendoring `ttfx` into the appex, ship a signed minimal host+appex derived from [AppexSaverMinimal](https://github.com/AerialScreensaver/AppexSaverMinimal).

The canary renderer draws a **fixed** grid (asymmetric fixture: a known glyph in the top-right cell, a colored blank in the bottom-left). No `ttfx`, no config, no image loader.

Acceptance, all required:

| Check | Pass |
|---|---|
| Install | User placed the app (DMG → `/Applications`, or Xcode DerivedData for local canary). Host only registers. Never both locations. |
| Discover | Listed with first-party savers in System Settings, not only under Other |
| Thumbnail | Landscape 107×65 / 214×130 |
| Enable | PaperSaver `setScreensaverEverywhere` and Settings both work |
| Idle | Activates on idle on the development Mac (macOS 26) |
| Multi-display | Every connected display paints the fixture |
| Teardown | `willstop` / window-nil drops Metal; no leak after open/close Settings ten times |
| Uninstall | Host unregisters and shows “move Omacy to Trash”; it does not delete the bundle |
| Recovery | Host reports a missing/unelected appex and offers re-register |
| Version | Repeat idle + Settings on macOS 15 when a box exists; document if deferred |

Fail the gate: do not spend further effort on engine-in-appex. Keep the host preview path.

## Install, update, failure

MVP distribution is a **signed, notarized DMG**. The user drags `Omacy.app` into `/Applications` like any Mac app. The host does not copy, replace, or delete itself.

- **Diagnose:** if the bundle is not under `/Applications` (and not a documented DerivedData canary), the host explains drag-to-Applications and refuses PlugInKit registration from a random path.
- **Register / enable:** from `/Applications`, `pluginkit -a` on the embedded appex; PaperSaver enable; Settings instruction. One location per machine — mixing DerivedData and `/Applications` makes PlugInKit sticky.
- **Update:** user replaces the app via a new DMG drop. Host re-registers on next launch. No Sparkle / no self-update in MVP.
- **Uninstall:** host unregisters (`pluginkit -r`) and shows instructions to Trash the app and optionally delete the App Group. No self-delete.
- **Signing:** ad-hoc for local canary; Developer ID + notarize on the DMG before any other machine.
- **Failure:** last-known-good `settings.json` + `screensaver.txt` (write temp, `rename`). Invalid files keep last-known-good and surface an error in the host. Bundled defaults only when no last-known-good exists. A dead session is `destroy`ed on the main thread and recreated there with last-known-good content and the current (or pending) geometry.

## Settings

App Group `group.be.zenjoy.omacy`:

```
screensaver.txt
settings.json
```

```json
{
  "effect": "random",
  "background": "#000000",
  "fontSize": 18,
  "asciiMode": "block",
  "threshold": 50,
  "invert": false
}
```

No `exclude`, no `cols`/`rows`. `effect` is `"random"` or a `ttfx` name.

**Ownership**

| Key | Owner | When it hits the engine |
|---|---|---|
| `effect`, `background`, `screensaver.txt` | Engine (disk or `OmacyPendingConfig`) | Create, and at the `step` that enters wait. A pending packet queued *during* wait waits for the following boundary. |
| `fontSize` | Swift / `OmacyRenderer` only | Never sent to the engine. Drives cell metrics → `resize` |
| `asciiMode`, `threshold`, `invert` | Host config UI only | Conversion time, not the live session |

The session is created on the main thread with `OmacySessionConfig` plus initial `cols`/`rows`. `config_dir` is create-only; pending config cannot change the reload directory. At an effect end, `step` caches the last frame, then applies pending content or rereads engine keys from disk into `selected_next` (see [ffi.md](ffi.md)) and waits. It does not apply `pending_geometry` (that would invalidate the frame before upload). Swift uploads that frame, reads `fontSize` (from its own copy of settings), recomputes the grid, `resize`s if needed, then `begin_next`. A newly selected background is not the presented clear until `begin_next` succeeds. Failed disk reads keep last-known-good **content**; bundled defaults only if none exists. Geometry is untouched by content reload. No dispatch source, no `NSFileCoordinator` watcher.

Image import, threshold, invert, mode, and paste-from-text run in the host app. Saving writes the App Group and, if a preview session exists, `set_pending_config` on the main thread. The System Settings sheet, when added, can change `effect` and restore default art only.

## Image → ASCII

Internal module of `omacy-engine`. Host config UI calls it through the FFI text allocators in [ffi.md](ffi.md). The appex never sees image bytes.

Pipeline follows the same stages as Omarchy’s script (alpha-or-luma, invert, trim, resize, threshold, pack). **Acceptance is committed-fixture parity** (`assets/fixtures/`), not a live ImageMagick replay — magick version, resize filter, and SVG viewport are not pinned. See [parity.md](parity.md).

SVG: `resvg` with **no** external resources, scripts, network, file references, or external fonts.

## Resource limits

All checked with `checked_mul` / explicit length tests. Breach → `OMACY_ERR_LIMIT`, no allocation of the huge object. **Stateful** session/config operations keep last-known-good. **Stateless** conversion (`ascii_from_bytes`) returns no output (`*out` is NULL).

| Resource | Cap |
|---|---|
| ASCII input bytes | 64 KiB |
| ASCII lines | 128 |
| ASCII columns (longest line) | 256 |
| Grid width or height | 512 |
| Grid cells (`cols * rows`) | 32_768 |
| Conversion columns | 256 |
| Conversion rows | 128 |
| Conversion output cells | 32_768 |
| PNG / SVG file bytes | 8 MiB / 2 MiB |
| Decoded pixels | 4_194_304 (2048²) |
| SVG elements | 8_192 |
| Atlas glyphs beyond preload | 256 |

Preload is ASCII `0x20–0x7E` + Braille block + conversion block characters. Particle glyphs that miss the atlas after the cap draw background only.

## Lifecycle

- `stopAnimation` may not run on Tahoe. Also stop from `willstop` and nil window — still on the main thread, destroy-then-invalidate.
- Settings preview can leak views. `OmacyRenderer.stop` is the primary cleanup. `deinit` asserts if a session remains.
- After a rebuild, re-register; `killall ScreenSaverEngine` is a documented dev hammer.

Multi-display: independent sessions, independent random picks, shared App Group files. Each saver view fills its window (`autoresizingMask`) and waits for ScreenSaverEngine’s main-display → real-display window migration before `attach`. Mixed-DPI desks use per-window `backingScaleFactor` for the atlas and Metal drawable.

## Testing

| Layer | Gate |
|---|---|
| Canary | Acceptance table above, macOS 26 (15 when available) |
| `vendor/ttfx` | Upstream parity suite green after patches |
| `fill_grid` | Vs ANSI oracle; asymmetric origin fixture; reverse × four occupancies |
| Engine | [parity.md](parity.md) matrix, all 37 effects |
| ASCII | Identity vs committed fixtures |
| FFI | Null `out` on `step`, panic invalidates `cells`, `RUNNING` `resize` does not, waiting `resize` applies `pending_geometry`, `clear_*` vs `selected_next.background`, `error_message(NULL)` any thread |
| Host | Preview still runs if the appex is uninstalled |

Rust tests run on CI without a Mac. Canary and saver idle tests are local until a macOS runner exists.

## Licensing

Omacy: MIT (Peter Dedene). `ttfx` / TTE / Omarchy branding and transcode rules: MIT; keep `NOTICE`. Bundled font: SIL OFL beside the font.

About screen: “Effects by Terminal Text Effects (ChrisBuilds), Rust engine `ttfx`.”

## Delivery phases

The implementation followed this order:

0. **Architecture spec.**
1. **Appex canary.** Signed host+appex, fixed asymmetric grid, install/enable/idle/uninstall. **Go/no-go.**
2. **Engine in the host.** Vendored `ttfx`, 60 Hz `step`, Metal renderer, default wordmark, random effects, parity matrix. **Worst-case gate:** all 37 effects, maximum grid (32_768 cells), at least three simultaneous sessions. Main-thread `step` + upload + encode must stay under 8.3 ms (one 120 Hz frame). Miss the budget: lower the presentation cap or the cell cap; do not ship a 120 Hz link that misses.
3. **Engine in the canary.** Same renderer as the host, still no image UI.
4. **Host config.** Paste, PNG/SVG, threshold/invert/mode, restore default, App Group reload at boundaries.
5. **Polish.** ProMotion present-vs-sim check, notarization, Settings sheet if still wanted.

## Risks

| Risk | Mitigation |
|---|---|
| Private appex API | Phase 1 gate; AppexSaverMinimal is the template |
| Tick-on-vsync speed bug | 60 Hz accumulator inside Rust |
| Colored blanks / reverse | Occupancy flags; reverse resolved in `fill_grid`; four-combo fixtures |
| Vertical flip | ABI origin + asymmetric golden |
| FFI races / panics | Main-thread ownership, `catch_unwind`, `panic = "unwind"`, no retained pointers |
| Stale geometry on config | Content packets have no dimensions |
| Mid-effect resize | `pending_geometry`; apply in wait; margins absorb the gap |
| Font vs next effect | Upload completed frame, then waiting `resize` / `begin_next` |
| Clear color at boundary | Cached `clear_*` stays old; `selected_next.background` promotes on `begin_next` |
| `step` during wait | Republish cached frame; pending queued in wait is for the next boundary |
| 120 Hz main-thread budget | Phase 2 gate: < 8.3 ms, max grid, ≥3 sessions |
| Resource bombs | Caps in the table above |
| 60 Hz vs Omarchy 120 | Recorded in parity.md; consistent across Macs |
| Braille looks wrong | Bundled OFL font, not SF Mono |
| Tahoe bounds units | Backing-scale handling |

## Out of scope until someone asks

Per-effect knobs. Exclude lists. Multiple saved logos. Color themes beyond the engine. Intel/universal. `.saver` fallback. `CAMetalDisplayLink`. Self-update. Off-main sessions (if ever: immutable snapshots produced on main — never `Send` the session). Mid-effect canvas remapping / restart-on-resize.
