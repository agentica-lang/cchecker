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
