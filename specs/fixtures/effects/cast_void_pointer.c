#include "cchecker.h"

unsigned int sleep(unsigned int seconds);

static int slow(void) { return (int)sleep(1); }

/* A function kept in a `void *` and called through a cast back. */
static void *stored = (void *)slow;
CC_SHORT int entry(void) { return ((int (*)(void))stored)(); }
