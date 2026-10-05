#include <stdint.h>
#include <stddef.h>
typedef struct C8855 C8855;
int c8855_probe(const char *library, char *error, size_t capacity);
C8855 *c8855_open(const char *library, char *error, size_t capacity);
int c8855_start(C8855 *counter, uint8_t gate_code, unsigned timeout_ms);
int c8855_read(C8855 *counter, uint32_t *count);
int c8855_stop(C8855 *counter);
const char *c8855_error(C8855 *counter);
void c8855_close(C8855 *counter);
