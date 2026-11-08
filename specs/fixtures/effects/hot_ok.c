#include <string.h>

#include "cchecker.h"

static int twice(int x) { return x * 2; }
CC_HOT int hot_sum(const int *xs, int n) {
  int total = 0;
  for (int i = 0; i < n; i++) total += twice(xs[i]);
  return total;
}
CC_HOT void hot_copy(char *to, const char *from, size_t n) { memcpy(to, from, n); }
