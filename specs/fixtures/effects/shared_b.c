#include "shared.h"

unsigned int sleep(unsigned int seconds);

static int helper(int x) { sleep(1); return x; }
int b_entry(int x) { return helper(x); }
