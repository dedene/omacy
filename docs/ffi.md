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

Effect completion is **not** an error. A successful `step` always publishes a grid. Completion enters `WAITING_FOR_BEGIN` (`needs_begin_next = 1`). The next effect is constructed only by `begin_next`.

### Signature classes and panic fallbacks

Every `extern "C"` entry is wrapped in `catch_unwind`. Unwind never crosses FFI.

| Class | Examples | Success | Panic / catch_unwind |
|---|---|---|---|
| `omacy_status` | `create`, `step`, `resize`, `set_pending_config`, `begin_next`, `generation`, `error_message`, `ascii_from_bytes` | `OMACY_OK` | `OMACY_ERR_PANIC`; session marked dead if one was involved; out-pointers NULLed as in the per-op table |
| `void` | `destroy`, `text_free` | — | Swallow. `destroy`: if main thread, free what can be freed and mark dead; if already dead, still free. Never unwind. |
| `const char *` | `status_string`, `text_utf8` | pointer | `NULL`. `status_string` is a static table and must not allocate; treat panic as a bug. |
| `size_t` | `text_len` | length | `0` |

`OMACY_ERR_DEAD`: session panicked earlier (or was otherwise marked dead). Legal calls: `destroy`, `error_message`, `generation`. Illegal: `step`, `resize`, `set_pending_config`, `begin_next` → `OMACY_ERR_DEAD` with no mutation.

## Session states

A live session is exactly one of:

| State | Meaning |
|---|---|
| `RUNNING` | A current effect exists. `step` may advance it. |
| `WAITING_FOR_BEGIN` | The current effect has ended. Selected content is already applied. The next effect is not constructed. |
| `DEAD` | Panic (or equivalent). Only diagnostics + `destroy`. |

```
create OK ──────────────────────────────► RUNNING
RUNNING + step, effect still going ─────► RUNNING
RUNNING + step, effect ends ────────────► WAITING_FOR_BEGIN
WAITING_FOR_BEGIN + step ───────────────► WAITING_FOR_BEGIN   (republish)
WAITING_FOR_BEGIN + begin_next OK ──────► RUNNING
WAITING_FOR_BEGIN + begin_next fail ────► WAITING_FOR_BEGIN   (unchanged)
any panic ──────────────────────────────► DEAD
```

`resize` and `set_pending_config` do not change this state. `needs_begin_next` is 1 iff the session is `WAITING_FOR_BEGIN`.

Entering `DEAD` (caught panic on any session function) invalidates every borrowed `cells` pointer from that session, including a pointer published by an earlier successful `step`. Do not read `cells` after `OMACY_ERR_PANIC`.

## Config structs

Strings are **pointer + length**. Length is authoritative. A null pointer is allowed only with `len == 0` (absent). Null + `len > 0` is `OMACY_ERR_INVALID_ARG`. Pointers need not be NUL-terminated; the implementation must not read past `len`.

`create` and `set_pending_config` **validate and deep-copy** every field into session-owned storage **before returning**. After `OMACY_OK`, the caller may immediately free or reuse the pointed-to memory. After any error, the session’s pending/current content config is unchanged (create: no session).

Geometry is **not** in these structs. `resize` is the only call that changes `cols`/`rows`. Boundary updates always keep the current dimensions.

```c
/* Content at create. No geometry. config_dir is create-only. */
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

/* Replaceable user settings. No geometry, no seed, no config_dir. */
typedef struct {
  const uint8_t *ascii;        /* empty = keep current art when applied */
  size_t         ascii_len;
  const uint8_t *effect;       /* required: "random" or a ttfx name */
  size_t         effect_len;
  uint8_t        bg_r, bg_g, bg_b, bg_a;
  uint8_t        _pad[3];
} OmacyPendingConfig;

#define OMACY_ASCII_BRAILLE 0u
#define OMACY_ASCII_BLOCK   1u

typedef struct {
  uint32_t mode;       /* OMACY_ASCII_BRAILLE or OMACY_ASCII_BLOCK */
  uint32_t width;      /* conversion columns, not the live grid */
  uint32_t height;     /* conversion rows, not the live grid */
  uint8_t  threshold;  /* 0–100 */
  uint8_t  invert;     /* 0 or 1 */
  uint8_t  trim;       /* 0 or 1 */
  uint8_t  _pad;
} OmacyAsciiConfig;
```

`OmacyAsciiConfig.width` / `height` are the **image-to-text** target, not the session canvas.

`config_dir` is create-only. Later disk reloads always use that path. `OmacyPendingConfig` cannot change it.

