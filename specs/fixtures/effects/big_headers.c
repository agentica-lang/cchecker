/* Enough system headers for an AST of more than 1 MiB of JSON. */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "cchecker.h"

static pthread_mutex_t table_lock = PTHREAD_MUTEX_INITIALIZER;

static int locked_count(int *count) {
  pthread_mutex_lock(&table_lock);
  int n = *count;
  pthread_mutex_unlock(&table_lock);
  return n;
}

/* The lock is held across a sleep here, so it is not short and taking it blocks. */
void wait_count(int *count) {
  pthread_mutex_lock(&table_lock);
  sleep((unsigned int)*count);
  pthread_mutex_unlock(&table_lock);
}

CC_SHORT int current_count(int *count) { return locked_count(count); }
