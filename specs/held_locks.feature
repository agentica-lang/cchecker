Feature: What runs while a lock is held
  A lock whose field (or global) is marked CC_NO_SYSCALL_UNDER() is held for short sections only: no system call and
  no blocking call runs under it, directly or through the functions of the project it calls, except its own release
  and a wait on a condition with it. A function marked CC_NO_SYSCALL_UNDER(lock) says the same of one of its locks.
  CC_LOCK_LEVEL(n) on a field or a global orders the locks: a lock is taken only while every lock held has a lower
  level, directly or in a function it calls.

  Scenario Outline: A system call while a CC_NO_SYSCALL_UNDER lock is held is a finding at the function (<case>)
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; pthread_cond_t cv; int fd; int n; };
      pthread_mutex_t other; void flush(struct queue *q);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-SYSCALL-UNDER-LOCK","tool":"rules","file":"$DIR/push.c","line":8,"column":6,
      """
    And the output includes:
      """
      <end>"]
      """

    Examples:
      | case            | end                         | code                                                                                                                                         |
      | direct          | calls write                 | void push(struct queue *q) { pthread_mutex_lock(&q->mu); write(q->fd, "x", 1); pthread_mutex_unlock(&q->mu); }                              |
      | blocking        | calls usleep                | void push(struct queue *q) { pthread_mutex_lock(&q->mu); usleep(1); pthread_mutex_unlock(&q->mu); }                                         |
      | another lock    | calls pthread_mutex_lock    | void push(struct queue *q) { pthread_mutex_lock(&q->mu); pthread_mutex_lock(&other); pthread_mutex_unlock(&other); pthread_mutex_unlock(&q->mu); } |
      | through a call  | calls flush: flush -> write | void push(struct queue *q) { pthread_mutex_lock(&q->mu); flush(q); pthread_mutex_unlock(&q->mu); } void flush(struct queue *q) { write(q->fd, "x", 1); } |
      | a wait on other | calls pthread_cond_wait     | void push(struct queue *q) { pthread_mutex_lock(&q->mu); pthread_mutex_lock(&other); pthread_cond_wait(&q->cv, &other); pthread_mutex_unlock(&other); pthread_mutex_unlock(&q->mu); } |

  Scenario Outline: What runs under a CC_NO_SYSCALL_UNDER lock passes when it makes no system call (<case>)
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; pthread_cond_t cv; int fd; int n; };
      struct box { pthread_mutex_t mu; int fd; };

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 0

    Examples:
      | case                 | code                                                                                                                                 |
      | after the unlock     | void push(struct queue *q) { pthread_mutex_lock(&q->mu); q->n++; pthread_mutex_unlock(&q->mu); write(q->fd, "x", 1); }               |
      | a wait with the lock | void push(struct queue *q) { pthread_mutex_lock(&q->mu); while (!q->n) pthread_cond_wait(&q->cv, &q->mu); pthread_mutex_unlock(&q->mu); } |
      | a lock not marked    | void put(struct box *b) { pthread_mutex_lock(&b->mu); write(b->fd, "x", 1); pthread_mutex_unlock(&b->mu); }                         |
      | a call that computes | static int count(struct queue *q) { return q->n + 1; } void push(struct queue *q) { pthread_mutex_lock(&q->mu); q->n = count(q); pthread_mutex_unlock(&q->mu); } |

  Scenario: CC_NO_SYSCALL_UNDER(lock) on a function holds for that lock in that function
    Given the C file "put.c" holds:
      """
      #include <pthread.h>
      #include <unistd.h>
      #include "cchecker.h"

      struct box { pthread_mutex_t mu; int fd; };

      CC_NO_SYSCALL_UNDER(b->mu) void put(struct box *b) {
        pthread_mutex_lock(&b->mu);
        write(b->fd, "x", 1);
        pthread_mutex_unlock(&b->mu);
      }

      void other(struct box *b) {
        pthread_mutex_lock(&b->mu);
        write(b->fd, "x", 1);
        pthread_mutex_unlock(&b->mu);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/put.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-SYSCALL-UNDER-LOCK","tool":"rules","file":"$DIR/put.c","line":7,"column":33,
      """
    And the output includes:
      """
      "path":["8:3 takes b->mu","9:3 calls write"]
      """
    And the output does not include:
      """
      "line":13
      """

  Scenario Outline: A lock taken while a lock of the same or a higher level is held is a finding (<case>)
    Given the C file "order.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      typedef struct runtime runtime_t;
      struct queue { CC_LOCK_LEVEL(2) pthread_mutex_t mu; int n; };
      struct runtime { CC_LOCK_LEVEL(1) pthread_mutex_t sync; struct queue *q; };
      CC_ACQUIRES(rt->sync) void rt_lock(runtime_t *rt);
      CC_RELEASES(rt->sync) void rt_unlock(runtime_t *rt);
      void bump(runtime_t *rt) { pthread_mutex_lock(&rt->sync); pthread_mutex_unlock(&rt->sync); }

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/order.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-ORDER","tool":"rules","file":"$DIR/order.c","line":11,"column":6,
      """
    And the output includes:
      """
      <end>"]
      """

    Examples:
      | case            | end                    | code                                                                                                                                        |
      | direct          | takes rt->sync         | void f(runtime_t *rt) { pthread_mutex_lock(&rt->q->mu); pthread_mutex_lock(&rt->sync); pthread_mutex_unlock(&rt->sync); pthread_mutex_unlock(&rt->q->mu); } |
      | same level      | takes b->mu            | void f(struct queue *a, struct queue *b) { pthread_mutex_lock(&a->mu); pthread_mutex_lock(&b->mu); pthread_mutex_unlock(&b->mu); pthread_mutex_unlock(&a->mu); } |
      | through helper  | takes rt->sync         | void f(runtime_t *rt) { pthread_mutex_lock(&rt->q->mu); rt_lock(rt); rt_unlock(rt); pthread_mutex_unlock(&rt->q->mu); }                    |
      | through a call  | calls bump, which takes runtime.sync | void f(runtime_t *rt) { pthread_mutex_lock(&rt->q->mu); bump(rt); pthread_mutex_unlock(&rt->q->mu); }                                     |

  Scenario Outline: Locks taken in the order of their levels pass (<case>)
    Given the C file "order.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      typedef struct runtime runtime_t;
      struct queue { CC_LOCK_LEVEL(2) pthread_mutex_t mu; pthread_mutex_t free_mu; int n; };
      struct runtime { CC_LOCK_LEVEL(1) pthread_mutex_t sync; struct queue *q; };
      CC_ACQUIRES(rt->sync) void rt_lock(runtime_t *rt);
      CC_RELEASES(rt->sync) void rt_unlock(runtime_t *rt);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/order.c -- -I../include"
    Then the exit code is 0

    Examples:
      | case           | code                                                                                                                                        |
      | in order       | void f(runtime_t *rt) { rt_lock(rt); pthread_mutex_lock(&rt->q->mu); pthread_mutex_unlock(&rt->q->mu); rt_unlock(rt); }                   |
      | one after one  | void f(runtime_t *rt) { pthread_mutex_lock(&rt->q->mu); pthread_mutex_unlock(&rt->q->mu); rt_lock(rt); rt_unlock(rt); }                   |
      | no level       | void f(runtime_t *rt) { pthread_mutex_lock(&rt->q->mu); pthread_mutex_lock(&rt->q->free_mu); pthread_mutex_unlock(&rt->q->free_mu); pthread_mutex_unlock(&rt->q->mu); } |

  Scenario: The levels and the marks of a field hold in the other files of the run
    Given the C file "queue.h" holds:
      """
      #include <pthread.h>
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() CC_LOCK_LEVEL(2) pthread_mutex_t mu; int fd; };
      """
    And the C file "user.c" holds:
      """
      #include <unistd.h>
      #include "queue.h"

      void push(struct queue *q) {
        pthread_mutex_lock(&q->mu);
        write(q->fd, "x", 1);
        pthread_mutex_unlock(&q->mu);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/user.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["5:3 takes q->mu","6:3 calls write"]
      """
