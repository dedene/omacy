#include "omacy.h"

/* The declaration published before header generation became automated. */
extern const char *omacy_status_string(omacy_status status);

static const char *(*const previous_status_string)(omacy_status) = omacy_status_string;

int main(void) {
  return previous_status_string(OMACY_OK) == NULL;
}
