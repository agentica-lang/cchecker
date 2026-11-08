#include "cchecker.h"
#include "shared.h"

static int helper(int x) { return x + 1; }
CC_SHORT int a_entry(int x) { return helper(x); }
