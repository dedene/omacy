# ANSI oracle fixtures

Raw inputs for the test-only SGR decoder in [parity.md](../../../docs/parity.md).
Each file uses real CSI (`ESC [ … m`). Do not regenerate these in the test crate.

| File | Sequences | Expected snapshot |
|---|---|---|
| `sgr-reset.ans` | `31`, `0` | `A` red fg; `B` default (no fg) |
| `sgr-reverse.ans` | `31`, `7`, `27` | `A` red; `B` reverse-of-red; `C` red, reverse off |
| `sgr-ansi16-fg.ans` | `30–37`, `90–97` | 16 glyphs `A–P`, matching 16-color fg, no bg |
| `sgr-ansi16-bg.ans` | `40–47`, `100–107` | 16 spaces, background-only occupancy |
| `sgr-xterm256.ans` | `38;5;196`, `48;5;17` | `X`, xterm 196 / 17 |
| `sgr-truecolor.ans` | `38;2;255;128;0`, `48;2;0;0;64` | `X`, `#ff8000` on `#000040` |
| `sgr-default-colors.ans` | `31`, `41`, `39`, `49` | `A` red/red; `B` default fg + red bg; `C` both default |
| `occupancy-four.ans` | 2×2 occupancy set | top-left unpainted; top-right glyph; bottom-left space+bg; bottom-right both |
| `origin-asymmetric.ans` | origin | top-right `X`; bottom-left space + bg 44; other two unpainted |
| `sgr-style-ignored.ans` | `1`, `3`, `4`, `22`, `23`, `24`, `31` | `X` red, `flags = 0`; `Y` default |

Reverse × occupancy is `sgr-reverse.ans` plus the four-combo grid. `flags` is 0 in every snapshot.
