#include "cchecker.h"

unsigned int sleep(unsigned int seconds);

static void release(int *p) { (void)p; sleep(1); }

/* The cleanup attribute calls `release` when `k` goes out of scope. */
CC_SHORT int entry(int x) {
  int k __attribute__((cleanup(release))) = x;
  return k;
}
