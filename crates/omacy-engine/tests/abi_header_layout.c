#include "omacy.h"

#include <stddef.h>
#include <pthread.h>
#include <stdint.h>

#if defined(__cplusplus)
#define OMACY_STATIC_ASSERT(condition, message) static_assert(condition, message)
#define OMACY_ALIGNOF(type) alignof(type)
#else
#define OMACY_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#define OMACY_ALIGNOF(type) _Alignof(type)
#endif

OMACY_STATIC_ASSERT(sizeof(void *) == 8, "the Omacy ABI requires LP64");
OMACY_STATIC_ASSERT(sizeof(size_t) == 8, "the Omacy ABI requires LP64");

OMACY_STATIC_ASSERT(OMACY_OK == 0, "status value");
OMACY_STATIC_ASSERT(OMACY_ERR_WRONG_THREAD == 7, "status value");
OMACY_STATIC_ASSERT(sizeof(omacy_status) == 4, "omacy_status size");
OMACY_STATIC_ASSERT(OMACY_CELL_HAS_BACKGROUND == 1, "cell flag");
OMACY_STATIC_ASSERT(OMACY_CELL_HAS_GLYPH == 2, "cell flag");
OMACY_STATIC_ASSERT(OMACY_ASCII_BRAILLE == 0, "ASCII mode");
OMACY_STATIC_ASSERT(OMACY_ASCII_BLOCK == 1, "ASCII mode");

OMACY_STATIC_ASSERT(sizeof(OmacyCell) == 16, "OmacyCell size");
OMACY_STATIC_ASSERT(OMACY_ALIGNOF(OmacyCell) == 4, "OmacyCell alignment");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, glyph) == 0, "OmacyCell.glyph offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, fg_r) == 4, "OmacyCell.fg_r offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, fg_g) == 5, "OmacyCell.fg_g offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, fg_b) == 6, "OmacyCell.fg_b offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, fg_a) == 7, "OmacyCell.fg_a offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, bg_r) == 8, "OmacyCell.bg_r offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, bg_g) == 9, "OmacyCell.bg_g offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, bg_b) == 10, "OmacyCell.bg_b offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, bg_a) == 11, "OmacyCell.bg_a offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, flags) == 12, "OmacyCell.flags offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, occupancy) == 13, "OmacyCell.occupancy offset");
OMACY_STATIC_ASSERT(offsetof(OmacyCell, _pad) == 14, "OmacyCell._pad offset");

OMACY_STATIC_ASSERT(sizeof(OmacyFrame) == 24, "OmacyFrame size");
OMACY_STATIC_ASSERT(OMACY_ALIGNOF(OmacyFrame) == 8, "OmacyFrame alignment");
OMACY_STATIC_ASSERT(offsetof(OmacyFrame, cols) == 0, "OmacyFrame.cols offset");
OMACY_STATIC_ASSERT(offsetof(OmacyFrame, rows) == 4, "OmacyFrame.rows offset");
OMACY_STATIC_ASSERT(offsetof(OmacyFrame, clear_r) == 8, "OmacyFrame.clear_r offset");
OMACY_STATIC_ASSERT(offsetof(OmacyFrame, clear_g) == 9, "OmacyFrame.clear_g offset");
OMACY_STATIC_ASSERT(offsetof(OmacyFrame, clear_b) == 10, "OmacyFrame.clear_b offset");
OMACY_STATIC_ASSERT(offsetof(OmacyFrame, clear_a) == 11, "OmacyFrame.clear_a offset");
OMACY_STATIC_ASSERT(offsetof(OmacyFrame, _pad) == 12, "OmacyFrame._pad offset");
OMACY_STATIC_ASSERT(offsetof(OmacyFrame, cells) == 16, "OmacyFrame.cells offset");

OMACY_STATIC_ASSERT(sizeof(OmacyStepResult) == 32, "OmacyStepResult size");
OMACY_STATIC_ASSERT(OMACY_ALIGNOF(OmacyStepResult) == 8, "OmacyStepResult alignment");
OMACY_STATIC_ASSERT(offsetof(OmacyStepResult, frame) == 0, "OmacyStepResult.frame offset");
OMACY_STATIC_ASSERT(offsetof(OmacyStepResult, needs_begin_next) == 24,
                    "OmacyStepResult.needs_begin_next offset");
