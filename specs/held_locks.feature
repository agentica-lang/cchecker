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
      pthread_mutex_t other; void flush(struct queue *q); void wait_disk(struct queue *q);

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
      | a blocking function | calls wait_disk         | void push(struct queue *q) { pthread_mutex_lock(&q->mu); wait_disk(q); pthread_mutex_unlock(&q->mu); } CC_BLOCKING void wait_disk(struct queue *q) { q->n++; } |
      | a wait on other | calls pthread_cond_wait     | void push(struct queue *q) { pthread_mutex_lock(&q->mu); pthread_mutex_lock(&other); pthread_cond_wait(&q->cv, &other); pthread_mutex_unlock(&other); pthread_mutex_unlock(&q->mu); } |

  Scenario Outline: A function that never returns or is cold is followed under a CC_NO_SYSCALL_UNDER lock (<case>)
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; int fd; int n; };
      <attribute> void fail(struct queue *q) { write(q->fd, "x", 1); <end> }
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); if (q->n == -1) fail(q); q->n++; pthread_mutex_unlock(&q->mu); }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "code":"CC-PATH-SYSCALL-UNDER-LOCK"
      """
    And the output includes:
      """
      calls fail: fail -> write"]
      """

    Examples:
      | case     | attribute             | end         |
      | cold     | __attribute__((cold)) |             |
      | noreturn | _Noreturn             | for (;;) {} |

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

  Scenario Outline: A CC_RELEASES helper is held to the system calls it makes before its release (<case>)
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; pthread_cond_t cv; int fd; int n; }; pthread_mutex_t other;
      CC_RELEASES(q->mu) void unlock_queue(struct queue *q) { <body> }
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); q->n++; unlock_queue(q); }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is <exit>
    And the output <includes>:
      """
      "path":["7:30 takes q->mu","7:66 calls unlock_queue: unlock_queue -> <call>"]
      """

    Examples:
      | case                         | body                                                                                         | exit | includes         | call                 |
      | the release alone            | q->n--; pthread_mutex_unlock(&q->mu);                                                        | 0    | does not include | pthread_mutex_unlock |
      | a signal after the unlock    | pthread_mutex_unlock(&q->mu); pthread_cond_signal(&q->cv);                                   | 0    | does not include | pthread_cond_signal  |
      | a write after the unlock     | pthread_mutex_unlock(&q->mu); write(q->fd, "x", 1);                                          | 0    | does not include | write                |
      | a wait, then the unlock      | while (!q->n) pthread_cond_wait(&q->cv, &q->mu); pthread_mutex_unlock(&q->mu); write(q->fd, "x", 1); | 0 | does not include | write          |
      | an unlock through an alias   | pthread_mutex_t *m = &q->mu; pthread_mutex_unlock(m);                                        | 0    | does not include | pthread_mutex_unlock |
      | a write after a wait         | pthread_cond_wait(&q->cv, &q->mu); write(q->fd, "x", 1); pthread_mutex_unlock(&q->mu);       | 1    | includes         | write                |
      | a write before the unlock    | write(q->fd, "x", 1); pthread_mutex_unlock(&q->mu);                                          | 1    | includes         | write                |
      | a signal before the unlock   | pthread_cond_signal(&q->cv); pthread_mutex_unlock(&q->mu);                                   | 1    | includes         | pthread_cond_signal  |
      | a write on one branch        | if (q->n) write(q->fd, "x", 1); pthread_mutex_unlock(&q->mu);                                | 1    | includes         | write                |
      | another lock's unlock first  | pthread_mutex_unlock(&other); write(q->fd, "x", 1); pthread_mutex_unlock(&q->mu);            | 1    | includes         | write                |

  Scenario Outline: A CC_RELEASES helper that releases a lock taken under a CC_NO_SYSCALL_UNDER lock is held to all its system calls (<case>)
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; int n; }; pthread_mutex_t other;
      CC_RELEASES(m) void drop(pthread_mutex_t *m) { <body> }
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); pthread_mutex_lock(&other); q->n++; drop(&other); pthread_mutex_unlock(&q->mu); }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["7:30 takes q->mu","7:58 calls pthread_mutex_lock"]
      """
    And the output <includes>:
      """
      calls drop: drop -> write"]
      """

    Examples:
      | case                     | body                                         | includes         |
      | the release alone        | pthread_mutex_unlock(m);                     | does not include |
      | a write after the unlock | pthread_mutex_unlock(m); write(1, "x", 1);   | includes         |

  Scenario: The cleanup of a variable of a statement expression runs at the end of the statement expression
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; int fd; int n; };
      CC_RELEASES(*m) static void drop(pthread_mutex_t **m) { pthread_mutex_unlock(*m); }

      void after(struct queue *q) {
        int n = ({ pthread_mutex_t *held __attribute__((cleanup(drop))) = &q->mu; pthread_mutex_lock(held); q->n; });
        write(q->fd, "x", 1);
        q->n = n;
      }

      void inside(struct queue *q) {
        int n = ({ pthread_mutex_t *held __attribute__((cleanup(drop))) = &q->mu; pthread_mutex_lock(held); write(q->fd, "x", 1); q->n; });
        q->n = n;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "line":14,"column":6,"message":"inside calls write while holding q->mu","path":["15:77 takes q->mu","15:103 calls write"]
      """
    And the output does not include:
      """
      "line":8,
      """

  Scenario: A lock taken under a CC_NO_SYSCALL_UNDER lock is one finding of the rule, and its release none
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() CC_LOCK_LEVEL(2) pthread_mutex_t mu; int n; };
      CC_LOCK_LEVEL(1) pthread_mutex_t other;

      void push(struct queue *q) {
        pthread_mutex_lock(&q->mu);
        pthread_mutex_lock(&other);
        q->n++;
        pthread_mutex_unlock(&other);
        pthread_mutex_unlock(&q->mu);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["8:3 takes q->mu","9:3 calls pthread_mutex_lock"]
      """
    And the output includes:
      """
      "code":"CC-PATH-LOCK-ORDER"
      """
    And the output does not include:
      """
      calls pthread_mutex_unlock
      """

  Scenario: The release of a lock taken by a trylock under a CC_NO_SYSCALL_UNDER lock is a finding, as its take is none
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; int n; }; pthread_mutex_t other;
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); if (pthread_mutex_trylock(&other) == 0) { q->n++; pthread_mutex_unlock(&other); } pthread_mutex_unlock(&q->mu); }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      calls pthread_mutex_unlock"]
      """
    And the output does not include:
      """
      calls pthread_mutex_trylock
      """

  Scenario: The [library] flags do not turn off a blocking call under a CC_NO_SYSCALL_UNDER lock: it is a system call
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; int n; };

      void push(struct queue *q) { pthread_mutex_lock(&q->mu); usleep(1); pthread_mutex_unlock(&q->mu); }
      """
    And the file "cchecker.toml" holds:
      """
      [library]
      libc_blocking = false
      pthread_blocking = false
      """
    When I run cchecker in its folder with "--tools rules --json push.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-SYSCALL-UNDER-LOCK","tool":"rules","file":"push.c","line":7,"column":6,
      """
    And the output includes:
      """
      "config":"cchecker.toml"
      """

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
      void nested(runtime_t *rt) { rt_lock(rt); rt_unlock(rt); }

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/order.c -- -I../include"
    Then the exit code is 0

    Examples:
      | case           | code                                                                                                                                        |
      | in order       | void f(runtime_t *rt) { rt_lock(rt); pthread_mutex_lock(&rt->q->mu); pthread_mutex_unlock(&rt->q->mu); rt_unlock(rt); }                   |
      | one after one  | void f(runtime_t *rt) { pthread_mutex_lock(&rt->q->mu); pthread_mutex_unlock(&rt->q->mu); rt_lock(rt); rt_unlock(rt); }                   |
      | a nested take  | void f(runtime_t *rt) { rt_lock(rt); nested(rt); rt_unlock(rt); }                                                                         |
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

  Scenario: A call through a function pointer under a lock reaches the functions stored in the pointer
    Given the C file "cb.c" holds:
      """
      #include <pthread.h>
      #include <unistd.h>
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() CC_LOCK_LEVEL(2) pthread_mutex_t mu; void (*cb)(struct queue *q); int fd; };
      struct runtime { CC_LOCK_LEVEL(1) pthread_mutex_t sync; };
      struct runtime rt;
      static void flush(struct queue *q) { write(q->fd, "x", 1); }
      static void sync_up(struct queue *q) { (void)q; pthread_mutex_lock(&rt.sync); pthread_mutex_unlock(&rt.sync); }
      void setup(struct queue *q) { q->cb = flush; }
      void push(struct queue *q) {
        pthread_mutex_lock(&q->mu);
        q->cb(q);
        pthread_mutex_unlock(&q->mu);
      }
      void each(struct queue *q, void (*f)(struct queue *)) {
        pthread_mutex_lock(&q->mu);
        f(q);
        pthread_mutex_unlock(&q->mu);
      }
      void run(struct queue *q) { each(q, sync_up); }
      """
    When I run cchecker with "--tools rules --json $DIR/cb.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-SYSCALL-UNDER-LOCK","tool":"rules","file":"$DIR/cb.c","line":11,"column":6,
      """
    And the output includes:
      """
      "13:3 calls q->cb: flush -> write"]
      """
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-ORDER","tool":"rules","file":"$DIR/cb.c","line":16,"column":6,
      """
    And the output includes:
      """
      "18:3 calls f, which takes runtime.sync"]
      """

  Scenario Outline: A call under a lock through a pointer that holds two functions reaches both (<case>)
    Given the C file "cb.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; void (*cb)(struct queue *q); int fd; };
      static void count(struct queue *q) { q->fd++; }
      static void flush(struct queue *q) { write(q->fd, "x", 1); }
      void quiet(struct queue *q) { q->cb = count; }
      <setup>
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); q->cb(q); pthread_mutex_unlock(&q->mu); }
      """
    When I run cchecker with "--tools rules --json $DIR/cb.c -- -I../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      "10:58 calls q->cb: flush -> write"]
      """

    Examples:
      | case            | setup                                          | exit | found            |
      | both stored     | void loud(struct queue *q) { q->cb = flush; }  | 1    | includes         |
      | one stored      | void loud(struct queue *q) { (void)q; }        | 0    | does not include |

  Scenario Outline: A lock of a helper is classed through the qualifiers of its parameter (<case>)
    Given the C file "order.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      struct queue { CC_LOCK_LEVEL(2) pthread_mutex_t mu; };
      struct runtime { CC_LOCK_LEVEL(1) pthread_mutex_t sync; };
      CC_ACQUIRES(r->sync) void rt_lock(struct runtime *<qualifier> r);
      CC_RELEASES(r->sync) void rt_unlock(struct runtime *<qualifier> r);
      void f(struct runtime *rt, struct queue *q) { pthread_mutex_lock(&q->mu); rt_lock(rt); rt_unlock(rt); pthread_mutex_unlock(&q->mu); }
      """
    When I run cchecker with "--tools rules --json $DIR/order.c -- -I../include -Wno-nullability-completeness"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-ORDER","tool":"rules","file":"$DIR/order.c","line":8,"column":6,
      """

    Examples:
      | case          | qualifier    |
      | none          | const        |
      | _Atomic       | _Atomic      |
      | __restrict__  | __restrict__ |
      | _Nonnull      | _Nonnull     |

  Scenario: Locks are classed through arrays, const pointers and their own declarations, and a trylock waits for none
    Given the C file "classes.c" holds:
      """
      #include <pthread.h>
      #include "cchecker.h"

      struct pool { CC_LOCK_LEVEL(1) pthread_mutex_t m[4]; };
      struct queue { CC_LOCK_LEVEL(2) pthread_mutex_t mu; };
      CC_ACQUIRES(p->m[0]) void pool_lock(struct pool *const p);
      CC_RELEASES(p->m[0]) void pool_unlock(struct pool *const p);
      CC_LOCK_LEVEL(1) pthread_mutex_t gate;
      void array(struct queue *q, struct pool *p) {
        pthread_mutex_lock(&q->mu); pthread_mutex_lock(&p->m[1]); pthread_mutex_unlock(&p->m[1]); pthread_mutex_unlock(&q->mu);
      }
      void constant(struct queue *q, struct pool *p) {
        pthread_mutex_lock(&q->mu); pool_lock(p); pool_unlock(p); pthread_mutex_unlock(&q->mu);
      }
      void shadow(struct queue *q, pthread_mutex_t *gate) {
        pthread_mutex_lock(&q->mu); pthread_mutex_lock(gate); pthread_mutex_unlock(gate); pthread_mutex_unlock(&q->mu);
      }
      void attempt(struct queue *q, struct pool *p) {
        pthread_mutex_lock(&q->mu);
        if (pthread_mutex_trylock(&p->m[2]) == 0) pthread_mutex_unlock(&p->m[2]);
        pthread_mutex_unlock(&q->mu);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/classes.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-ORDER","tool":"rules","file":"$DIR/classes.c","line":9,"column":6,
      """
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-ORDER","tool":"rules","file":"$DIR/classes.c","line":12,"column":6,
      """
    And the output does not include:
      """
      "line":15,
      """
    And the output does not include:
      """
      "line":18,
      """

  Scenario: A lock mark that cannot be read in a header is one error, of the header
    Given the C file "box.h" holds:
      """
      #include <pthread.h>
      #include "cchecker.h"
      struct box { CC_LOCK_LEVEL(0x2) pthread_mutex_t mu; };
      """
    And the C file "a.c" holds:
      """
      #include "box.h"
      void a(struct box *b) { (void)b; }
      """
    And the C file "b.c" holds:
      """
      #include "box.h"
      void b(struct box *b) { (void)b; }
      """
    When I run cchecker with "--tools rules --json $DIR/a.c $DIR/b.c -- -I../include"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"rules","file":"$DIR/box.h","message":"box.mu: CC_LOCK_LEVEL takes a decimal number: lock_level(0x2)"}]
      """

  Scenario: A static lock is its own file's
    Given the C file "q.h" holds:
      """
      #include <pthread.h>
      #include "cchecker.h"
      struct queue { CC_LOCK_LEVEL(2) pthread_mutex_t mu; };
      """
    And the C file "a.c" holds:
      """
      #include "q.h"
      static CC_LOCK_LEVEL(1) pthread_mutex_t lk;
      void a(struct queue *q) { pthread_mutex_lock(&q->mu); pthread_mutex_lock(&lk); pthread_mutex_unlock(&lk); pthread_mutex_unlock(&q->mu); }
      """
    And the C file "b.c" holds:
      """
      #include "q.h"
      static pthread_mutex_t lk;
      void b(struct queue *q) { pthread_mutex_lock(&q->mu); pthread_mutex_lock(&lk); pthread_mutex_unlock(&lk); pthread_mutex_unlock(&q->mu); }
      """
    When I run cchecker with "--tools rules --json $DIR/a.c $DIR/b.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-ORDER","tool":"rules","file":"$DIR/a.c","line":3,"column":6,
      """
    And the output does not include:
      """
      "file":"$DIR/b.c"
      """

  Scenario Outline: A lock mark that cannot be read is an error of the tool (<case>)
    Given the C file "marks.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      <code>
      void touch(void) { }
      """
    When I run cchecker with "--tools rules --json $DIR/marks.c -- -I../include"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"rules","file":"$DIR/marks.c",
      """
    And the output includes:
      """
      <message>
      """

    Examples:
      | case                    | code                                                         | message                                                  |
      | a level not a number    | struct box { CC_LOCK_LEVEL(0x2) pthread_mutex_t mu; };       | box.mu: CC_LOCK_LEVEL takes a decimal number             |
      | a lock named on a field | struct box { CC_NO_SYSCALL_UNDER(mu) pthread_mutex_t mu; };  | box.mu: CC_NO_SYSCALL_UNDER() on a lock names no lock    |
      | a field with no class   | struct { CC_LOCK_LEVEL(1) pthread_mutex_t mu; } box;         | a lock mark needs a field of a named struct or a global  |

  Scenario: A CC_RELEASES helper whose prototype names its parameters apart from its definition stops at its unlock
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; pthread_cond_t cv; int n; };
      CC_RELEASES(queue->mu) void unlock_and_wake(struct queue *queue);
      void unlock_and_wake(struct queue *q) { pthread_mutex_unlock(&q->mu); pthread_cond_signal(&q->cv); }
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); q->n++; unlock_and_wake(q); }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 0

  Scenario: A CC_RELEASES helper of two locks is held to its system calls up to the release of the quiet one
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; int fd; int n; }; struct box { pthread_mutex_t mu; };
      CC_RELEASES(a->mu, b->mu) void unlock_both(struct queue *a, struct box *b) { pthread_mutex_unlock(&b->mu); write(a->fd, "x", 1); pthread_mutex_unlock(&a->mu); }
      void push(struct queue *q, struct box *x) { pthread_mutex_lock(&x->mu); pthread_mutex_lock(&q->mu); q->n++; unlock_both(q, x); }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      calls unlock_both: unlock_both -> write"]
      """

  Scenario: The restore of a CC_PAIR whose set ran under a CC_NO_SYSCALL_UNDER lock is held to its system calls
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "signal.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; int n; };
      CC_PAIR(mask_signals, restore_signals) void mask_signals(void); void restore_signals(void);
      void mask_signals(void) { sigprocmask(SIG_BLOCK, 0, 0); } void restore_signals(void) { sigprocmask(SIG_SETMASK, 0, 0); }
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); mask_signals(); q->n++; restore_signals(); pthread_mutex_unlock(&q->mu); }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      calls restore_signals: restore_signals -> sigprocmask"]
      """

  Scenario: A call of a CC_RELEASES helper that cannot name one of its locks stops the walk at any of them
    Given the C file "push.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; int fd; int n; }; struct box { pthread_mutex_t mu; };
      struct box *box_of(struct queue *q);
      CC_RELEASES(a->mu, b->mu) void unlock_both(struct queue *a, struct box *b) { pthread_mutex_unlock(&b->mu); write(a->fd, "x", 1); pthread_mutex_unlock(&a->mu); }
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); q->n++; unlock_both(q, box_of(q)); }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the output does not include:
      """
      calls unlock_both
      """
