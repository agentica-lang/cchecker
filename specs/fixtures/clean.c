#include <stdlib.h>

int *make_counter(void) {
  int *p = calloc(1, sizeof *p);
  return p;
}

void drop_counter(int *p) { free(p); }
