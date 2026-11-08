#include "cchecker.h"

/* A static function of the same name as one in static_b.c, which blocks: they are not the same function. */
static int helper(int x) { return x + 1; }
CC_SHORT int a_entry(int x) { return helper(x); }
