# Omacy architecture

Omacy is a native macOS host app with a `com.apple.screensaver` extension. A patched Rust `ttfx` engine publishes a packed cell grid through a generated C ABI; Swift turns that grid into Metal instances and presents it on a display link.

Companion contracts: [FFI](ffi.md), [parity](parity.md), [macOS gates](macos-gates.md), and [ttfx vendor provenance](vendor-ttfx.md).

## System shape

```text
~/.config/omacy/{screensaver.txt,settings.json}
                    │ read + validate at startup/effect boundaries
                    ▼
      OmacyConfigRepository (Swift)
         public files → process-private sandbox cache → bundled defaults
                    │ immutable snapshot
                    ▼
OmacyRenderer (@MainActor, orchestration only)
  ├─ OmacyTransitionCoordinator  transactional state + retry identities
  ├─ OmacyEngineSession          session-lifecycle C pointers and statuses
  ├─ OmacyMetalGridRenderer      atlas, frame resources, Metal encoding
  └─ OmacyDisplayLinkDriver      main-run-loop display-link lifecycle
                    │
Host OmacyWorkspaceModel → OmacyAsciiConverter → image/owned-text conversion FFI
                    │
                    ▼
 libomacy_engine.a → checked-in patched vendor/ttfx snapshot
```

`OmacyHostView` embeds the renderer in the app. `OmacySaverView` embeds the same renderer in the extension. Each fullscreen saver view owns an independent session, so displays choose and advance effects independently.

Production supports Apple silicon only (`arm64`, macOS 15 or later). Debug and Release pin `ARCHS = arm64` in the checked-in Xcode project, and the Rust build phase rejects any input other than one exact `arm64` architecture before invoking Cargo.

## Configuration boundary

The public, agent-friendly contract is:

```text
~/.config/omacy/screensaver.txt
~/.config/omacy/settings.json
```

The host app and user tools may write these files. The screensaver extension is read-only and has narrowly scoped home-relative read entitlements for exactly these two paths. It has no App Group entitlement and never writes the canonical or legacy shared files. It may persist last-good values inside its own sandbox container. The host temporarily retains the old App Group entitlement solely to migrate existing installs.

Swift owns discovery, validation, migration, caching, and every filesystem operation. Rust receives explicit bytes and never knows a configuration path. There is no filesystem watcher: a running saver loads a fresh snapshot at the next effect boundary. The in-app pinned preview is the exception; its editor updates are debounced and replace the preview session transactionally.

The files are independently replaceable. A valid new `settings.json` remains usable when art is invalid, and valid new art remains usable when settings are invalid. Each valid public value updates the current process's private last-good cache inside that process's sandbox container. Host and extension caches are never shared and never use the App Group. Loading resolves each value in this order:

1. valid public file;
2. in-memory value or that process's private last-good cache under Application Support;
3. bundled default.

Host saves use a same-directory temporary file followed by replacement. A failure identifies the file that failed; it does not roll back an independently successful sibling-file replacement.

`settings.json` contains the selected effect pool, background, font size, and image-conversion preferences. Effect names are validated against the catalog exported by Rust rather than a duplicated Swift list. When `effects` is present, it is authoritative and Swift synchronizes the legacy `effect` field to the pool (`random` unless exactly one effect is selected). When `effects` is absent, Swift imports the legacy `effect` value as either one selected effect or the complete catalog. An empty `effects` array normalizes to the complete catalog.

### Legacy migration

Only the host migrates. If both public files are already valid, legacy state is untouched. Otherwise one migration attempt reads legacy App Group `UserDefaults`, then legacy App Group files for values still missing.

The attempt marker is written before reading legacy state, including when no usable data is found or migration fails. An explicit retry clears that marker. The extension never performs migration.

## Direct agent workflow

An agent or script can drive the saver without app automation:

```sh
mkdir -p "$HOME/.config/omacy"
$EDITOR "$HOME/.config/omacy/screensaver.txt"
$EDITOR "$HOME/.config/omacy/settings.json"
```

Write complete UTF-8 ASCII art without ESC bytes/sequences and a valid JSON object. TAB and NUL are accepted; the validator does not reject every control byte. Publish with a temporary file plus rename when coordinating multiple writers. Changes become visible when each session reaches its next effect boundary; there is intentionally no live watcher or mid-effect restart. A ready-to-run example and the settings schema are in [agent-configuration.md](agent-configuration.md).

## Engine and transition contract

```text
create → RUNNING → WAITING_FOR_BEGIN → begin_next_with_config → RUNNING
                    └─ validation/construction failure: unchanged, retryable
```

