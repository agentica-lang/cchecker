#include "cchecker.h"

int wait_slow(int fd);
CC_SHORT int ask(int fd) { return wait_slow(fd); }
