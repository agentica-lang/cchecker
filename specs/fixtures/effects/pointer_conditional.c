#include "cchecker.h"

unsigned int sleep(unsigned int seconds);
typedef int (*step_fn)(int);

static int quick(int x) { return x + 1; }
static int slow(int x) { sleep(1); return x; }

/* Both branches of a conditional can be stored. */
static step_fn chosen = 1 ? quick : slow;
CC_SHORT int entry(int x) { return chosen(x); }