OMACY_STATIC_ASSERT(offsetof(OmacyStepResult, steps_taken) == 25,
                    "OmacyStepResult.steps_taken offset");
OMACY_STATIC_ASSERT(offsetof(OmacyStepResult, _pad) == 26, "OmacyStepResult._pad offset");

OMACY_STATIC_ASSERT(sizeof(OmacySessionConfig) == 64, "OmacySessionConfig size");
OMACY_STATIC_ASSERT(OMACY_ALIGNOF(OmacySessionConfig) == 8, "OmacySessionConfig alignment");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, ascii) == 0,
                    "OmacySessionConfig.ascii offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, ascii_len) == 8,
                    "OmacySessionConfig.ascii_len offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, effect) == 16,
                    "OmacySessionConfig.effect offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, effect_len) == 24,
                    "OmacySessionConfig.effect_len offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, effect_pool) == 32,
                    "OmacySessionConfig.effect_pool offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, effect_pool_count) == 40,
                    "OmacySessionConfig.effect_pool_count offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, bg_r) == 48, "OmacySessionConfig.bg_r offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, bg_g) == 49, "OmacySessionConfig.bg_g offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, bg_b) == 50, "OmacySessionConfig.bg_b offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, bg_a) == 51, "OmacySessionConfig.bg_a offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, has_seed) == 52,
                    "OmacySessionConfig.has_seed offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, _pad) == 53,
                    "OmacySessionConfig._pad offset");
OMACY_STATIC_ASSERT(offsetof(OmacySessionConfig, seed) == 56, "OmacySessionConfig.seed offset");

OMACY_STATIC_ASSERT(sizeof(OmacyByteSlice) == 16, "OmacyByteSlice size");
OMACY_STATIC_ASSERT(OMACY_ALIGNOF(OmacyByteSlice) == 8, "OmacyByteSlice alignment");
OMACY_STATIC_ASSERT(offsetof(OmacyByteSlice, ptr) == 0, "OmacyByteSlice.ptr offset");
OMACY_STATIC_ASSERT(offsetof(OmacyByteSlice, len) == 8, "OmacyByteSlice.len offset");

OMACY_STATIC_ASSERT(sizeof(OmacyAsciiConfig) == 16, "OmacyAsciiConfig size");
OMACY_STATIC_ASSERT(OMACY_ALIGNOF(OmacyAsciiConfig) == 4, "OmacyAsciiConfig alignment");
OMACY_STATIC_ASSERT(offsetof(OmacyAsciiConfig, mode) == 0, "OmacyAsciiConfig.mode offset");
OMACY_STATIC_ASSERT(offsetof(OmacyAsciiConfig, width) == 4, "OmacyAsciiConfig.width offset");
OMACY_STATIC_ASSERT(offsetof(OmacyAsciiConfig, height) == 8, "OmacyAsciiConfig.height offset");
OMACY_STATIC_ASSERT(offsetof(OmacyAsciiConfig, threshold) == 12,
                    "OmacyAsciiConfig.threshold offset");
OMACY_STATIC_ASSERT(offsetof(OmacyAsciiConfig, invert) == 13, "OmacyAsciiConfig.invert offset");
OMACY_STATIC_ASSERT(offsetof(OmacyAsciiConfig, trim) == 14, "OmacyAsciiConfig.trim offset");
OMACY_STATIC_ASSERT(offsetof(OmacyAsciiConfig, _pad) == 15, "OmacyAsciiConfig._pad offset");

static omacy_status (*const create_signature)(const OmacySessionConfig *, uint32_t, uint32_t,
                                               OmacySession **) = omacy_session_create;
static omacy_status (*const begin_signature)(OmacySession *, const uint8_t *, size_t,
                                              const OmacyByteSlice *, size_t, uint32_t,
                                              uint32_t) = omacy_session_begin_next_with_config;
static size_t (*const catalog_count_signature)(void) = omacy_effect_catalog_count;
static omacy_status (*const catalog_get_signature)(size_t, const uint8_t **, size_t *) =
    omacy_effect_catalog_get;
