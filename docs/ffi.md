# Omacy engine C ABI

The engine is an in-memory renderer. Swift owns configuration discovery, migration, validation, caching, and disk I/O. Every session is created from explicit ASCII bytes, and every subsequent generation is supplied as one atomic transition packet.

The generated public declaration is `crates/omacy-engine/include/omacy.h`. Regenerate it with `cargo xtask header write`; CI checks the committed header with `cargo xtask header check`. Do not edit the header by hand.

## Ownership and threading

- `OmacySession` is opaque and owned by the caller between `omacy_session_create` and `omacy_session_destroy`.
- Omacy's Swift integration keeps session creation, mutation, and destruction on `@MainActor`. This is a host policy, not a threading guarantee encoded by the generated C header. Immutable catalog/status accessors and the thread-local null-session diagnostic do not require a session owner.
- Input strings and effect-pool slices are borrowed only for the duration of a call. The engine validates and deep-copies accepted content before returning.
- Published cell storage is session-owned. It remains valid until the next successful transition, session death, or destruction.
- The engine never reads or writes configuration files. It has no configuration-directory concept.

## Lifecycle

```text
create(bytes, effect, background, geometry) -> RUNNING
RUNNING -- effect completes --> WAITING_FOR_BEGIN
WAITING_FOR_BEGIN -- begin_next_with_config succeeds --> RUNNING
any live state -- panic --> DEAD
```

`omacy_session_step` always publishes the last complete grid on success. Effect completion is not an error: the result sets `needs_begin_next = 1` and retains the final frame. Further steps while waiting republish that frame with zero advances.

`OMACY_ERR_DEAD` means the session previously panicked or was marked dead. Only destruction, generation lookup, and error lookup remain legal.

## Creation

`OmacySessionConfig.ascii` is required UTF-8 ASCII-art content. Swift must resolve public configuration, last-known-good cache, or bundled fallback before calling the engine. `effect`, `effect_pool`, background RGBA, optional seed, and initial geometry are also copied into the new session. `effect_pool_count == 0` means the complete catalog and the pointer is ignored. A nonzero count requires a non-null array whose entries are non-empty UTF-8, known, unique effect names. A pinned (non-`random`) `effect` must belong to an explicit pool.

Creation rejects missing/empty content, invalid UTF-8, ESC bytes/sequences, unknown effects, invalid flags, and geometry or content beyond the documented limits. TAB and NUL are accepted; this is not a blanket control-byte rejection. Failure leaves the output session pointer null.

## Atomic next-generation transition

```c
omacy_status omacy_session_begin_next_with_config(
    OmacySession *session,
    const uint8_t *content,
    size_t content_len,
    const OmacyByteSlice *effect_pool,
    size_t effect_pool_count,
    uint32_t cols,
    uint32_t rows);
```

This is the sole in-session boundary operation. It validates the complete candidate, constructs the next effect and frame storage off to the side, and promotes content, effect pool, geometry, generation, and the advanced selector state together only after construction succeeds. Background and seed are not transition inputs: the session keeps its background and its selector stream is seeded or entropy-initialized only at creation. Candidate construction uses a clone of that stream, so failure consumes no selection and an identical retry remains deterministic. Swift recreates the complete session transactionally when the background changes.

- It is legal only when `needs_begin_next` is set.
- `effect_pool_count == 0` means the complete catalog. Otherwise every item must be non-empty UTF-8, known, unique, and within the catalog-size limit.
- On any error, the previous frame pointer, dimensions, clear color, generation, content, and waiting state remain unchanged.
- A successful transition increments generation exactly once and invalidates the previous frame pointer.

There are intentionally no separate resize, pending-config, or parameterless begin-next calls. Geometry and content cannot drift into different generations.

## Effect catalog

`omacy_effect_catalog_count` and `omacy_effect_catalog_get` expose the immutable engine catalog so Swift does not duplicate effect names. Returned name bytes have process lifetime and must not be freed. An invalid index clears both outputs and returns `OMACY_ERR_INVALID_ARG`.

## Status and errors

All status-returning entry points are panic-contained. A panic returns `OMACY_ERR_PANIC`; if a session was involved it becomes dead and published cells are invalidated. Recoverable validation or construction errors leave live state unchanged.

`omacy_session_error_message` copies a NUL-terminated diagnostic into caller storage. A null session returns the thread-local diagnostic from failures that occurred before a session existed. `omacy_status_string` returns immutable process-lifetime names for known status values.

On a failed `step`, a non-null output is zeroed. Catalog access similarly clears its outputs on failure. Callers should branch on the status before reading any other output.

## Step timing

The engine advances on a virtual 60 Hz accumulator with at most four advances per call. `steps_taken` is `0...4`; when an effect finishes on the first non-advancing call, it is reported as one changed step because the final frame was published. Waiting steps report zero and do not change generation.

Swift should render the returned frame first. If `needs_begin_next` is set, it should load the latest validated snapshot, compute the target layout, call the atomic transition, and promote Swift-side font/layout state only after `OMACY_OK`.
