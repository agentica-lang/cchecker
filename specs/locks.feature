Feature: Locks on every path
  The rules tool builds a control flow graph of each function that takes or drops a lock, and follows every path: a
  lock the function takes is released on every path that returns, and a lock it releases is one it holds. A lock is
  the expression the call names (`&q->mu` is `q->mu`). A path that ends in a call that does not return holds what it
  holds. A function that takes a lock for its caller says so with CC_ACQUIRES, and one that drops it with
  CC_RELEASES. The finding is at the function, and `path` is the path that breaks the rule.

  Scenario Outline: A path that leaves a lock held is a finding at the function (<case>)
    Given the C file "pop.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "stdlib.h"
      #include "cchecker.h"

      struct queue { pthread_mutex_t mu; pthread_cond_t cv; int n; };
      int work(struct queue *q);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/pop.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-NOT-RELEASED","tool":"rules","file":"$DIR/pop.c","line":8,"column":<column>,
      """

    Examples:
      | case          | column | code                                                                                                                                                                                                    |
      | early return  | 5      | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); if (q->n == 0) return -1; pthread_mutex_unlock(&q->mu); return 0; }                                                                             |
      | end of a void | 6      | void push(struct queue *q) { pthread_mutex_lock(&q->mu); q->n++; }                                                                                                                                      |
      | goto          | 5      | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); if (work(q)) goto fail; pthread_mutex_unlock(&q->mu); return 0; fail: return -1; }                                                               |
      | break         | 5      | int pop(struct queue *q) { for (;;) { pthread_mutex_lock(&q->mu); if (work(q)) break; pthread_mutex_unlock(&q->mu); } return 0; }                                                                       |
      | continue      | 5      | int pop(struct queue *q) { for (int i = 0; i < q->n; i++) { pthread_mutex_lock(&q->mu); if (work(q)) continue; pthread_mutex_unlock(&q->mu); } return 0; }                                             |
      | switch case   | 5      | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); switch (q->n) { case 0: pthread_mutex_unlock(&q->mu); case 1: q->n++; break; default: pthread_mutex_unlock(&q->mu); } return 0; }               |
      | fallthrough   | 5      | int pop(struct queue *q) { switch (q->n) { case 0: pthread_mutex_lock(&q->mu); /* fall through */ case 1: q->n++; break; } return 0; }                                                                 |
      | no default    | 5      | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); switch (q->n) { case 0: pthread_mutex_unlock(&q->mu); return 0; } return 1; }                                                                    |
      | condition     | 5      | int pop(struct queue *q, int locked) { if (locked) pthread_mutex_lock(&q->mu); if (q->n) pthread_mutex_unlock(&q->mu); return 0; }                                                                      |
      | changed flag  | 5      | int pop(struct queue *q, int locked) { if (locked) pthread_mutex_lock(&q->mu); locked = work(q); if (locked) pthread_mutex_unlock(&q->mu); return 0; }                                                  |
      | ternary       | 5      | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); return q->n ? (pthread_mutex_unlock(&q->mu), 1) : 0; }                                                                                           |
      | statement expression | 5 | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); int n = ({ int k = q->n; if (k == 0) return -1; k; }); pthread_mutex_unlock(&q->mu); return n; }                                              |
      | computed goto | 5      | int pop(struct queue *q) { void *next = &&out; pthread_mutex_lock(&q->mu); goto *next; pthread_mutex_unlock(&q->mu); out: return 0; }                                                                   |
      | elvis         | 5      | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); return q->n ?: (pthread_mutex_unlock(&q->mu), 0); }                                                                                              |
      | flag by address | 23   | int flip(int *x); int pop(struct queue *q, int locked) { if (locked) pthread_mutex_lock(&q->mu); flip(&locked); if (locked) pthread_mutex_unlock(&q->mu); return 0; }                                  |
      | nested break  | 5      | int pop(struct queue *q) { for (;;) { for (int i = 0; i < q->n; i++) { pthread_mutex_lock(&q->mu); if (work(q)) break; pthread_mutex_unlock(&q->mu); } return 0; } }                                      |
      | freed by address | 34  | void zap(CC_FREES char **p); int pop(struct queue *q) { CC_OWNS char *b = malloc(8); if (b) pthread_mutex_lock(&q->mu); zap(&b); if (b) pthread_mutex_unlock(&q->mu); return 0; } |

  Scenario Outline: A lock released on every path passes (<case>)
    Given the C file "pop.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "stdlib.h"
      #include "cchecker.h"

      struct queue { pthread_mutex_t mu; pthread_cond_t cv; int n; };
      int work(struct queue *q);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/pop.c -- -I../include"
    Then the exit code is 0

    Examples:
      | case              | code                                                                                                                                                                                                                       |
      | if and else       | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); int n = q->n; if (n == 0) { pthread_mutex_unlock(&q->mu); return -1; } else { q->n--; } pthread_mutex_unlock(&q->mu); return n; }                                   |
      | goto fail         | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); if (work(q)) goto fail; pthread_mutex_unlock(&q->mu); return 0; fail: pthread_mutex_unlock(&q->mu); return -1; }                                                   |
      | break, continue   | int pop(struct queue *q) { for (int i = 0; i < q->n; i++) { pthread_mutex_lock(&q->mu); if (work(q)) { pthread_mutex_unlock(&q->mu); continue; } if (i > 3) { pthread_mutex_unlock(&q->mu); break; } pthread_mutex_unlock(&q->mu); } return 0; } |
      | fallthrough       | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); switch (q->n) { case 0: q->n++; /* fall through */ case 1: pthread_mutex_unlock(&q->mu); break; default: pthread_mutex_unlock(&q->mu); } return 0; }               |
      | while and do      | int pop(struct queue *q) { do { pthread_mutex_lock(&q->mu); q->n--; pthread_mutex_unlock(&q->mu); } while (work(q)); while (q->n) { pthread_mutex_lock(&q->mu); pthread_mutex_unlock(&q->mu); } return 0; }               |
      | abort             | void check(struct queue *q) { pthread_mutex_lock(&q->mu); if (q->n >= 0) { pthread_mutex_unlock(&q->mu); return; } abort(); }                                                                                              |
      | __builtin_abort   | void check(struct queue *q) { pthread_mutex_lock(&q->mu); if (q->n >= 0) { pthread_mutex_unlock(&q->mu); return; } __builtin_abort(); }                                                                                    |
      | _Noreturn         | _Noreturn void die(struct queue *q); void check(struct queue *q) { pthread_mutex_lock(&q->mu); if (q->n >= 0) { pthread_mutex_unlock(&q->mu); return; } die(q); }                                                          |
      | CC_NORETURN       | CC_NORETURN void fail(struct queue *q); void check(struct queue *q) { pthread_mutex_lock(&q->mu); if (q->n >= 0) { pthread_mutex_unlock(&q->mu); return; } fail(q); }                                                      |
      | cleanup           | CC_RELEASES(*m) static void drop(pthread_mutex_t **m) { pthread_mutex_unlock(*m); } int pop(struct queue *q) { pthread_mutex_t *held __attribute__((cleanup(drop))) = &q->mu; pthread_mutex_lock(held); if (q->n == 0) return -1; return 0; } |
      | same condition    | int pop(struct queue *q, int locked) { if (locked) pthread_mutex_lock(&q->mu); work(q); if (!locked) return 1; pthread_mutex_unlock(&q->mu); return 0; }                                                                  |
      | trylock           | int pop(struct queue *q) { if (pthread_mutex_trylock(&q->mu) != 0) return -1; q->n--; pthread_mutex_unlock(&q->mu); return 0; }                                                                                            |
      | checked lock      | int pop(struct queue *q) { if (pthread_mutex_lock(&q->mu)) return -1; q->n--; pthread_mutex_unlock(&q->mu); return 0; }                                                                                                    |
      | condition wait    | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); while (q->n == 0) pthread_cond_wait(&q->cv, &q->mu); q->n--; pthread_mutex_unlock(&q->mu); return 0; }                                                             |
      | drop and retake   | int pop(struct queue *q) { pthread_mutex_unlock(&q->mu); work(q); pthread_mutex_lock(&q->mu); return 0; }                                                                                                                  |
      | local alias       | int pop(struct queue *q) { pthread_mutex_t *m = &q->mu; pthread_mutex_lock(m); q->n--; pthread_mutex_unlock(&q->mu); return 0; }                                                                                           |
      | ternary           | int pop(struct queue *q) { pthread_mutex_lock(&q->mu); return q->n ? (pthread_mutex_unlock(&q->mu), 1) : (pthread_mutex_unlock(&q->mu), 0); }                                                                              |
      | and               | int pop(struct queue *q) { if (q->n > 0 && pthread_mutex_trylock(&q->mu) == 0) { q->n--; pthread_mutex_unlock(&q->mu); } return 0; }                                                                                       |
      | or                | int pop(struct queue *q) { if (q->n == 0 \|\| pthread_mutex_trylock(&q->mu) != 0) return -1; q->n--; pthread_mutex_unlock(&q->mu); return 0; }                                                                            |
      | do while 0        | int pop(struct queue *q) { do { pthread_mutex_lock(&q->mu); } while (0); q->n--; pthread_mutex_unlock(&q->mu); return 0; }                                                                                                 |
      | struct by value   | CC_RELEASES(q->mu) void leave(struct queue *q); struct queue box; int pop(void) { pthread_mutex_lock(&box.mu); box.n--; leave(&box); return 0; }                                                                           |
      | field by address  | int pop(struct queue *q) { if (q->n) pthread_mutex_lock(&q->mu); work(q); if (q->n) pthread_mutex_unlock(&q->mu); return 0; }                                                                                               |
      | noreturn typedef  | typedef void fatal_fn(void) __attribute__((noreturn)); fatal_fn die; void check(struct queue *q) { pthread_mutex_lock(&q->mu); if (q->n >= 0) { pthread_mutex_unlock(&q->mu); return; } die(); }        |
      | noreturn pointer  | struct stopper { void (*stop)(void) __attribute__((noreturn)); }; void check(struct queue *q, struct stopper *s) { pthread_mutex_lock(&q->mu); if (q->n >= 0) { pthread_mutex_unlock(&q->mu); return; } s->stop(); } |
      | nested break      | int pop(struct queue *q) { for (;;) { pthread_mutex_lock(&q->mu); for (int i = 0; i < q->n; i++) { if (work(q)) break; } pthread_mutex_unlock(&q->mu); if (q->n) break; } return 0; }                          |
      | nested continue   | int pop(struct queue *q) { for (int j = 0; j < 2; j++) { pthread_mutex_lock(&q->mu); for (int i = 0; i < q->n; i++) { if (work(q)) continue; q->n--; } pthread_mutex_unlock(&q->mu); } return 0; }             |
      | switch in a loop  | int pop(struct queue *q) { for (int i = 0; i < q->n; i++) { pthread_mutex_lock(&q->mu); switch (work(q)) { case 0: break; default: pthread_mutex_unlock(&q->mu); continue; } pthread_mutex_unlock(&q->mu); } return 0; } |

  Scenario: The path of a finding goes from the lock to the return that leaves it held
    Given the C file "pop.c" holds:
      """
      #include <pthread.h>

      struct queue { pthread_mutex_t mu; int n; };

      int pop(struct queue *q) {
        pthread_mutex_lock(&q->mu);
        if (q->n == 0)
          return -1;
        q->n--;
        pthread_mutex_unlock(&q->mu);
        return 0;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/pop.c"
    Then the exit code is 1
    And the output includes:
      """
      "path":["6:3 takes q->mu","7:7 true","8:5 returns"]
      """

  Scenario: The path starts at the last take of a lock left held, and at the last release of a lock not held
    Given the C file "twice.c" holds:
      """
      #include <pthread.h>
      struct queue { pthread_mutex_t mu; int n; };
      int pop(struct queue *q) {
        pthread_mutex_lock(&q->mu);
        pthread_mutex_lock(&q->mu);
        pthread_mutex_unlock(&q->mu);
        return 0;
      }
      int push(struct queue *q) {
        pthread_mutex_unlock(&q->mu);
        pthread_mutex_unlock(&q->mu);
        pthread_mutex_lock(&q->mu);
        return 0;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/twice.c"
    Then the exit code is 1
    And the output includes:
      """
      "path":["5:3 takes q->mu","6:3 releases q->mu","7:3 returns"]
      """
    And the output includes:
      """
      "path":["11:3 releases q->mu","12:3 takes q->mu","13:3 returns"]
      """

  Scenario: Long chains of else-if and of || take little memory
    Given the C file "chain.c" holds, with ITEMS as 1000 times " else if (q->n == 7) work(7);":
      """
      #include <pthread.h>
      struct queue { pthread_mutex_t mu; int n; };
      int work(int n);
      int pop(struct queue *q) {
        pthread_mutex_lock(&q->mu);
        if (q->n == 0) work(0);ITEMS
        pthread_mutex_unlock(&q->mu);
        return 0;
      }
      """
    And the C file "or.c" holds, with ITEMS as 1000 times " || q->n == 7":
      """
      #include <pthread.h>
      struct queue { pthread_mutex_t mu; int n; };
      int pop(struct queue *q) {
        pthread_mutex_lock(&q->mu);
        int r = q->n == 0ITEMS;
        pthread_mutex_unlock(&q->mu);
        return r;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/chain.c $DIR/or.c" in at most 1500 MiB
    Then the exit code is 0

  Scenario: A function too large for the path rules is an error of the tool, and the rest of the run is checked
    Given the C file "huge.c" holds, with ITEMS as 6000 times " work(7);":
      """
      #include <pthread.h>
      struct queue { pthread_mutex_t mu; int n; };
      int work(int n);
      int pop(struct queue *q) {
        pthread_mutex_lock(&q->mu);
       ITEMS
        return 0;
      }
      int push(struct queue *q) {
        pthread_mutex_lock(&q->mu);
        return 0;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/huge.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"rules","file":"$DIR/huge.c",
      """
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-NOT-RELEASED","tool":"rules","file":"$DIR/huge.c","line":9,"column":5,
      """
    And the output does not include:
      """
      "line":4,
      """

  Scenario: A function with more paths than the walk follows is counted, and the run says so
    Given the C file "many.c" holds:
      """
      #include <pthread.h>
      pthread_mutex_t m[20];
      int pick(int i);
      void many(void) {
        if (pick(0)) pthread_mutex_lock(&m[0]);
        if (pick(1)) pthread_mutex_lock(&m[1]);
        if (pick(2)) pthread_mutex_lock(&m[2]);
        if (pick(3)) pthread_mutex_lock(&m[3]);
        if (pick(4)) pthread_mutex_lock(&m[4]);
        if (pick(5)) pthread_mutex_lock(&m[5]);
        if (pick(6)) pthread_mutex_lock(&m[6]);
        if (pick(7)) pthread_mutex_lock(&m[7]);
        if (pick(8)) pthread_mutex_lock(&m[8]);
        if (pick(9)) pthread_mutex_lock(&m[9]);
        if (pick(10)) pthread_mutex_lock(&m[10]);
        if (pick(11)) pthread_mutex_lock(&m[11]);
        if (pick(12)) pthread_mutex_lock(&m[12]);
        if (pick(13)) pthread_mutex_lock(&m[13]);
        if (pick(14)) pthread_mutex_lock(&m[14]);
        if (pick(15)) pthread_mutex_lock(&m[15]);
        if (pick(16)) pthread_mutex_lock(&m[16]);
        if (pick(17)) pthread_mutex_lock(&m[17]);
        if (pick(18)) pthread_mutex_lock(&m[18]);
        if (pick(19)) pthread_mutex_lock(&m[19]);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/many.c"
    Then the exit code is 1
    And the output includes:
      """
      "incomplete_functions":1
      """

  Scenario: A lock released by a function that did not take it is a finding, and so is another lock left held
    Given the C file "swap.c" holds:
      """
      #include <pthread.h>

      struct queue { pthread_mutex_t mu; int n; };

      void swap(struct queue *a, struct queue *b) {
        pthread_mutex_lock(&a->mu);
        pthread_mutex_unlock(&b->mu);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/swap.c"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-NOT-HELD","tool":"rules","file":"$DIR/swap.c","line":5,"column":6,
      """
    And the output includes:
      """
      "path":["7:3 releases b->mu","8:1 ends"]
      """
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-NOT-RELEASED","tool":"rules","file":"$DIR/swap.c","line":5,"column":6,
      """

  Scenario: Helpers that take and drop a lock for their caller are findings without CC_ACQUIRES and CC_RELEASES
    Given the C file "queue.c" holds:
      """
      #include <pthread.h>

      struct queue { pthread_mutex_t mu; int n; };

      void queue_lock(struct queue *q) { pthread_mutex_lock(&q->mu); }
      void queue_unlock(struct queue *q) { pthread_mutex_unlock(&q->mu); }
      """
    When I run cchecker with "--tools rules --json $DIR/queue.c"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-NOT-RELEASED","tool":"rules","file":"$DIR/queue.c","line":5,"column":6,
      """
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-NOT-HELD","tool":"rules","file":"$DIR/queue.c","line":6,"column":6,
      """

  Scenario: CC_ACQUIRES and CC_RELEASES on the prototypes carry the lock to the callers in other files
    Given the C file "queue.h" holds:
      """
      #include <pthread.h>
      #include "cchecker.h"

      struct queue { pthread_mutex_t mu; int n; };
      struct vm { struct queue *q; };

      CC_ACQUIRES(q->mu) void queue_lock(struct queue *q);
      CC_RELEASES(&q->mu) void queue_unlock(struct queue *q);
      CC_ACQUIRES(vm->q->mu) void vm_lock(struct vm *vm);
      CC_RELEASES(vm->q->mu) void vm_unlock(struct vm *vm);
      """
    And the C file "queue.c" holds:
      """
      #include "queue.h"

      void queue_lock(struct queue *q) { pthread_mutex_lock(&q->mu); }
      void queue_unlock(struct queue *q) { pthread_mutex_unlock(&q->mu); }
      void vm_lock(struct vm *vm) { queue_lock(vm->q); }
      void vm_unlock(struct vm *vm) { queue_unlock(vm->q); }
      """
    And the C file "user.c" holds:
      """
      #include "queue.h"

      int take(struct vm *vm) {
        vm_lock(vm);
        int n = vm->q->n;
        queue_unlock(vm->q);
        return n;
      }

      int leave(struct vm *vm) {
        queue_lock(vm->q);
        if (vm->q->n == 0)
          return 0;
        vm_unlock(vm);
        return 1;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/queue.c $DIR/user.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-LOCK-NOT-RELEASED","tool":"rules","file":"$DIR/user.c","line":10,"column":5,
      """
    And the output includes:
      """
      "path":["11:3 takes vm->q->mu","12:7 true","13:5 returns"]
      """
    And the output does not include:
      """
      "line":3,"column":5
      """
    And the output does not include:
      """
      "file":"$DIR/queue.c"
      """

  Scenario: An annotation of a prototype counts once for a caller after the definition, whatever the names of its parameters there
    Given the C file "pop.c" holds:
      """
      #include <pthread.h>
      #include "cchecker.h"

      struct queue { pthread_mutex_t mu; int n; };

      CC_RELEASES(q->mu) static void leave(struct queue *q);

      static void leave(struct queue *queue) { pthread_mutex_unlock(&queue->mu); }

      int pop(struct queue *q) {
        pthread_mutex_lock(&q->mu);
        q->n--;
        leave(q);
        return 0;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/pop.c -- -I../include"
    Then the exit code is 0

  Scenario: CC_IGNORE suppresses a finding of a path
    Given the C file "push.c" holds:
      """
      #include <pthread.h>
      #include "cchecker.h"

      struct queue { pthread_mutex_t mu; int n; };

      CC_IGNORE("CC-PATH-LOCK-NOT-RELEASED", "the caller drops it") void push(struct queue *q) {
        pthread_mutex_lock(&q->mu);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/push.c -- -I../include"
    Then the exit code is 0
    And the output includes:
      """
      "reason":"the caller drops it"
      """

  Scenario: The findings of paths go into the baseline, and a run of the whole database counts them fixed
    Given the C file "push.c" holds:
      """
      #include <pthread.h>

      struct queue { pthread_mutex_t mu; int n; };

      void push(struct queue *q) { pthread_mutex_lock(&q->mu); q->n++; }
      """
    And the C file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "push.c", "arguments": ["cc", "-c", "push.c"]}]
      """
    When I run cchecker with "--tools rules -b $DIR/base.json --update-baseline -p $DIR"
    Then the exit code is 0
    When I run cchecker with "--tools rules -b $DIR/base.json --json -p $DIR"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":1,"fixed":0
      """
    Given the C file "push.c" holds:
      """
      #include <pthread.h>

      struct queue { pthread_mutex_t mu; int n; };

      void push(struct queue *q) { pthread_mutex_lock(&q->mu); q->n++; pthread_mutex_unlock(&q->mu); }
      """
    When I run cchecker with "--tools rules -b $DIR/base.json --json -p $DIR"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":0,"fixed":1
      """