Validation on `OmacySessionConfig` / `OmacyPendingConfig` (all `INVALID_ARG` unless noted `LIMIT`):

- `effect` is `"random"` or a known ttfx name (exact, lowercase).
- `has_seed` is 0 or 1 (`SessionConfig` only).
- SessionConfig: `ascii` present, or `config_dir` present, or both. If both, inline `ascii` is the art; `config_dir` is used for later disk reloads of art/effect/background only.
- PendingConfig: `effect` required; empty `ascii` means keep the current art when the pending packet is applied.
- UTF-8 well-formed for every non-empty string. ASCII art is unstyled: no `ESC` (0x1B). `ESC` → `INVALID_ARG`.
- Neither struct may carry `cols`/`rows`/`fontSize`. Those fields do not exist.

`create` also takes `cols` and `rows` as separate arguments (same caps as `resize`).

`OmacyAsciiConfig`: `mode` is `OMACY_ASCII_BRAILLE` or `OMACY_ASCII_BLOCK`; `width` 1…256; `height` 1…128; `width * height` ≤ 32_768 (checked); `threshold` ≤ 100; `invert`/`trim` are 0 or 1.

Layout is fixed-width, not a C `enum` type. The crate asserts `size_of` / `align_of` / field offsets for `OmacyCell` (16 / 4), `OmacyAsciiConfig` (16 / 4), `OmacyFrame` (24 / 8 on LP64), and `OmacyStepResult` against the C header. cbindgen must emit `uint32_t mode`.

## Cell

16 bytes, `#[repr(C)]`, little-endian.

```c
typedef struct {
  uint32_t glyph;     /* Unicode scalar. 0 if !has_glyph. SPACE (0x20) is a real glyph. */
  uint8_t  fg_r, fg_g, fg_b, fg_a;
  uint8_t  bg_r, bg_g, bg_b, bg_a;
  uint8_t  flags;     /* reserved; fill_grid writes 0 */
  uint8_t  occupancy; /* bit0 has_background, bit1 has_glyph */
  uint8_t  _pad[2];
} OmacyCell;
```

**Occupancy** is the post-style occupancy Metal consumes. Terminal `reverse` is **not** a renderer concern.

Pinned ttfx **v0.3.2** effect files never set bold, italic, or underline. Those bits appear only if input art carries preexisting SGR, which this ABI rejects. MVP publishes `flags = 0`. Metal must not read `flags`. Bold / italic / underline are out of the MVP ABI.

| occupancy | Meaning | Draw |
|---|---|---|
| `0` | Unpainted (`EMPTY_RENDER_CELL`) | Skip. `frame.clear_*` shows. |
| `has_background` only | Filled cell, no coverage glyph | Background quad only |
| `has_glyph` only | Mark, no cell fill | Foreground quad if atlas coverage |
| both | Cell fill + mark | Background quad, then coverage fg |

`glyph == 0` is only valid when `has_glyph` is clear. A space with a background must have `has_background`.

### Reverse, resolved in `fill_grid`

`fill_grid` applies reverse **before** writing occupancy and colors. Published `flags` is always 0. Metal must not swap colors.

Let `term_bg` be **this published frame’s** clear color (the current effect’s background, default `#000000`). That is not `selected_next.background`. Let `ink` be the visual’s fg if present, else a default ink of `#ffffff`.

1. If the cell is `EMPTY_RENDER_CELL`: occupancy 0, zeros, done.
2. Take `CharacterVisual`. `rev = visual.reverse`.
3. `fg = ink`, `bg = visual.bg` (optional).
4. If `rev`:
   - New background = `fg` (always present after this).
   - New foreground = original `bg` if any, else `term_bg`.
   - Set `has_background`.
5. Else: `has_background` iff original visual had a background color.
6. `has_glyph` iff the symbol is non-empty and not a space (U+0020). Spaces never set `has_glyph`; their fill is occupancy background only.
7. Write resolved fg/bg (alpha 255 when that channel is present, else 0), occupancy, `flags = 0`.

Consequence: glyph-only + reverse produces a **background quad** (original ink as fill) and a glyph colored with `term_bg`. That is the required reverse-video cell.

Fixtures (test-only cells, all four occupancy combinations, each with reverse on and off): unpainted; space+bg; glyph no bg; glyph+bg. See [parity.md](parity.md).

## Frame

```c
typedef struct {
  uint32_t cols;
  uint32_t rows;
  uint8_t  clear_r, clear_g, clear_b, clear_a; /* resolved clear for THIS frame */
  uint32_t _pad;
  const OmacyCell *cells;
} OmacyFrame;
```

