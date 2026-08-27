# Omacy parity contract

What “the same as Omarchy / ttfx” means, and how we know.

Vendoring **may not start** until these SHAs are the recorded pins (update this table if we deliberately move; do not vendor `master`/`quattro` floating).

## Pins

| Component | Pin |
|---|---|
| TTE (ttfx’s upstream) | v0.15.0, `7a91dd9ca6ee0c4f4b1484efee0ecac1bb84104e` |
| ttfx | tag **v0.3.2**, `7203e354498462064b7c0a89375051f65cf2ce99` |
| Omarchy tree | `quattro` at `9d02bb08f896108ec83ad0984bdaafa753e9f1e8` |
| Omarchy screensaver | `bin/omarchy-screensaver` in that tree (no `--exclude-effects`) |
| Omarchy converter | `bin/omarchy-transcode-ascii` in that tree |
| Default art | Omarchy default `screensaver.txt` from that tree (vendored into `assets/branding/`) |

`ttfx` already treats byte-identical ANSI frames vs TTE as its standard. We do not weaken that for the CLI.

## Independent grid oracle

`fill_grid` is **never** compared to itself.

For each checked step:

1. `advance` once on the engine (same seed, canvas, input).
2. **Oracle:** take `get_formatted_output_string()` (the existing ANSI emission path, independent of `fill_grid`). Decode supported SGR into canonical `OmacyCell`s with the same occupancy rules as [ffi.md](ffi.md) (top-left remap). The decoder lives in **tests only**.
3. **SUT:** `fill_grid` into a packed buffer.
4. Compare occupancy, glyph, RGB. `flags` must be 0. Alpha is 0 or 255 only in MVP. Accepted differences: none.

The oracle is a **row-oriented SGR decoder**, not a VT emulator. Rows are `\n`-separated. It does not implement CUP / cursor saves.

Supported SGR (these change the pen or occupancy):

| Sequence | Meaning |
|---|---|
| `0` | Reset |
| `7` / `27` | Reverse on / off |
| `30–37` / `90–97` | 16-color fg |
| `40–47` / `100–107` | 16-color bg |
| `38;5;n` / `48;5;n` | xterm-256 fg / bg |
| `38;2;r;g;b` / `48;2;r;g;b` | 24-bit fg / bg |
| `39` / `49` | Default fg / bg |

Parsed and discarded (must not fail the decoder, must not set `flags`): `1` / `22` (bold), `3` / `23` (italic), `4` / `24` (underline).

Do not implement the oracle by calling `fill_grid`. The decoder models a terminal pen (fg, bg, reverse) from SGR, then snapshots to `OmacyCell` using the occupancy rules in [ffi.md](ffi.md). That snapshot logic is a **second implementation** of the ABI, not a shared function with `fill_grid`. If they disagree, `fill_grid` is wrong unless a hand-written ANSI unit test shows the decoder misreads SGR.

Committed raw ANSI under `assets/fixtures/ansi-oracle/` exercises every sequence above. Each file is the oracle input; expected occupancy/colors are in `manifest.md` beside them. Tests must load these files, not reconstruct the bytes in Rust.

Asymmetric fixture remains: top-right non-space glyph, bottom-left space with non-black background (`origin-asymmetric.ans`). Fail on swap or occupancy 0 on that blank.

Reverse fixtures: four occupancy combinations × reverse on/off (`occupancy-four.ans`, `sgr-reverse.ans`), compared to the ANSI oracle (not to `fill_grid` goldens).

## Clock policy

| Item | Omacy | Omarchy screensaver (pinned tree) |
|---|---|---|
| Step rate | 60 Hz, engine accumulator | `--frame-rate 120` |
| Presentation | Display link (60 or 120 Hz) | Terminal refresh |
| `matrix` / `thunderstorm` | `Clock::real()` | real tty time |
| Catch-up | max 4 steps per `step()` call, then drop remainder | n/a |

Intentional divergence: Omacy speed is stable across 60 Hz and 120 Hz panels. A 120 Hz Mac will not match Omarchy-on-Linux wall-clock duration for stepped effects.

Parity tests use `elapsed = 1.0/60.0` per `step`, seed fixed, no catch-up.

## Effect pool

All **37** `ttfx` effects. No exclude list in MVP.

Pinned `omarchy-screensaver` does not pass `--exclude-effects`. If a later Omarchy pin adds excludes, update this paragraph and the engine default together.

Random choice uses ttfx’s registry order and ttfx’s RNG (`xoshiro256++`). `--seed` is deterministic within ttfx, not vs CPython.

## Grid matrix (motion)

For **each** of the 37 effects:

| Field | Value |
|---|---|
| Input | Pinned Omarchy wordmark, plus `fixtures/asymmetric.txt` |
| Seed | `1` |
| Canvas | 80×24 and 160×48, centered anchors, `ignore_terminal_dimensions` |
| Clock | 60 Hz exact steps; `matrix` / `thunderstorm` tests inject a virtual clock (named in the test); production uses `Clock::real()` |
| Frames | First **180** steps, and the last frame before completion if completion is < 180 |
| Compare | `fill_grid` vs ANSI oracle (above) |

## Pixel matrix (presentation)

Not identity. Font rasterization will not match a terminal.

Spot-check: Metal occupancy map vs a CPU bitmap of published cells. One effect (`beams`) + default wordmark + 80×24. Host preview, not Linux CI.

## Conversion matrix

**Claim:** Omacy’s ascii module is byte-identical to **committed files** under `assets/fixtures/` (input image + expected `.txt` for named mode/threshold/invert/trim tuples).

That is the acceptance test. We do **not** claim live byte identity with ImageMagick: version, delegates, colorspace, resize filter, rounding, alpha extraction, threshold, trim, and SVG viewport are not pinned and are known to drift across `magick` builds.

The Omarchy script SHA is recorded so a human can regenerate fixtures on purpose. Regeneration is a manual, reviewed diff, not CI. Runtime conversion uses `image` / `resvg` with external SVG resources disabled.

## What we are not claiming

- Byte-identical ANSI vs `tte` from the GUI (we do not produce ANSI).
- Identical wall-clock length vs Omarchy’s 120 fps loop.
- Identical pixels vs Ghostty/Kitty.
- Bit-identical RNG vs CPython TTE.
- Live ImageMagick / `omarchy-transcode-ascii` identity at runtime.
