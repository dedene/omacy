# Omacy FFI contract

Normative ABI for `libomacy_engine`. Swift must not depend on behavior that is not here.

## Status codes

```c
typedef enum {
  OMACY_OK = 0,
  OMACY_ERR_NULL = 1,
  OMACY_ERR_INVALID_ARG = 2,
  OMACY_ERR_LIMIT = 3,
  OMACY_ERR_ENGINE = 4,
  OMACY_ERR_PANIC = 5,
  OMACY_ERR_DEAD = 6
} omacy_status;
```

Every exported function returns `omacy_status` except `destroy` / `free` (void) and `omacy_status_string`. Effect completion is **not** a status. A successful `step` always publishes a grid; the session auto-advances to the next effect internally.

`OMACY_ERR_DEAD`: the session panicked earlier. Only `destroy` is legal.

`omacy_status_string(status)` returns a static NUL-terminated English phrase.

`omacy_session_error_message(session, buf, buf_len)` copies a longer diagnostic (truncated, always NUL-terminated). `session == NULL` uses a **thread-local** last error (for failed `create`). Return is `OMACY_OK` or `OMACY_ERR_NULL` if `buf` is null.

## Cell

16 bytes, `#[repr(C)]`, little-endian.

```c
typedef struct {
  uint32_t glyph;     /* Unicode scalar. 0 if !has_glyph. SPACE (0x20) is a real glyph. */
  uint8_t  fg_r, fg_g, fg_b, fg_a;
  uint8_t  bg_r, bg_g, bg_b, bg_a;
  uint8_t  flags;     /* bit0 bold, bit1 italic, bit2 underline, bit3 reverse */
  uint8_t  occupancy; /* bit0 has_background, bit1 has_glyph */
  uint8_t  _pad[2];
} OmacyCell;
```

**Occupancy**

| occupancy | Meaning | Draw |
|---|---|---|
| `0` | Unpainted (ttfx `EMPTY_RENDER_CELL`) | Skip. View clear color. |
| `has_background` only | Blank / space with a background | Background quad only |
| `has_glyph` only | Mark, default/transparent bg | Foreground quad if atlas coverage |
| both | Colored mark | Background quad, then coverage fg |

`glyph == 0` is only valid when `has_glyph` is clear. Do not treat `glyph == 0` as “skip the cell.” A space with `bg_a > 0` must paint.

Reverse: swap fg and bg at draw time; occupancy still decides which quads exist.

## Frame

```c
typedef struct {
  uint32_t cols;
  uint32_t rows;
  const OmacyCell *cells;
} OmacyFrame;
```

- Row-major.
- **Origin is the top-left** of the visible canvas.
- Index `row * cols + col`. `row` 0 is the visual top; `col` 0 is the visual left.
- Rows increase downward; columns increase rightward.

`ttfx` terminal coordinates are south-west anchored and `get_formatted_output_string` emits top row first by iterating `row_index` in reverse. `fill_grid` must remap into this ABI. A golden fixture with a glyph only in the top-right cell and a colored blank only in the bottom-left cell catches inversion.

`cells` is `cols * rows` elements. `cols * rows` is computed with checked arithmetic; a frame that would overflow is never published.

## Pointer lifetime

`cells` is borrowed from the session.

It is valid only until the next call on **that** session, including `step`, `resize`, `set_next_config`, `destroy`, and any function that takes `OmacySession *`.

Swift must upload to Metal (or `memcpy` into its own buffer) before `step` returns to the run loop. Storing the pointer on the view is a contract violation.

`create` / `step` / `resize` write `OmacyFrame.cells = NULL` on failure.

## Session API

```c
omacy_status omacy_session_create(const OmacyConfig *cfg, OmacySession **out);
omacy_status omacy_session_resize(OmacySession *s, uint32_t cols, uint32_t rows);
omacy_status omacy_session_step(OmacySession *s, double elapsed_seconds, OmacyFrame *out);
omacy_status omacy_session_set_next_config(OmacySession *s, const OmacyConfig *cfg);
uint64_t     omacy_session_generation(const OmacySession *s); /* 0 if s is null */
void         omacy_session_destroy(OmacySession *s);          /* NULL is a no-op */
```

`OmacyConfig` (cbindgen) includes: UTF-8 path to the App Group directory (nullable if ASCII is passed inline), optional inline UTF-8 art, `cols`, `rows`, effect name or “random”, font size unused by the engine, background RGBA, seed optional, simulation Hz (must be 60 in MVP).

`create` validates limits, builds the first effect, publishes nothing until the first `step`. `out` is set only on `OMACY_OK`.

`step`:

1. Reject null `s`/`out`, dead session, non-finite `elapsed_seconds`.
2. Accumulate and `advance` at 60 Hz with a 4-step catch-up cap (architecture.md).
3. If the effect finishes, reload config from disk (if a directory was given), validate, fall back to last-known-good on failure, start the next effect, increment `generation`.
4. `fill_grid` into the session’s **publish buffer**.
5. Point `out` at that buffer.

`resize` rebuilds `EngineCtx` like ttfx SIGWINCH. It does not publish a frame. The next `step` does. Outstanding `cells` pointers are invalid.

`set_next_config` is applied at the next effect boundary, before a disk reread. If it was called since the last boundary, it wins and disk is not read. Otherwise, if a config directory was given at create, the session reads and validates those files. Failure keeps last-known-good.

## Threading

One serialized executor per session: a mutex around all `&mut` session operations.

- Re-entrant `step` from the same thread is `OMACY_ERR_INVALID_ARG`.
- Concurrent calls from two threads block; they do not data-race. Callers still **must not** overlap `step` with use of a previous `cells` pointer — the mutex does not extend pointer lifetime.
- The display-link thread owns the session in MVP. Config UI never calls `step`. It writes App Group files; the session rereads them at the next effect boundary.

The engine is not internally thread-safe beyond this mutex. `ttfx` uses `Rc` / thread-locals (formatted-symbol scratch). Do not send a session across threads mid-step.

## Panic containment

Every `extern "C"` function is wrapped in `catch_unwind`.

On panic: log the payload, set the session dead (if any), set last error, return `OMACY_ERR_PANIC`. No unwind across FFI. A panicked session leaks no frame pointer (`cells` is null).

## ASCII conversion

Not a second crate. Same library, different functions. Results are **owned** and must be freed.

```c
omacy_status omacy_ascii_from_bytes(const OmacyAsciiConfig *cfg,
                                    const uint8_t *bytes, size_t len,
                                    OmacyText **out);
void         omacy_text_free(OmacyText *t);           /* NULL is a no-op */
const char  *omacy_text_utf8(const OmacyText *t);     /* NULL if t is NULL */
size_t       omacy_text_len(const OmacyText *t);      /* bytes, not including NUL */
```

`omacy_text_utf8` is valid until `omacy_text_free`. It is not tied to a session.

`OmacyAsciiConfig`: mode braille/block, width, height, threshold, invert, trim. Format is sniffed (PNG magic, otherwise SVG). SVG config is forced: no external resources, scripts, network, file refs, fonts.

Limit failures return `OMACY_ERR_LIMIT` and `*out = NULL`.

## Worker rendering (not MVP)

If a worker is ever introduced: the worker advances into a private buffer, then publishes by atomic swap of an **immutable** `Arc<[OmacyCell]>`. The display-link thread only reads the published snapshot. Never mutate a buffer still visible through `OmacyFrame.cells`. Until then, `step` runs on the display-link thread.
