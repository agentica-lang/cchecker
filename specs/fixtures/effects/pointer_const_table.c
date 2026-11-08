#include "cchecker.h"

unsigned int sleep(unsigned int seconds);

static int slow(int x) { sleep(1); return x; }

/* A const array of pointers: the type of an item is `int (*const)(int)`, and the item is copied. */
static int (*const table[])(int) = {slow};
CC_SHORT int entry(int i) {
  int (*h)(int) = table[i];
  return h(i);
}
