#include <stdlib.h>

static inline int take(int n) {
  char *p = malloc(10);
  if (n > 3) {
    return 1;
  }
  free(p);
  return 0;
}
