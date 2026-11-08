#include "cchecker.h"

unsigned int sleep(unsigned int seconds);
typedef int (*step_fn)(int);

static int slow(int x) { sleep(1); return x; }

/* A field in an anonymous union of a struct. */
struct op { int tag; union { long code; step_fn run; }; };
static struct op o = {1, {.run = slow}};
CC_SHORT int entry(int x) { return o.run(x); }