Row-major. **Origin is top-left.** Index `row * cols + col`. Row 0 is the visual top; column 0 is the visual left; rows increase downward.

`fill_grid` remaps ttfx’s south-west terminal rows into this ABI. `cells` length is `cols * rows` via checked multiply; overflow is never published.

`clear_*` is the background Metal uses to clear, and the `term_bg` used when resolving reverse for this grid. It is captured with the frame. A background chosen at the boundary for the *next* effect is `selected_next.background` and is **not** written here until that effect’s first published frame (the first `step` after a successful `begin_next`).

Layout (LP64): `OmacyFrame` is 24 bytes, align 8. The crate asserts size / align / offsets.

## Pointer lifetime

`cells` is borrowed from the session. Valid until the next **frame-buffer-mutating** call on that session that returns `OMACY_OK`:

- `step` success
- `resize` success
- `begin_next` success
- `destroy`

`set_pending_config` mutates pending content and does **not** invalidate `cells`. Recoverable `begin_next` failure does not replace storage and does **not** invalidate `cells`. Failed calls that do not mutate the frame buffer leave a previously published pointer valid. Entering `DEAD` invalidates every previously published pointer.

Required display-link order on the main thread:

1. `step`
2. Synchronously upload or copy `out->frame` (cells **and** `clear_*`)
3. Then, if `needs_begin_next`: apply font, `resize`, `begin_next`

Present this callback’s frame (the completed effect’s last frame when entering wait). The new effect publishes on the **next** callback. Storing the `cells` pointer on the view is a contract violation.

## Session API

