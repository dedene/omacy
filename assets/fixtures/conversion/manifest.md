# Conversion goldens

Each row is one accepted `(input, mode, threshold, invert, trim)` tuple.
Omacy’s ascii module must emit the committed `.txt` byte-for-byte.

| Input | Mode | threshold | invert | trim | Expected |
|---|---|---|---|---|---|
| `solid-black-on-white.png` | braille | 50 | 0 | 1 | `solid-black-on-white.braille.t50.inv0.trim1.txt` |
| `solid-black-on-white.png` | block | 50 | 0 | 1 | `solid-black-on-white.block.t50.inv0.trim1.txt` |
| `solid-black-on-white.png` | braille | 50 | 1 | 1 | `solid-black-on-white.braille.t50.inv1.trim1.txt` |
| `solid-black-on-white.png` | block | 80 | 0 | 0 | `solid-black-on-white.block.t80.inv0.trim0.txt` |
| `alpha-logo.png` | braille | 50 | 0 | 1 | `alpha-logo.braille.t50.inv0.trim1.txt` |
| `logo.svg` | braille | 50 | 0 | 1 | `logo.svg.braille.t50.inv0.trim1.txt` |

Regeneration (manual, reviewed):

```
cargo run -p omacy-engine --example write_conversion_fixtures
```

Do not replay live ImageMagick in CI. The Omarchy converter SHA is recorded in [parity.md](../../../docs/parity.md).
