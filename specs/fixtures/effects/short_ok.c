#include <string.h>
#include <unistd.h>

#include "cchecker.h"

/* Recursion: the walk of the call graph ends. */
static int odd(int n);
static int even(int n) { return n == 0 ? 1 : odd(n - 1); }
static int odd(int n) { return n == 0 ? 0 : even(n - 1); }

/* Not reached from a CC_SHORT function. */
int slow_path(int fd) { char c; return (int)read(fd, &c, 1); }

CC_SHORT int name_length(const char *name) { return (int)strlen(name) + even(4); }
