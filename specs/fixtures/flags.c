#include <stdlib.h>

/* The leak is there only when the build defines LEAK. */
int use_buffer(int n) {
  char *buf = malloc(10);
  if (buf == NULL) {
    return -1;
  }
#ifdef LEAK
  if (n > 3) {
    return 1;
  }
#endif
  free(buf);
  return n;
}
