# Omacy FFI contract

Normative ABI for `libomacy_engine`. Swift must not depend on behavior that is not here.

`omacy-engine` **must** build with `panic = "unwind"` (dev and release). `catch_unwind` is meaningless if the crate graph uses `panic = "abort"`. ttfx’s own CLI profile may abort; it does not apply when ttfx is linked as a dependency of this crate.

## Status codes

```c
typedef enum {
  OMACY_OK = 0,
  OMACY_ERR_NULL = 1,
  OMACY_ERR_INVALID_ARG = 2,
  OMACY_ERR_LIMIT = 3,
  OMACY_ERR_ENGINE = 4,
  OMACY_ERR_PANIC = 5,
  OMACY_ERR_DEAD = 6,
  OMACY_ERR_WRONG_THREAD = 7
} omacy_status;
```

Effect completion is **not** an error. A successful `step` always publishes a grid. If the current effect ended, `needs_begin_next` is set and the next effect is **not** constructed until `begin_next` (after Swift has applied font + `resize`).

### Signature classes and panic fallbacks

Every `extern "C"` entry is wrapped in `catch_unwind`. Unwind never crosses FFI.

| Class | Examples | Success | Panic / catch_unwind |
|---|---|---|---|
| `omacy_status` | `create`, `step`, `resize`, `set_pending_config`, `begin_next`, `generation`, `error_message`, `ascii_from_bytes` | `OMACY_OK` | `OMACY_ERR_PANIC`; session marked dead if one was involved; out-pointers NULLed as in the per-op table |
| `void` | `destroy`, `text_free` | — | Swallow. `destroy`: if main thread, free what can be freed and mark dead; if already dead, still free. Never unwind. |
| `const char *` | `status_string`, `text_utf8` | pointer | `NULL`. `status_string` is a static table and must not allocate; treat panic as a bug. |
| `size_t` | `text_len` | length | `0` |

`OMACY_ERR_DEAD`: session panicked earlier (or was otherwise marked dead). Legal calls: `destroy`, `error_message`, `generation`. Illegal: `step`, `resize`, `set_pending_config`, `begin_next` → `OMACY_ERR_DEAD` with no mutation.

## Config structs

Strings are **pointer + length**. Length is authoritative. A null pointer is allowed only with `len == 0` (absent). Null + `len > 0` is `OMACY_ERR_INVALID_ARG`. Pointers need not be NUL-terminated; the implementation must not read past `len`.

`create` and `set_pending_config` **validate and deep-copy** every field into session-owned storage **before returning**. After `OMACY_OK`, the caller may immediately free or reuse the pointed-to memory. After any error, the session’s pending/current content config is unchanged (create: no session).

Geometry is **not** in these structs. `resize` is the only call that changes `cols`/`rows`. Boundary updates always keep the current dimensions.

```c
/* Content at create. No geometry. */
typedef struct {
  const uint8_t *config_dir;   /* UTF-8 App Group path, optional */
  size_t         config_dir_len;
  const uint8_t *ascii;        /* UTF-8 art, optional if config_dir has screensaver.txt */
  size_t         ascii_len;
  const uint8_t *effect;       /* required: "random" or a ttfx name */
  size_t         effect_len;
  uint8_t        bg_r, bg_g, bg_b, bg_a;
  uint8_t        has_seed;     /* 0 = entropy at create; 1 = `seed` is used */
  uint8_t        _pad[3];
  uint64_t       seed;
} OmacySessionConfig;

/* Replaceable user settings. No geometry. No seed (seed is create-only). */
typedef struct {
  const uint8_t *config_dir;
  size_t         config_dir_len;
  const uint8_t *ascii;
  size_t         ascii_len;
  const uint8_t *effect;
  size_t         effect_len;
  uint8_t        bg_r, bg_g, bg_b, bg_a;
  uint8_t        _pad[3];
} OmacyPendingConfig;

typedef enum {
  OMACY_ASCII_BRAILLE = 0,
  OMACY_ASCII_BLOCK = 1
} omacy_ascii_mode;

typedef struct {
  omacy_ascii_mode mode;
  uint32_t         width;      /* conversion columns, not the live grid */
  uint32_t         height;     /* conversion rows, not the live grid */
  uint8_t          threshold;  /* 0–100 */
  uint8_t          invert;     /* 0 or 1 */
  uint8_t          trim;       /* 0 or 1 */
  uint8_t          _pad;
} OmacyAsciiConfig;
```

`OmacyAsciiConfig.width` / `height` are the **image-to-text** target, not the session canvas.

Validation on `OmacySessionConfig` / `OmacyPendingConfig` (all `INVALID_ARG` unless noted `LIMIT`):

- `effect` is `"random"` or a known ttfx name (exact, lowercase).
- `has_seed` is 0 or 1 (`SessionConfig` only).
- `ascii` present, or `config_dir` present, or both. If both, inline `ascii` is the art; `config_dir` is used for later disk reloads of art/effect/background only.
- UTF-8 well-formed for every non-empty string.
- Neither struct may carry `cols`/`rows`/`fontSize`. Those fields do not exist.