static const char *(*const status_signature)(omacy_status) = omacy_status_string;

typedef struct {
  OmacySession *session;
  const uint8_t *content;
  const OmacyByteSlice *pool;
  omacy_status status;
} WrongThreadContext;

static void *begin_from_wrong_thread(void *opaque) {
  WrongThreadContext *context = (WrongThreadContext *)opaque;
  context->status = begin_signature(context->session, context->content, 4, context->pool, 1, 20, 8);
  return NULL;
}

static int require_generation(OmacySession *session, uint64_t expected) {
  uint64_t generation = UINT64_MAX;
  return omacy_session_generation(session, &generation) == OMACY_OK && generation == expected;
}

int main(void) {
  (void)catalog_count_signature;
  (void)catalog_get_signature;
  const char *status = status_signature(OMACY_OK);
  if (status == NULL || status[0] != 'O' || status_signature((omacy_status)99) != NULL) {
    return 2;
  }

  const uint8_t art[] = {'A'};
  const uint8_t random_effect[] = {'r', 'a', 'n', 'd', 'o', 'm'};
  const uint8_t wipe[] = {'w', 'i', 'p', 'e'};
  const OmacyByteSlice pool[] = {{wipe, sizeof(wipe)}};
  const OmacySessionConfig config = {
      art, sizeof(art), random_effect, sizeof(random_effect), pool, 1,
      0,   0,           0,             255,                   1,    {0, 0, 0}, 1};
  OmacySession *session = NULL;
  if (create_signature(&config, 20, 8, &session) != OMACY_OK || session == NULL) {
    return 3;
  }

  OmacyStepResult step = {{0, 0, 0, 0, 0, 0, 0, NULL}, 0, 0, {0, 0}};
  size_t attempts = 0;
  while (attempts++ < 20000 && !step.needs_begin_next) {
    if (omacy_session_step(session, 1.0 / 60.0, &step) != OMACY_OK) {
      return 4;
    }
  }
  if (!step.needs_begin_next || !require_generation(session, 0)) {
    return 5;
  }

  const uint8_t next[] = {'N', 'E', 'X', 'T'};
  const uint8_t unknown[] = {'n', 'o', 'p', 'e'};
  const OmacyByteSlice unknown_pool[] = {{unknown, sizeof(unknown)}};
  if (begin_signature(session, NULL, 1, pool, 1, 20, 8) != OMACY_ERR_INVALID_ARG ||
      !require_generation(session, 0)) {
    return 6;
  }
  if (begin_signature(session, next, sizeof(next), NULL, 1, 20, 8) != OMACY_ERR_INVALID_ARG ||
      !require_generation(session, 0)) {
    return 7;
  }
  if (begin_signature(session, next, sizeof(next), unknown_pool, 1, 20, 8) !=
          OMACY_ERR_INVALID_ARG ||
      !require_generation(session, 0)) {
    return 8;
  }
  if (begin_signature(session, next, sizeof(next), pool, 1, 513, 8) != OMACY_ERR_LIMIT ||
      !require_generation(session, 0)) {
    return 9;
  }

  WrongThreadContext wrong_thread = {session, next, pool, OMACY_OK};
  pthread_t thread;
  if (pthread_create(&thread, NULL, begin_from_wrong_thread, &wrong_thread) != 0 ||
      pthread_join(thread, NULL) != 0 || wrong_thread.status != OMACY_ERR_WRONG_THREAD ||
      !require_generation(session, 0)) {
    return 10;
  }
  if (begin_signature(session, next, sizeof(next), pool, 1, 20, 8) != OMACY_OK ||
      !require_generation(session, 1)) {
    return 11;
  }
  omacy_session_destroy(session);

  OmacySessionConfig invalid = config;
  invalid.effect_pool = NULL;
  invalid.effect_pool_count = 1;
  session = (OmacySession *)(uintptr_t)1;
  if (create_signature(&invalid, 20, 8, &session) != OMACY_ERR_INVALID_ARG || session != NULL) {
    return 12;
  }
  return 0;
}
