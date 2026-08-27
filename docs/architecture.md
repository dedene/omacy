# Omacy Screensaver

macOS screensaver that replays Omarchy’s ASCII text-effects loop: a logo (or any text), animated by the 37 Terminal Text Effects, hosted as a real System Settings screensaver.

Stack: **Rust `ttfx` engine → zero-copy cell grid → Swift/Metal view → Aerial-style host app + `.appex`.**

This document is the design. Implementation follows only after it is accepted.

## Goal

When the Mac idles, every display shows the same kind of thing Omarchy shows: a centered ASCII/Braille logo, black field, a random (or chosen) `ttfx` effect, then the next one. In System Settings the user can paste art, generate it from a PNG/SVG, and pick effects.

It should feel identical to Omarchy, not “inspired by.” Same effect catalog, same motion, same image→Braille conversion. Font and cell size are the only allowed visual drift, and both are configurable.

## Non-goals

- Wrapping a terminal emulator or spawning the `ttfx` CLI. The screensaver host is sandboxed; that Linux architecture does not port.
- Reimplementing the 37 effects.
- Legacy `.saver` bundles as the shipping format.
- Wallpaper-continuity / lock-screen stills (Apple’s private wallpaper API). Preview-in-app is enough.
- Python TTE, ImageMagick, or any runtime interpreter.

## Locked decisions

| Decision | Choice | Why |
|---|---|---|
| Host | Host `.app` + `com.apple.screensaver` `.appex` | Same path Aerial 4 uses; `.saver` is rotting on Tahoe |
| Engine | Vendor `omacom-io/ttfx`, patch, don’t rewrite | Already a macOS-tested lib; byte-identical to TTE v0.15.0 |
| Frame contract | C ABI, packed cell buffer, no UniFFI | Zero-copy into Metal; UniFFI would serialize every cell |
| Draw path | Metal glyph atlas + instanced quads | Core Text per cell per frame would dominate CPU |
| Timing | `CADisplayLink`, `ttfx` frame-sleep off | Vsync, not a 120 fps tty sleep |
| Settings | App Group container | Host app and appex are different processes |
| Image convert | Pure Rust, once at config time | Matches Omarchy’s braille/block script; no `magick` |
| OS floor | macOS 15 (Sequoia); develop on 26 | Appex exists since Sonoma; Peter is on Tahoe |
| Displays | One engine session per `ScreenSaverView` | Omarchy launches one `ttfx` per monitor |

Private API risk is accepted: `ScreenSaverExtension` / ExtensionKit screensaver point is undocumented. The host app’s preview window uses the same renderer and remains usable if Apple breaks registration.

## System shape

```
┌─────────────────────────────────────────────────────────────┐
│  Omacy.app                                                  │
│  SwiftUI: preview, install/enable, full config              │
│                                                             │
│  Contents/PlugIns/Omacy.appex  ──►  ScreenSaverEngine /     │
│  ScreenSaverExtension + View        WallpaperAgent          │
└──────────────┬──────────────────────────┬───────────────────┘
               │                          │
               │  OmacyRenderer (shared)  │
               │  GridView + Metal + Settings
               ▼                          ▼
        omacy_engine.dylib / staticlib (Rust)
               │
               ├─ Session (tick → grid)
               ├─ ttfx (vendored)
               └─ omacy-ascii (PNG/SVG → Braille/block)
```

Three processes can draw:

1. **Host preview** — ordinary app window. Always works. Primary development surface.
2. **System Settings thumbnail/preview** — appex, `isPreview ≈ true`. Cheap: 30 fps, no atlas rebuild storms.
3. **Idle fullscreen** — one appex view per display, vsync, full quality.

All three instantiate the same `OmacyGridView`.

## Repo layout

```
omacy-screensaver/
  apps/Omacy/                 Xcode: host + appex + shared renderer
  crates/
    omacy-engine/             session, FFI, links ttfx
    omacy-ascii/              image → text (no ttfx dep)
  vendor/ttfx/                git submodule, pinned commit + our patches
  assets/
    branding/screensaver.txt  default Omarchy wordmark
    fonts/                    bundled OFL monospace with full Braille
  docs/architecture.md        this file
```

Xcode does not compile Rust ad hoc in the appex. A build phase runs `cargo build --release` for `aarch64-apple-darwin` (universal later) and links `libomacy_engine.a`. `cbindgen` emits `OmacyEngine.h`.

