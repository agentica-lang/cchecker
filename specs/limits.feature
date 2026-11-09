@slow
Feature: Time and memory on large generated inputs
  Each scenario generates a large C file that reaches a limit of the rules, and runs cchecker under `ulimit -v` with a
  bound on its time: a run that needs more memory fails, and one that takes longer fails the step. The bounds are for
  the CI runner (`make test-slow`); `make test` leaves these scenarios out.

  Scenario: A chain of 1000 else-if branches under a lock stays in its bounds
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
    When I run cchecker with "--tools rules --json $DIR/chain.c" in at most 1500 MiB and 20 seconds
    Then the exit code is 0

  Scenario: A chain of 3000 else-if branches, over the guard of 20 000 nodes, stays in its bounds
    Given the C file "chain.c" holds, with ITEMS as 3000 times " else if (q->n == 7) work(7);":
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
    When I run cchecker with "--tools rules --json $DIR/chain.c" in at most 1500 MiB and 20 seconds
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"rules","file":"$DIR/chain.c",
      """

  Scenario: A condition of 1000 terms joined by || under a lock stays in its bounds
    Given the C file "or.c" holds, with ITEMS as 1000 times " || q->n == 7":
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
    When I run cchecker with "--tools rules --json $DIR/or.c" in at most 1500 MiB and 20 seconds
    Then the exit code is 0

  Scenario: A condition of 3000 terms joined by || under a lock stays in its bounds
    Given the C file "or.c" holds, with ITEMS as 3000 times " || q->n == 7":
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
    When I run cchecker with "--tools rules --json $DIR/or.c" in at most 1500 MiB and 20 seconds
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"rules","file":"$DIR/or.c",
      """

  Scenario: A declaration of 16 million lines of the dump, far over the cap, is skipped in its bounds
    Given the C file "big.c" holds, with ITEMS as 320000 times "GREEN,":
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      enum color { RED, GREEN };
      static const enum color BIG[] = {ITEMS};
      CC_SHORT int entry(int i) { return (int)BIG[i] + (int)sleep(1); }
      """
    When I run cchecker with "--tools rules --json $DIR/big.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 1
    And the output includes:
      """
      "path":["entry","sleep"]
      """
    And the output includes:
      """
      "skipped_declarations":1
      """

  Scenario: A function over the guard of 20 000 nodes is an error of the tool, in its bounds, and the rest is checked
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
    When I run cchecker with "--tools rules --json $DIR/huge.c" in at most 1500 MiB and 20 seconds
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

  Scenario: A function with more paths than the 200 000 states of the walk is counted, in its bounds
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
    When I run cchecker with "--tools rules --json $DIR/many.c" in at most 1500 MiB and 20 seconds
    Then the exit code is 1
    And the output includes:
      """
      "incomplete_functions":[{"file":"$DIR/many.c","line":4,"function":"many"}]
      """

  Scenario Outline: Blocks that declare a pointer of the same name do not multiply the states of the ownership walk (<case>)
    Given the C file "blocks.c" holds, with ITEMS as 24 times " if (pick()) { <block> }":
      """
      #include <stdlib.h>
      #include "cchecker.h"
      CC_OWNS char *make(void);
      int pick(void);
      void emit(char *s);
      void many(void) {ITEMS
      }
      """
    When I run cchecker with "--tools rules --json $DIR/blocks.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

    Examples:
      | case                 | block                                                         |
      | plain                | char *s = make(); emit(s); free(s);                           |
      | alias                | char *s = make(); char *t = s; if (!t) emit(0); else free(t); |
      | statement expression | char *q = ({ CC_OWNS char *t = make(); t; }); free(q);        |

  Scenario: Statement expressions at the top level of a function do not multiply the states of the ownership walk
    Given the C file "top.c" holds, with ITEMS as 24 times " s = TAKE(); if (s) free(s);":
      """
      #include <stdlib.h>
      #include "cchecker.h"
      #define TAKE() ({ CC_OWNS char *t_ = make(); t_; })
      CC_OWNS char *make(void);
      void many(void) {
        char *s;ITEMS
      }
      """
    When I run cchecker with "--tools rules --json $DIR/top.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: A lock held in a function with more paths than the walk follows is not inferred short
    Given the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "many.c", "arguments": ["cc", "-c", "many.c", "-I../../../include"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [library]
      short_lock_sections = true
      """
    And the C file "many.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"
      pthread_mutex_t m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15, m16, m17, m18, m19;
      int pick(int i);
      void many(void) {
        if (pick(0)) pthread_mutex_lock(&m0);
        if (pick(1)) pthread_mutex_lock(&m1);
        if (pick(2)) pthread_mutex_lock(&m2);
        if (pick(3)) pthread_mutex_lock(&m3);
        if (pick(4)) pthread_mutex_lock(&m4);
        if (pick(5)) pthread_mutex_lock(&m5);
        if (pick(6)) pthread_mutex_lock(&m6);
        if (pick(7)) pthread_mutex_lock(&m7);
        if (pick(8)) pthread_mutex_lock(&m8);
        if (pick(9)) pthread_mutex_lock(&m9);
        if (pick(10)) pthread_mutex_lock(&m10);
        if (pick(11)) pthread_mutex_lock(&m11);
        if (pick(12)) pthread_mutex_lock(&m12);
        if (pick(13)) pthread_mutex_lock(&m13);
        if (pick(14)) pthread_mutex_lock(&m14);
        if (pick(15)) pthread_mutex_lock(&m15);
        if (pick(16)) pthread_mutex_lock(&m16);
        if (pick(17)) pthread_mutex_lock(&m17);
        if (pick(18)) pthread_mutex_lock(&m18);
        if (pick(19)) pthread_mutex_lock(&m19);
        if (pick(19)) pthread_mutex_unlock(&m19);
        if (pick(18)) pthread_mutex_unlock(&m18);
        if (pick(17)) pthread_mutex_unlock(&m17);
        if (pick(16)) pthread_mutex_unlock(&m16);
        if (pick(15)) pthread_mutex_unlock(&m15);
        if (pick(14)) pthread_mutex_unlock(&m14);
        if (pick(13)) pthread_mutex_unlock(&m13);
        if (pick(12)) pthread_mutex_unlock(&m12);
        if (pick(11)) pthread_mutex_unlock(&m11);
        if (pick(10)) pthread_mutex_unlock(&m10);
        if (pick(9)) pthread_mutex_unlock(&m9);
        if (pick(8)) pthread_mutex_unlock(&m8);
        if (pick(7)) pthread_mutex_unlock(&m7);
        if (pick(6)) pthread_mutex_unlock(&m6);
        if (pick(5)) pthread_mutex_unlock(&m5);
        if (pick(4)) pthread_mutex_unlock(&m4);
        if (pick(3)) pthread_mutex_unlock(&m3);
        if (pick(2)) pthread_mutex_unlock(&m2);
        if (pick(1)) pthread_mutex_unlock(&m1);
        if (pick(0)) pthread_mutex_unlock(&m0);
      }
      CC_SHORT void tick(void) { pthread_mutex_lock(&m0); pthread_mutex_unlock(&m0); }
      """
    When I run cchecker in its folder with "--tools rules --json" in at most 1500 MiB and 20 seconds
    Then the exit code is 1
    And the output includes:
      """
      "CC-EFFECT-SHORT-BLOCKS"
      """
    And the output includes:
      """
      "inferred_short_locks":[]
      """
