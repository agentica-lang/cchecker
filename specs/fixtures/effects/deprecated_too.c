#include "cchecker.h"

unsigned int sleep(unsigned int seconds);

/* The project's own deprecated attribute next to an annotation is no annotation. */
__attribute__((deprecated("old"))) static int slow(void) { return (int)sleep(1); }
__attribute__((deprecated("use entry2"))) CC_SHORT int entry(void) { return slow(); }