## Engine: adapting ttfx

`ttfx` is already a library (`src/lib.rs`) plus CLI. Effects implement:

```rust
fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError>;
fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String>;
```

`next_frame` ticks physics then `Terminal::get_formatted_output_string()`, which walks the dense `render_cells` buffer and emits ANSI. The cell buffer is the thing we want. `CharacterVisual` already has `symbol`, `colors`, and style flags *beside* the precomputed SGR string.

### Patches in `vendor/ttfx`

Keep them small and upstreamable.

1. **`Terminal::fill_grid(&mut self, out: &mut [Cell])`** — after `update_render_cells()`, write glyph + RGBA + flags. No SGR, no `String`.
2. **`Effect::advance`** — tick without formatting. `next_frame` becomes `advance` + `get_formatted_output_string` so the CLI stays byte-identical.
3. **Disable tty pacing and SIGWINCH** when constructed for a GUI session. We size the canvas ourselves (`ignore_terminal_dimensions = true`, `canvas_width/height` in cells, `anchor-canvas c`, `anchor-text c`).
4. **Default-config constructors** reachable without clap. `EffectCommand::build_effect` already does this; expose `from_name("beams")` that builds with struct defaults.

Do not fork the effect files. Do not change RNG, easing, or painter order. Parity suites in `vendor/ttfx` stay green.

### Our session (`omacy-engine`)

```text
create(ascii, cols, rows, effect | random, seed?)
resize(cols, rows)        → rebuild EngineCtx (Omarchy SIGWINCH path)
tick() -> Grid            → advance + fill_grid, borrowed until next tick
is_complete() -> bool     → start the next random effect, Omarchy loop
destroy()
```

On completion, pick the next effect the way Omarchy does: random from the 37, optional exclude list (Omarchy currently excludes `dev_worm` in some trees; we default to *all 37*, configurable).

Clock: `Clock::real()`. Matrix and thunderstorm are wall-clock gated; matching Omarchy means real time, not a virtual 120 fps clock. Frame delivery is vsync; a tick that finishes early waits for the display link, a tick that overruns drops to the next vsync (never sleep inside Rust).

## FFI

No UniFFI. One C header, `#[repr(C)]`, session pointer.

```c
typedef struct {
  uint32_t glyph;     /* Unicode scalar; 0 = empty */
  uint8_t  fg_r, fg_g, fg_b, fg_a;
  uint8_t  bg_r, bg_g, bg_b, bg_a;
  uint8_t  flags;     /* bit0 bold, bit1 italic, bit2 underline, bit3 reverse */
  uint8_t  _pad[3];
} OmacyCell;          /* 16 bytes */

typedef struct {
  uint32_t cols;
  uint32_t rows;
  const OmacyCell *cells; /* row-major, valid until next tick/destroy */
} OmacyFrame;

OmacySession *omacy_session_create(const OmacyConfig *cfg);
int           omacy_session_resize(OmacySession *, uint32_t cols, uint32_t rows);
int           omacy_session_tick(OmacySession *, OmacyFrame *out);
void          omacy_session_destroy(OmacySession *);
```

`tick` returns `1` if `out` is filled, `0` if the effect finished (caller creates a new session or we auto-advance inside — auto-advance inside, so Swift always gets a frame). Empty cells are `glyph = 0`; Metal skips them.

Swift overlay: `OmacySession` class, `tick() -> OmacyFrame` with an `UnsafeBufferPointer<OmacyCell>`. No copy.

ASCII transcode is a separate pair of C functions (`omacy_ascii_from_png`, `_from_svg`) used only by the host app’s config UI, not by the hot path.

## Renderer

`OmacyGridView: NSView` (`wantsLayer = true`). Shared by host preview and appex.

**Layout.** From `bounds` (points) and backing scale:

- cell height = chosen font size (preview may scale down)
- cell width = glyph advance of `M` in the bundled font (monospace, so one value)
- `cols = floor(width / cellWidth)`, `rows = floor(height / cellHeight)`
- integer leftover becomes black margin; the grid is centered in the view
- on `layout` / `viewDidMoveToWindow`, if `cols,rows` changed → `session.resize`

Tahoe can hand the screensaver view backing pixels instead of points. Use `convertToBacking` / `window?.backingScaleFactor` and treat a jump of 2× as scale, not a huge canvas.

**Metal.**

