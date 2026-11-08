#include "proto.h"

/* Blocking by its annotation, whatever its body does. */
int wait_ready(int fd) { return fd; }
