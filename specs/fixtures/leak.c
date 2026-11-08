#include <stdlib.h>

int use_buffer(int n) {
  char *buf = malloc(10);
  if (buf == NULL) {
    return -1;
  }
  if (n > 3) {
    return 1;
  }
  free(buf);
  return 0;
}
