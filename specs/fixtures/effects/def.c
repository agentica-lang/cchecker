#include "cchecker.h"

/* The annotation is on the definition only: decl.c declares the function without it. */
CC_BLOCKING int wait_slow(int fd) { return fd; }
