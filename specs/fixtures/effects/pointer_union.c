#include "cchecker.h"

unsigned int sleep(unsigned int seconds);
typedef int (*step_fn)(int);

static int slow(int x) { sleep(1); return x; }

/* A designated initializer of a union that sets a field other than the first. */
union handler { long code; step_fn run; };
static union handler h = {.run = slow};
CC_SHORT int entry(int x) { return h.run(x); }
