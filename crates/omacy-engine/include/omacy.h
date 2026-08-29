#ifndef OMACY_H
#define OMACY_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#define OMACY_CELL_HAS_BACKGROUND 1
#define OMACY_CELL_HAS_GLYPH 2
typedef int32_t omacy_status;
#define OMACY_OK ((omacy_status)0)
#define OMACY_ERR_NULL ((omacy_status)1)
#define OMACY_ERR_INVALID_ARG ((omacy_status)2)
#define OMACY_ERR_LIMIT ((omacy_status)3)
#define OMACY_ERR_ENGINE ((omacy_status)4)
#define OMACY_ERR_PANIC ((omacy_status)5)
#define OMACY_ERR_DEAD ((omacy_status)6)
#define OMACY_ERR_WRONG_THREAD ((omacy_status)7)
typedef struct OmacyText OmacyText;


#define OMACY_ASCII_BLOCK 1

#define OMACY_ASCII_BRAILLE 0

typedef struct OmacySession OmacySession;

typedef struct {
  uint32_t mode;
  uint32_t width;
  uint32_t height;
  uint8_t threshold;
  uint8_t invert;
  uint8_t trim;
  uint8_t _pad;
} OmacyAsciiConfig;

typedef struct {
  const uint8_t *ptr;
  size_t len;
} OmacyByteSlice;

typedef struct {
  const uint8_t *ascii;
  size_t ascii_len;
  const uint8_t *effect;
  size_t effect_len;
  const OmacyByteSlice *effect_pool;
  size_t effect_pool_count;
  uint8_t bg_r;
  uint8_t bg_g;
  uint8_t bg_b;
  uint8_t bg_a;
  uint8_t has_seed;
  uint8_t _pad[3];
  uint64_t seed;
} OmacySessionConfig;

typedef struct {
  uint32_t glyph;
  uint8_t fg_r;
  uint8_t fg_g;
  uint8_t fg_b;
  uint8_t fg_a;
  uint8_t bg_r;
  uint8_t bg_g;
  uint8_t bg_b;
  uint8_t bg_a;
  uint8_t flags;
  uint8_t occupancy;
  uint8_t _pad[2];
} OmacyCell;

typedef struct {
  uint32_t cols;
  uint32_t rows;
  uint8_t clear_r;
  uint8_t clear_g;
  uint8_t clear_b;
  uint8_t clear_a;
  uint32_t _pad;
  const OmacyCell *cells;
} OmacyFrame;

typedef struct {
  OmacyFrame frame;
  uint8_t needs_begin_next;
  uint8_t steps_taken;
  uint8_t _pad[2];
} OmacyStepResult;

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

omacy_status omacy_ascii_from_bytes(const OmacyAsciiConfig *cfg,
                                    const uint8_t *bytes,
                                    size_t len,
                                    OmacyText **out);

size_t omacy_effect_catalog_count(void);

omacy_status omacy_effect_catalog_get(size_t index, const uint8_t **out_ptr, size_t *out_len);

omacy_status omacy_session_begin_next_with_config(OmacySession *s,
                                                  const uint8_t *content,
                                                  size_t content_len,
                                                  const OmacyByteSlice *effect_pool,
                                                  size_t effect_pool_count,
                                                  uint32_t cols,
                                                  uint32_t rows);

omacy_status omacy_session_create(const OmacySessionConfig *cfg,
                                  uint32_t cols,
                                  uint32_t rows,
                                  OmacySession **out);

void omacy_session_destroy(OmacySession *s);

omacy_status omacy_session_error_message(const OmacySession *s, char *buf, size_t buf_len);

omacy_status omacy_session_generation(const OmacySession *s, uint64_t *out);

omacy_status omacy_session_step(OmacySession *s, double elapsed_seconds, OmacyStepResult *out);

const char *omacy_status_string(omacy_status status);

void omacy_text_free(OmacyText *t);

size_t omacy_text_len(const OmacyText *t);

const char *omacy_text_utf8(const OmacyText *t);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* OMACY_H */