```c
typedef struct {
  OmacyFrame frame;
  uint8_t    needs_begin_next; /* 1 iff WAITING_FOR_BEGIN; last frame is in `frame` */
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

`create`: main thread. Validate + deep-copy `cfg`. Validate `cols`/`rows` (caps). Build the first effect on those dimensions. Session starts `RUNNING`, `generation = 0`, accumulator 0. On `OMACY_OK`, `*out` is non-null; no frame until `step`. On failure, `*out` is NULL. Off the main thread → `OMACY_ERR_WRONG_THREAD` and `*out` is NULL.

`step`: if `out == NULL` → `OMACY_ERR_NULL`. Do not dereference `out`. Session state is unchanged.

`step` (`RUNNING`): main thread. Accumulate 60 Hz (architecture.md). If the effect ends this call: `fill_grid` the last frame using the **current** background as `clear_*` / `term_bg`, cache that frame, reset the 60 Hz accumulator to 0, apply **boundary content** into `selected_next` (below) **without changing geometry and without rewriting the cache**, enter `WAITING_FOR_BEGIN`, set `needs_begin_next = 1`, do **not** construct the next effect, publish the cached frame. Otherwise stay `RUNNING`, `needs_begin_next = 0`. On failure with a non-null `out`: zero `out->frame` (`cells` NULL, `clear_*` 0) and `needs_begin_next = 0`.

`step` (`WAITING_FOR_BEGIN`): main thread. Republish the cached frame (same `clear_*`) with `needs_begin_next = 1`. Do **not** advance, do **not** touch the accumulator (already 0), do **not** reload disk, do **not** consume pending, do **not** change `generation`. Reject NaN / negative / infinite `elapsed` as `INVALID_ARG` without leaving this state and without changing the cache; if `out` is non-null, zero the published result. After a successful `resize` in this state, the cache is an unpainted grid at the new size with the **same captured `clear_*`**; republish that.

`resize`: main thread. The **only** operation that changes geometry. Legal in `RUNNING` and `WAITING_FOR_BEGIN`. On `OMACY_OK`, rebuild storage at the new size; previous `cells` pointer is invalid; no frame published (the next `step` publishes). State is unchanged. On failure without rebuild: previous pointer remains valid, dimensions unchanged.

`set_pending_config`: main thread. Legal in `RUNNING` and `WAITING_FOR_BEGIN`. Validate + deep-copy into `pending`. No geometry. On failure, pending is unchanged. Does not publish or invalidate `cells`. Queued while `RUNNING` applies at the next boundary (the step that enters `WAITING_FOR_BEGIN`). Queued **after** entering `WAITING_FOR_BEGIN` applies at the **following** boundary, not the imminent `begin_next`.

`begin_next`: main thread. Legal only in `WAITING_FOR_BEGIN`; otherwise `OMACY_ERR_INVALID_ARG`. Atomic:

- **Success:** construct the next effect from **selected** content (applied when entering wait) on the **current** `cols`/`rows`. Promote `selected_next.background` to the current background. Install the effect. Increment `generation`. Enter `RUNNING` with accumulator 0. Invalidate the previous `cells` pointer. Do not publish a frame; the next `step` does, and that frame’s `clear_*` is the promoted background.
- **Recoverable failure** (`ENGINE`, `LIMIT`, `INVALID_ARG` after a construct attempt): do not install. Selected content and geometry unchanged. `generation` unchanged. Stay `WAITING_FOR_BEGIN`. Previous `cells` remains valid. An identical retry is legal.
- **Panic:** `OMACY_ERR_PANIC`, session `DEAD`.

`generation`: main thread. Allowed on a dead session (last generation). Writes `*out`. On null `s`/`out`: `OMACY_ERR_NULL` and does not write if `out` is null.

`error_message(NULL, buf, buf_len)`: **any thread**. Reads that thread’s TLS last error (so a wrong-thread `destroy` / other void call can be diagnosed on the thread that made it). `buf == NULL` → `OMACY_ERR_NULL`. `buf_len < 1` → `OMACY_ERR_INVALID_ARG` (NUL termination is impossible). `buf_len >= 1` writes at most `buf_len - 1` payload bytes and `buf[written] = 0`.

`error_message(s, buf, buf_len)` with non-null `s`: main thread. Allowed on a dead session. Same buffer rules.

`destroy`: main thread. `NULL` is a no-op. Wrong thread: **no-op**, TLS `OMACY_ERR_WRONG_THREAD`. Swift must call `destroy` on the main thread **before** invalidating the display link or tearing down the renderer.

### Boundary content (after the last frame is cached, before entering `WAITING_FOR_BEGIN`)

Runs **once** on the transition into wait, **after** the last frame is filled and cached. Writes `selected_next` (art / effect name / background) only. **Never** writes `cols`/`rows`. **Never** rewrites the cached frame or its `clear_*`. Later `step`s in wait do not run this.

Two backgrounds exist until `begin_next` succeeds:

- **Published / cached `clear_*`** — the completed effect’s background. Metal clears with this. Reverse on the cached grid used this as `term_bg`.
- **`selected_next.background`** — the next effect’s background. Promoted only when `begin_next` returns `OMACY_OK`.

Exactly one of:

1. If `pending` is set (successful `set_pending_config` since last boundary, and it was queued **before** this transition): apply those content fields, clear pending. **Do not** read disk. That packet becomes **selected** content.
2. Else if `config_dir` is non-empty: read `screensaver.txt` and the engine keys of `settings.json` (`effect`, `background` only). Ignore `fontSize`, `asciiMode`, `threshold`, `invert`. Validate; on failure keep last-known-good content. That result becomes selected.
3. Else: keep in-memory content as selected.

`begin_next` uses selected content. A `set_pending_config` that arrives while already waiting stays queued for the next transition into wait.

Disk and pending configs have no dimensions. A resize queued-then-applied cannot happen because geometry is not in those structs.

## Main-thread ownership

Every **production** session is owned by the process main thread (`@MainActor` in Swift). `create` requires `pthread_main_np()` (or equivalent). If `create` is not on the main thread → `OMACY_ERR_WRONG_THREAD`.

Every later session function except `omacy_status_string` and `error_message(NULL, …)` requires that same thread (the main thread). Mismatch → `OMACY_ERR_WRONG_THREAD` (or the void/pointer fallbacks). **No mutex. No hop onto an arbitrary “display-link thread.”** An `NSView.displayLink` does not give you a dispatch queue.

A void call on the wrong thread (e.g. `destroy`) writes `OMACY_ERR_WRONG_THREAD` into **that thread’s** TLS. Read it with `error_message(NULL, …)` on the same thread.

The display link is added to the **main run loop** (`.main`, `.common`). Its callback runs on the main thread and may call `step`. A callback that lands in `WAITING_FOR_BEGIN` republishes; it does not error.

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

`ascii_from_bytes` validates + deep-copies `cfg` before work. On `OMACY_OK`, `*out` is non-null. On failure, `*out` is NULL. Over conversion limits → `OMACY_ERR_LIMIT` and no text object (stateless; there is no last-known-good).

`text_utf8` is valid until `text_free`. `text_free(NULL)` is a no-op. `text_utf8(NULL)` is `NULL`. `text_len(NULL)` is `0`.

Format: PNG magic, else SVG. SVG: no external resources, scripts, network, file refs, or external fonts.

## Worker rendering (not MVP)

Do not move a session off the main thread. A future worker would consume immutable snapshots produced on main. Not in MVP.
