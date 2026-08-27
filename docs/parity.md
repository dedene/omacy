# Omacy parity contract

What “the same as Omarchy / ttfx” means, and how we know.

## Pins

Record concrete revisions in this file when they are vendored. Until then the targets are:

| Component | Pin |
|---|---|
| TTE (ttfx’s upstream) | v0.15.0, commit `7a91dd9ca6ee0c4f4b1484efee0ecac1bb84104e` |
| ttfx | Release **0.3.2** (or the successor we vendor); store the git SHA in `vendor/ttfx` |
| Omarchy screensaver loop | `bin/omarchy-screensaver` on the `quattro` line we vendor against |
| Omarchy converter | `bin/omarchy-transcode-ascii` at that same revision |
| Default art | Omarchy branding `screensaver.txt` at that revision |

`ttfx` already treats byte-identical ANSI frames vs TTE as its standard. We do not weaken that for the CLI. Our GUI path is **cell-identical** to `fill_grid` of that same engine, not ANSI-identical (we never emit ANSI).

## Clock policy

| Item | Omacy | Omarchy screensaver |
|---|---|---|
| Step rate | 60 Hz, engine accumulator | `--frame-rate 120` (120 steps/s) |
| Presentation | Display link (60 or 120 Hz) | Terminal refresh |
| `matrix` / `thunderstorm` | `Clock::real()` | real tty time |
| Catch-up | max 4 steps per `step()` call, then drop remainder | n/a |

This is an intentional divergence: Omacy speed is stable across 60 Hz and 120 Hz panels. A 120 Hz Mac will **not** match Omarchy-on-Linux wall-clock duration for stepped effects (Omarchy is ~2× our step rate). It **will** match another Omacy Mac.

Parity tests use the 60 Hz virtual cadence: `elapsed = 1.0/60.0` per `step`, seed fixed, no catch-up (elapsed is exact).

## Effect pool

All **37** `ttfx` effects. No exclude list in MVP.

Current Omarchy `omarchy-screensaver` (quattro) does not pass `--exclude-effects`. Older trees excluded `dev_worm`. We follow current Omarchy: include all. If the pinned Omarchy revision excludes any, update this paragraph and the engine default to match — do not silently drift.

Random choice uses ttfx’s `from_name` list in registry order and ttfx’s RNG (`xoshiro256++`). `--seed` is deterministic within ttfx, not vs CPython.

## Grid matrix (motion)

For **each** of the 37 effects:

| Field | Value |
|---|---|
| Input | Pinned Omarchy wordmark, plus one small asymmetric fixture (`fixtures/asymmetric.txt`) |
| Seed | `1` |
| Canvas | 80×24 and 160×48, centered anchors, `ignore_terminal_dimensions` |
| Clock | 60 Hz exact steps, `Clock` as in production (`real` for wall-clock effects; tests inject a virtual clock that still *reports* real-style durations for those two by advancing the injected clock 1/60 s per step — documented in the test harness) |
| Frames | First **180** steps, and the last frame before completion if completion is < 180 |
| Compare | Packed `OmacyCell` bytes vs a dump from patched ttfx `fill_grid` after the same `advance` sequence |

Accepted differences: none on occupancy, glyph, RGB, flags. Alpha is 0 or 255 only in MVP.

`matrix` and `thunderstorm` are duration-gated. For those, the harness uses a virtual clock of 60 Hz so the test is deterministic; production still uses `Clock::real()`. That harness/production split is listed in the test name.

Asymmetric fixture (both canvases, `beams` and `wipe` at least): top-right cell has a non-space glyph; bottom-left cell is a space with a non-black background. Fail if those positions are swapped or if the colored blank is occupancy 0.

## Pixel matrix (presentation)

Not identity. Font rasterization will not match a terminal.

Accepted: the Metal view, with the bundled font at 18 pt, shows the same **grid** as `fill_grid` (spot-check occupancy map: screenshot vs a CPU-drawn bitmap of bg/fg quads). One effect (`beams`) + default wordmark + 80×24. This is a host-preview test, not CI on Linux.

## Conversion matrix

`assets/fixtures/` contains PNG and SVG logos (silhouette, transparent, inverted). Goldens are produced **once** with pinned `omarchy-transcode-ascii` (ImageMagick allowed at golden-generation time, not at runtime) for:

- braille / block
- threshold 50 and 30
- invert on/off
- default width/height of the Omarchy screensaver path

Omacy’s ascii module must emit byte-identical text. If upstream awk/magick is unavailable on CI, the committed goldens are the source of truth; a Mac or Linux job with `magick` refreshes them when the Omarchy pin moves.

## What we are not claiming

- Byte-identical ANSI vs `tte` from the GUI (we do not produce ANSI).
- Identical wall-clock length vs Omarchy’s 120 fps loop.
- Identical pixels vs Ghostty/Kitty.
- Bit-identical RNG vs CPython TTE (ttfx already does not).
