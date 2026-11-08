#include <stdlib.h>

void release_twice(void) {
  int *p = malloc(sizeof *p);
  if (p == NULL) {
    return;
  }
  free(p);
  free(p);
}
