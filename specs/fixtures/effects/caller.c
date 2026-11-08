#include "proto.h"

static int check(int fd) { return wait_ready(fd); }
int poll_once(int fd) { return check(fd); }
