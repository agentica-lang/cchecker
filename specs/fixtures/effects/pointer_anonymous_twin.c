#include "cchecker.h"

unsigned int sleep(unsigned int seconds);
typedef int (*step_fn)(int);

static int quick(int x) { return x + 1; }
static int slow(int x) { sleep(1); return x; }

/* Two anonymous unions with a field of the same name are fields of two structs, not one. */
struct slow_op { int tag; union { long code; step_fn run; }; };
struct quick_op { int tag; union { long code; step_fn run; }; };
static struct slow_op s = {1, {.run = slow}};
static struct quick_op q = {1, {.run = quick}};
int use_slow(int x) { return s.run(x); }
CC_SHORT int entry(int x) { return q.run(x); }
