#include "cchecker.h"

unsigned int sleep(unsigned int seconds);
typedef int (*step_fn)(int);

static int quick(int x) { return x + 1; }
static int slow(int x) { sleep(1); return x; }

/* An unnamed bit-field takes no item of the initializer. */
struct op { step_fn first; int : 3; step_fn second; };
static struct op o = {quick, slow};
CC_SHORT int entry(int x) { return o.second(x); }
