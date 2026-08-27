#ifndef OMACY_H
#define OMACY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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

#define OMACY_CELL_HAS_BACKGROUND 1
#define OMACY_CELL_HAS_GLYPH 2

typedef struct {
  uint32_t glyph;
  uint8_t fg_r, fg_g, fg_b, fg_a;
  uint8_t bg_r, bg_g, bg_b, bg_a;
  uint8_t flags;
  uint8_t occupancy;
  uint8_t _pad[2];
} OmacyCell;

typedef struct {
  uint32_t cols;
  uint32_t rows;
  uint8_t clear_r, clear_g, clear_b, clear_a;
  uint32_t _pad;
  const OmacyCell *cells;
} OmacyFrame;

typedef struct {
  OmacyFrame frame;
  uint8_t needs_begin_next;
  uint8_t _pad[3];
} OmacyStepResult;

typedef struct {
  const uint8_t *config_dir;
  size_t config_dir_len;
  const uint8_t *ascii;
  size_t ascii_len;
  const uint8_t *effect;
  size_t effect_len;
  uint8_t bg_r, bg_g, bg_b, bg_a;
  uint8_t has_seed;
  uint8_t _pad[3];
  uint64_t seed;
} OmacySessionConfig;

typedef struct {
  const uint8_t *ascii;
  size_t ascii_len;
  const uint8_t *effect;
  size_t effect_len;
  uint8_t bg_r, bg_g, bg_b, bg_a;
  uint8_t _pad[3];
} OmacyPendingConfig;

#define OMACY_ASCII_BRAILLE 0u
#define OMACY_ASCII_BLOCK 1u

typedef struct {
  uint32_t mode;
  uint32_t width;
  uint32_t height;
  uint8_t threshold;
  uint8_t invert;
  uint8_t trim;
  uint8_t _pad;
} OmacyAsciiConfig;

typedef struct OmacySession OmacySession;
typedef struct OmacyText OmacyText;

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
void omacy_session_destroy(OmacySession *s);
const char *omacy_status_string(omacy_status status);

omacy_status omacy_ascii_from_bytes(const OmacyAsciiConfig *cfg,
                                    const uint8_t *bytes, size_t len,
                                    OmacyText **out);
void omacy_text_free(OmacyText *t);
const char *omacy_text_utf8(const OmacyText *t);
size_t omacy_text_len(const OmacyText *t);

#ifdef __cplusplus
}
#endif

#endif
