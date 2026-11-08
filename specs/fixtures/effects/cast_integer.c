#include <stdint.h>

#include "cchecker.h"

unsigned int sleep(unsigned int seconds);

static int slow(void) { return (int)sleep(1); }

/* A function kept in an integer of a typedef'd type. */
static uintptr_t address = (uintptr_t)slow;
CC_SHORT int entry(void) { return ((int (*)(void))address)(); }
