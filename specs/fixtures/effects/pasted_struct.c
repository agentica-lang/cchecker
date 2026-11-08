#include "cchecker.h"

unsigned int sleep(unsigned int seconds);

/* The tag of the struct is pasted by the macro. */
#define OPS(prefix) struct prefix##_ops { int (*run)(int); }
OPS(my);

static int slow(int x) { sleep(1); return x; }
static struct my_ops ops = {slow};
CC_SHORT int entry(int x) { return ops.run(x); }
