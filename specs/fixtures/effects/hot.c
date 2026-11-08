#include <stdlib.h>
#include <unistd.h>

#include "cchecker.h"

static void *grow(size_t n) { return malloc(n); }
CC_HOT void *hot_alloc(size_t n) { return grow(n); }
CC_HOT long hot_write(int fd) { return (long)write(fd, "x", 1); }