1. Build a **glyph atlas** once (and on font-size change): rasterize every distinct scalar seen in the current ASCII *plus* the Braille block `U+2800…U+28FF` *plus* ASCII printable. Core Text → `MTLTexture` (R8 or RG for coverage).
2. Each frame: walk the cell buffer, skip `glyph == 0`, write an instance (`uv rect, position, fg, bg`) into a triple-buffered `MTLBuffer`.
3. Draw two instanced quads per occupied cell: background then coverage-modulated foreground. Reverse flag swaps fg/bg.
4. Clear color = session background (`#000000` default).

Atlas misses (rare, a new particle glyph): rasterize that scalar on the next frame, don’t stall the current one — draw a space.

**Do not** use SwiftUI for the grid. SwiftUI is fine for the host chrome and the configuration sheet. Aerial’s warning about `NSHostingView` vs screensaver lifecycle stands; the pixels go through Metal.

**Display link.** `CADisplayLink` attached to the view’s window scene. Appex Info.plist: `SSENeedsAnimationTimer = false`. `startAnimation` / `viewDidMoveToWindow(window != nil)` starts the link; `stopAnimation` / window-nil invalidates it. Preview caps at 30 Hz.

## Host app and appex

Follow `AerialScreensaver/AppexSaverMinimal` for wiring, not Aerial’s production tree.

| Piece | Class | Notes |
|---|---|---|
| Principal | `OmacyExtension: ScreenSaverExtension` | `NSExtensionPointIdentifier = com.apple.screensaver` |
| View controller | `OmacyViewController: ScreenSaverViewController` | `loadView` creates `OmacyGridView` |
| View | `OmacyGridView: ScreenSaverView` | Metal + session |
| Config sheet | `OmacyConfigController` | SwiftUI hosted *in the sheet*, not in the saver view |
| Host app | SwiftUI | Preview, install, full settings |

Registration: `pluginkit -a` on the embedded appex (host “Install” button). Activation: PaperSaver `setScreensaverEverywhere(module: "Omacy")` behind “Enable as Screensaver”. Ship the app to `/Applications/Omacy.app`. One install location per machine — mixing DerivedData and `/Applications` makes PlugInKit sticky; debug from one place.

Thumbnails: landscape `107×65` / `214×130` in `thumbnail.imageset`. Square assets vanish in System Settings.

Bundle IDs:

- App: `be.zenjoy.omacy`
- Appex: `be.zenjoy.omacy.screensaver`
- App Group: `group.be.zenjoy.omacy`

Signing: Developer ID, notarize the `.app` zip, staple the app. The appex is signed as part of the host.

## Settings

Persisted in the App Group container, not `ScreenSaverDefaults` alone (the host app is not the legacyScreenSaver container).

```
group.be.zenjoy.omacy/
  screensaver.txt          current art
  settings.json            see below
```

```json
{
  "effect": "random",
  "exclude": [],
  "fontSize": 18,
  "asciiMode": "braille",
  "threshold": 50,
  "invert": false,
  "background": "#000000"
}
```

`effect` is `"random"` or a `ttfx` name. Font size 18 matches Omarchy’s Ghostty/Kitty screensaver override.

The host app is the real editor (file picker, live preview, threshold slider). The System Settings sheet is the same SwiftUI form in a narrower window. Saving writes the App Group; a running session observes with `NSFileCoordinator` / a dispatch source and rebuilds at the next effect boundary (not mid-frame).

Logo files: convert in the host, store *text*. The appex never opens the original image, so we don’t fight security-scoped bookmarks from a sandbox that didn’t show the open panel.

## Image → ASCII

Port `omarchy-transcode-ascii` (ImageMagick + awk) into `omacy-ascii`. Byte-for-byte isn’t required; visual match is.

Pipeline:

1. Decode PNG (`image`) or SVG (`resvg` → raster).
2. If alpha range is useful, use alpha; else luma. `--invert` flips the sense.
3. Trim empty borders (optional, default on).
4. Resize to `width*2 × height*4` (braille) or `width × height*2` (block).
5. Threshold (default 50%).
6. Pack: Braille dots in the same 2×4 bit order as Omarchy (`U+2800 + mask`), or `█▀▄ `.

CLI in the host is unnecessary; the config UI calls the crate via FFI. Keep a `cargo test` fixture against a few logos so the bit masks don’t drift.

