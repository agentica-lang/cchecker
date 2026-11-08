#include "cchecker.h"

unsigned int sleep(unsigned int seconds);

static int slow(void) { return (int)sleep(1); }

/* An array of `void *` that holds functions. */
static void *table[] = {(void *)slow};
CC_SHORT int entry(int i) { return ((int (*)(void))table[i])(); }
