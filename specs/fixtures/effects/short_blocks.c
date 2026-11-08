#include <unistd.h>

#include "cchecker.h"

static int fill(int fd, char *buf) { return (int)read(fd, buf, 1); }
static int helper(int fd) { char c; return fill(fd, &c); }
CC_SHORT int next_id(int fd) { return helper(fd) + 1; }