Default art: vendor Omarchy’s wordmark into `assets/branding/screensaver.txt` (MIT). “Restore default” copies it back.

**Font.** Bundle a SIL-OFL monospace with a complete Braille block. Candidate: JetBrains Mono NL (no ligatures) or Iosevka Term. SF Mono’s Braille is not good enough as the only option; system fonts can be a fallback picker later.

## Lifecycle

Known host bugs we design around (Tahoe / `legacyScreenSaver` / WallpaperAgent):

- `stopAnimation` may not run. Also stop in `deinit`, `viewDidMoveToWindow` (nil window), and `com.apple.screensaver.willstop`.
- Preview instantiates extra views and may leak them. `OmacyGridView.stop` must drop the Metal stack and the Rust session. Don’t rely on `NSHostingView`.
- After a rebuild, PlugInKit may keep serving the old binary. Host “Install” re-registers; document `killall -9 ScreenSaverEngine` for dev.

Resize: debounce 50 ms (ttfx already does this for SIGWINCH) then `session.resize`. Don’t recreate the Metal device.

Multi-display: independent sessions, independent random picks. Shared settings, shared ASCII.

## Performance budget

Target: 60 fps (120 on ProMotion) on a 5K iMac-class grid (~220×80 cells) with `< 20% of one P-core` and trivial GPU.

| Cost | How we stay under |
|---|---|
| Effect physics | Already hundreds-to-thousands fps on 200×50 in `ttfx` |
| ANSI encode/decode | Skipped |
| Tty sleep | Skipped |
| Glyph raster | Once per font size, atlas |
| Per-frame CPU | Walk occupied cells, write instances |
| Preview | 30 Hz, smaller font → fewer cells |

Measure with Instruments on the host preview before wiring the appex. If `tick` exceeds half a vsync, move it to a worker and display the previous grid (double-buffer frames, not sessions).

## Testing

| Layer | Gate |
|---|---|
| `vendor/ttfx` | Their parity suite still passes after our patches |
| `omacy-ascii` | Fixture images → golden `.txt` |
| `omacy-engine` | Headless: known seed + input → grid hash for a few effects (not ANSI-identical; cell-identical to a `fill_grid` dump from patched ttfx) |
| Renderer | Host preview screenshot smoke (manual / later snapshot) |
| Appex | `open -a ScreenSaverEngine`, Console subsystem `be.zenjoy.omacy` |

CI on this repo can run the Rust tests without a Mac. The Xcode/appex path is local until we have a macOS runner.

## Licensing

- Omacy: MIT (Peter Dedene), this repo.
- `ttfx` / TerminalTextEffects: MIT, ChrisBuilds + omacom-io. Preserve both in `NOTICE` and in the about screen.
- Bundled font: SIL OFL, keep the license file next to the font.

Do not rebrand the effects as original work. Credit on the about screen: “Effects by Terminal Text Effects (ChrisBuilds), Rust engine `ttfx`.”

## Delivery phases

Build in this order so each phase is demoable without the next.

0. **This spec.**
1. **Windowed prototype.** Host app, Metal grid, vendored ttfx with `fill_grid`, default wordmark, random effects. No appex. This is the visual proof.
2. **Config.** App Group, image import, threshold/invert/mode, effect picker, restore default.
3. **Appex.** Extension target, PlugInKit, PaperSaver enable, preview vs fullscreen, thumbnail.
4. **Polish.** Atlas coverage, ProMotion, Instruments pass, notarization, exclude-list, per-effect options if we still want them.

Phase 1 is the real risk-reducer: if the grid looks like Omarchy in a window, the rest is Apple hosting.

## Risks

| Risk | Mitigation |
|---|---|
| Private screensaver API breaks | Preview app still runs; AppexSaverMinimal is the canary |
| `ttfx` clap-tangled effects | `from_name` + default configs; don’t parse argv in the saver |
| Braille looks wrong | Bundled font, not SF Mono |
| Tahoe pixel-vs-point bounds | Explicit backing-scale handling |
| Appex sandbox vs user files | Convert in host, store text in App Group |
| ttfx upstream moves fast | Pin a commit; patches stay < few hundred lines |
| CPU on 5K | Atlas + skip empty cells; worker tick only if measured |

## Out of scope until someone asks

Per-effect knobs (Omarchy uses defaults). Multiple saved logos. Color themes beyond the engine’s own palettes. Intel/universal binary (Apple Silicon first). A `.saver` fallback.
