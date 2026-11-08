#include "cchecker.h"

unsigned int sleep(unsigned int seconds);

/* The name of the function is pasted by the macro: clang spells it in its scratch space. */
#define DEFINE_WAIT(name) static int wait_##name(void) { return (int)sleep(1); }
DEFINE_WAIT(ready)

CC_SHORT int entry(void) { return wait_ready(); }