`create` also takes `cols` and `rows` as separate arguments (same caps as `resize`).

`OmacyAsciiConfig`: `mode` is a declared enumerator; `width`/`height` ≥ 1 and in cap; `threshold` ≤ 100; `invert`/`trim` are 0 or 1.

## Cell

16 bytes, `#[repr(C)]`, little-endian.

```c
typedef struct {
  uint32_t glyph;     /* Unicode scalar. 0 if !has_glyph. SPACE (0x20) is a real glyph. */
  uint8_t  fg_r, fg_g, fg_b, fg_a;
  uint8_t  bg_r, bg_g, bg_b, bg_a;
  uint8_t  flags;     /* bit0 bold, bit1 italic, bit2 underline; bit3 reserved 0 */
  uint8_t  occupancy; /* bit0 has_background, bit1 has_glyph */
  uint8_t  _pad[2];
} OmacyCell;
```

**Occupancy** is the post-style occupancy Metal consumes. Terminal `reverse` is **not** a renderer concern.

| occupancy | Meaning | Draw |
|---|---|---|
| `0` | Unpainted (`EMPTY_RENDER_CELL`) | Skip. View clear color. |
| `has_background` only | Filled cell, no coverage glyph | Background quad only |
| `has_glyph` only | Mark, no cell fill | Foreground quad if atlas coverage |
| both | Cell fill + mark | Background quad, then coverage fg |

`glyph == 0` is only valid when `has_glyph` is clear. A space with a background must have `has_background`.

### Reverse, resolved in `fill_grid`

`fill_grid` applies reverse **before** writing occupancy and colors. Published `flags` bit3 is always 0. Metal must not swap colors.

Let `term_bg` be the session background (default `#000000`). Let `ink` be the visual’s fg if present, else a default ink of `#ffffff`.

1. If the cell is `EMPTY_RENDER_CELL`: occupancy 0, zeros, done.
2. Take `CharacterVisual`. `rev = visual.reverse`.
3. `fg = ink`, `bg = visual.bg` (optional).
4. If `rev`:
   - New background = `fg` (always present after this).
   - New foreground = original `bg` if any, else `term_bg`.
   - Set `has_background`.
5. Else: `has_background` iff original visual had a background color.
6. `has_glyph` iff the symbol is non-empty and not a space (U+0020). Spaces never set `has_glyph`; their fill is occupancy background only.
7. Write resolved fg/bg (alpha 255 when that channel is present, else 0), occupancy, flags without reverse.

Consequence: glyph-only + reverse produces a **background quad** (original ink as fill) and a glyph colored with `term_bg`. That is the required reverse-video cell.

Fixtures (test-only cells, all four occupancy combinations, each with reverse on and off): unpainted; space+bg; glyph no bg; glyph+bg. See [parity.md](parity.md).

## Frame

```c
typedef struct {
  uint32_t cols;
  uint32_t rows;
  const OmacyCell *cells;
} OmacyFrame;
```

Row-major. **Origin is top-left.** Index `row * cols + col`. Row 0 is the visual top; column 0 is the visual left; rows increase downward.

`fill_grid` remaps ttfx’s south-west terminal rows into this ABI. `cells` length is `cols * rows` via checked multiply; overflow is never published.

## Pointer lifetime

`cells` is borrowed from the session. Valid until the next **mutating** call on that session that returns `OMACY_OK` (`step` success, `resize` success, `destroy`). Failed calls that do not mutate (see postconditions) leave a previously published pointer valid.

Swift uploads to Metal (or copies) before returning from the main-thread display-link callback that called `step`. Storing the pointer on the view is a contract violation.

## Session API

```c
typedef struct {
  OmacyFrame frame;
  uint8_t    needs_begin_next; /* 1 = effect ended; last frame is in `frame` */
  uint8_t    _pad[3];
} OmacyStepResult;

omacy_status omacy_session_create(const OmacySessionConfig *cfg,
                                  uint32_t cols, uint32_t rows,
                                  OmacySession **out);
omacy_status omacy_session_resize(OmacySession *s, uint32_t cols, uint32_t rows);
omacy_status omacy_session_step(OmacySession *s, double elapsed_seconds,
                                OmacyStepResult *out);
omacy_status omacy_session_set_pending_config(OmacySession *s,
                                              const OmacyPendingConfig *cfg);
omacy_status omacy_session_begin_next(OmacySession *s);
omacy_status omacy_session_generation(const OmacySession *s, uint64_t *out);
omacy_status omacy_session_error_message(const OmacySession *s, char *buf, size_t buf_len);
void         omacy_session_destroy(OmacySession *s);
const char  *omacy_status_string(omacy_status status);
```

`create`: main thread. Validate + deep-copy `cfg`. Validate `cols`/`rows` (caps). Build the first effect on those dimensions. On `OMACY_OK`, `*out` is non-null; no frame until `step`. On failure, `*out` is NULL. Off the main thread → `OMACY_ERR_WRONG_THREAD` and `*out` is NULL.