At effect completion, `step` publishes and retains the final frame with `needs_begin_next = 1`. Swift presents that frame before attempting a transition. `omacy_session_begin_next_with_config` is the only in-session boundary operation: content, effect-pool slices, columns, and rows are validated and constructed off to the side, then promoted with the generation. Background and seed are not supplied at this boundary. The selector is seeded or entropy-initialized only at session creation; each boundary advances a clone of that continuous stream and promotes the advanced clone only on success, so a failed attempt and retry select exactly what an uninterrupted control session would select. A background change is applied by constructing a replacement session before discarding the old one. A failed boundary call leaves the old frame, generation, geometry, and waiting state intact. Success increments the generation once and invalidates the previous cell pointer.

There are no separate pending-config, resize, or parameterless begin calls. Swift promotes its font and layout state only after the Rust transition succeeds. See [ffi.md](ffi.md) for pointer and error contracts.

The immutable effect catalog is exposed through indexed FFI accessors. An effect-pool count of zero means every catalog entry; explicit pools must contain known, unique UTF-8 names.

## Rendering and lifecycle

`OmacyRenderer` coordinates the boundary but does not implement every layer:

- `OmacyTransitionCoordinator` owns transactional Swift-side promotion, pinned-preview state, retry identities, and recovery state.
- `OmacyEngineSession` is the sole session-lifecycle FFI boundary. It owns session pointers, status classification, generation tracking, and replacement.
- `OmacyAsciiConverter` is the separate, host-only image-conversion FFI boundary. It converts C results into Swift strings and owns the exactly-once `OmacyText` release contract, so UI code never handles raw text pointers or statuses.
- `OmacyMetalGridRenderer` owns the glyph atlas, renderer-attachment frame resources, grid packing, and Metal commands.
- `OmacyDisplayLinkDriver` owns creation, retargeting, and invalidation of the main-run-loop display link.

Frames use a top-left cell origin. Background and glyph occupancy are separate; reverse video is resolved by Rust. Metal clears with the published frame color, then draws packed background and glyph quads. The renderer copies packed instances into attachment-owned Metal buffers. Leases keep those copied GPU inputs alive and prevent a slot from being overwritten until its command buffer completes; they do not retain Rust frame pointers and are not owned by a Rust generation.

Simulation advances at a fixed virtual 60 Hz with a four-step catch-up cap, independent of a 60 or 120 Hz presentation rate. The Settings preview is rate limited. Screen-specific scale and bounds come from the saver view's window, not `NSScreen.main`; initial attachment waits for ScreenSaverEngine's window migration.

## Generated ABI

The public header is [the committed generated file](../crates/omacy-engine/include/omacy.h). It is produced by the workspace `xtask` using pinned `cbindgen` 0.29.4:

```sh
cargo xtask header write
cargo xtask header check
```

Do not edit the header manually. CI checks byte-for-byte generation, C11 and C++17 inclusion, ABI linking, and continued absence of removed legacy symbols.

## Vendored ttfx

`vendor/ttfx` is a checked-in snapshot, not a Git submodule. `vendor/ttfx/PIN` records the exact upstream tag and commits. The normalized local delta lives at `vendor/patches/ttfx-omacy.patch`, and the verifier reconstructs the snapshot from upstream while rejecting unrecorded or individual effect-file changes. See [vendor-ttfx.md](vendor-ttfx.md).

## Distribution and verification

The user installs the signed, notarized app in `/Applications`; only that installed copy is a release-gate candidate, and the host registers its embedded extension. A DerivedData build is a separate compile/development surface and must not be mixed with the `/Applications` registration. Sparkle checks the signed appcast and exposes user-approved updates. Omacy does not silently replace itself or delete its bundle.

macOS can keep the previous screensaver extension process alive after replacing the containing app. On the first host launch for a new embedded extension version, Omacy reconciles the `/Applications` registration and restarts `WallpaperAgent` once when Omacy is active. The recorded extension identity suppresses repeat restarts on later launches and inactive installations do not disturb the wallpaper service.

Linux CI proves Rust tests, vendor tests, header generation, and ABI checks. macOS CI proves unsigned arm64 host/extension builds and Swift unit tests. Neither environment proves ScreenSaverEngine behavior, sandbox/TCC behavior, registration, idle activation, or multi-display teardown. Those remain signed, physical-Mac release gates in [macos-gates.md](macos-gates.md), including the requirement that repeated saver launches produce no file-access prompt.

## Non-goals

- A terminal subprocess or ANSI rendering in the app.
- A legacy `.saver` shipping format.
- Intel or universal binaries.
- Filesystem watchers or mid-effect configuration restarts.
- Rust filesystem access or App Group configuration ownership.
- Per-effect parameter UIs or modifications to vendored effect implementations.
- Pixel identity with a terminal; parity is measured at the cell-grid boundary.