`step`: main thread. Accumulate 60 Hz (architecture.md). If the effect ends this call: apply **boundary content** (below) **without changing geometry**, set `needs_begin_next = 1`, do **not** construct the next effect, publish the last frame. Otherwise `needs_begin_next = 0`. On failure, `out->frame` is zeroed (`cells` NULL) and `needs_begin_next = 0`.

`resize`: main thread. The **only** operation that changes geometry. On `OMACY_OK`, rebuild `EngineCtx` at the new size; previous `cells` pointer is invalid; no frame published (next `step` or `begin_next` publishes). On failure without rebuild: previous pointer remains valid, dimensions unchanged. Calling `resize` while `needs_begin_next` is set is allowed and expected (Swift applies font-driven size before `begin_next`).

`set_pending_config`: main thread. Validate + deep-copy into `pending`. No geometry. On failure, pending is unchanged. Does not publish or invalidate `cells`. Applied as content at the next effect boundary, never as a resize.

`begin_next`: main thread. Legal only when `needs_begin_next` is set; otherwise `OMACY_ERR_INVALID_ARG`. Constructs the next effect on the **current** `cols`/`rows` (post-`resize` if Swift just called it). Increments `generation`. Clears `needs_begin_next`. Does not publish a frame; the next `step` does.

`generation`: main thread. Allowed on a dead session (last generation). Writes `*out`. On null `s`/`out`: `OMACY_ERR_NULL` and does not write if `out` is null.

`error_message`: main thread. Allowed on a dead session. Copies a truncated, always-NUL-terminated message. `s == NULL` reads **thread-local** last error. `buf == NULL` → `OMACY_ERR_NULL`.

`destroy`: main thread. `NULL` is a no-op. Wrong thread: **no-op**, TLS `OMACY_ERR_WRONG_THREAD`. Swift must call `destroy` on the main thread **before** invalidating the display link or tearing down the renderer.

### Boundary content (effect end, inside `step`, before `needs_begin_next`)

Applies art / effect name / background only. **Never** writes `cols`/`rows`.

Exactly one of:

1. If `pending` is set (successful `set_pending_config` since last boundary): apply those content fields, clear pending. **Do not** read disk.
2. Else if `config_dir` is non-empty: read `screensaver.txt` and the engine keys of `settings.json` (`effect`, `background` only). Ignore `fontSize`, `asciiMode`, `threshold`, `invert`. Validate; on failure keep last-known-good content.
3. Else: keep in-memory content.

Disk and pending configs have no dimensions. A resize queued-then-applied cannot happen because geometry is not in those structs.

## Main-thread ownership

Every **production** session is owned by the process main thread (`@MainActor` in Swift). `create` requires `pthread_main_np()` (or equivalent). If `create` is not on the main thread → `OMACY_ERR_WRONG_THREAD`.

Every later session function except `omacy_status_string` requires that same thread (the main thread). Mismatch → `OMACY_ERR_WRONG_THREAD` (or the void/pointer fallbacks). **No mutex. No hop onto an arbitrary “display-link thread.”** An `NSView.displayLink` does not give you a dispatch queue.

The display link is added to the **main run loop** (`.main`, `.common`). Its callback runs on the main thread and may call `step`.

Teardown, on the main thread, in this order:

1. `omacy_session_destroy`
2. Invalidate the display link
3. Drop Metal / atlas

`deinit` is an assertion + fallback (`assertionFailure` in debug if the session is still live, then destroy if still on main). It is not the primary cleanup path.

UI / config that is already on the main thread calls `set_pending_config` / `destroy` directly. Background work `DispatchQueue.main.async`s onto main. Do not target a display-link-specific queue.

Rust unit tests of the engine crate (no FFI) may run on any thread. FFI `create` off main always fails.

Re-entrant `step` on the main thread (step → callback → step) → `OMACY_ERR_INVALID_ARG`.

## ASCII conversion

No session. May be called from any thread. Results are owned.

```c
omacy_status omacy_ascii_from_bytes(const OmacyAsciiConfig *cfg,
                                    const uint8_t *bytes, size_t len,
                                    OmacyText **out);
void         omacy_text_free(OmacyText *t);
const char  *omacy_text_utf8(const OmacyText *t);
size_t       omacy_text_len(const OmacyText *t);
```

`ascii_from_bytes` validates + deep-copies `cfg` before work. On `OMACY_OK`, `*out` is non-null. On failure, `*out` is NULL. Limit → `OMACY_ERR_LIMIT`.

`text_utf8` is valid until `text_free`. `text_free(NULL)` is a no-op. `text_utf8(NULL)` is `NULL`. `text_len(NULL)` is `0`.

Format: PNG magic, else SVG. SVG: no external resources, scripts, network, file refs, or external fonts.

## Worker rendering (not MVP)

Do not move a session off the main thread. A future worker would consume immutable snapshots produced on main. Not in MVP.
