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

  Scenario: A trylock kept in a variable and a flag set to a constant, 24 times in a loop, stay in their bounds
    Each kept result is a fact until its test, and each constant until the flag is tested after the loop: a path holds
    the lock only between a take and its unlock, so the states do not multiply with the uses.

    Given the C file "tries.c" holds, with ITEMS as 24 times " r = pthread_mutex_trylock(&q->mu); if (r == 0) { work(1); pthread_mutex_unlock(&q->mu); done = 1; }":
      """
      #include <pthread.h>
      struct queue { pthread_mutex_t mu; int n; };
      int work(int n);
      int pop(struct queue *q) {
        int r;
        int done = 0;
        for (int i = 0; i < q->n; i++) {ITEMS
        }
        if (done) work(2);
        return 0;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/tries.c" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: 20 flags set to constants and tested after a lock, with no lock in their branches, stay in their bounds
    A constant written to a flag is a fact only when a test of the flag guards a lock call or a way out, so these
    flags are not followed and the walk does not keep a state for each choice of them.

    Given the C file "flags.c" holds:
      """
      #include <pthread.h>
      int c(int);
      void w(int);
      void f(pthread_mutex_t *m) {
        int f0 = 0, f1 = 0, f2 = 0, f3 = 0, f4 = 0, f5 = 0, f6 = 0, f7 = 0, f8 = 0, f9 = 0, f10 = 0, f11 = 0, f12 = 0, f13 = 0, f14 = 0, f15 = 0, f16 = 0, f17 = 0, f18 = 0, f19 = 0;
        if (c(0)) f0 = 1; if (c(1)) f1 = 1; if (c(2)) f2 = 1; if (c(3)) f3 = 1; if (c(4)) f4 = 1;
        if (c(5)) f5 = 1; if (c(6)) f6 = 1; if (c(7)) f7 = 1; if (c(8)) f8 = 1; if (c(9)) f9 = 1;
        if (c(10)) f10 = 1; if (c(11)) f11 = 1; if (c(12)) f12 = 1; if (c(13)) f13 = 1; if (c(14)) f14 = 1;
        if (c(15)) f15 = 1; if (c(16)) f16 = 1; if (c(17)) f17 = 1; if (c(18)) f18 = 1; if (c(19)) f19 = 1;
        pthread_mutex_lock(m);
        if (f0) w(0); if (f1) w(1); if (f2) w(2); if (f3) w(3); if (f4) w(4);
        if (f5) w(5); if (f6) w(6); if (f7) w(7); if (f8) w(8); if (f9) w(9);
        if (f10) w(10); if (f11) w(11); if (f12) w(12); if (f13) w(13); if (f14) w(14);
        if (f15) w(15); if (f16) w(16); if (f17) w(17); if (f18) w(18); if (f19) w(19);
        pthread_mutex_unlock(m);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/flags.c" in at most 1500 MiB and 5 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: A function walked again without its conditions is counted, in its bounds
    18 flags each tested twice under the lock take more than the 200 000 states with their values: the walk without
    them finds the same, and the function is listed, as its paths were not all told apart. The walk that stops at
    200 000 states, each with the values of 18 flags, needs more memory than the other scenarios.

    Given the C file "twice.c" holds:
      """
      #include <pthread.h>
      int c(int);
      void w(int);
      void f(pthread_mutex_t *m) {
        int f0 = c(0), f1 = c(1), f2 = c(2), f3 = c(3), f4 = c(4), f5 = c(5), f6 = c(6), f7 = c(7), f8 = c(8), f9 = c(9), f10 = c(10), f11 = c(11), f12 = c(12), f13 = c(13), f14 = c(14), f15 = c(15), f16 = c(16), f17 = c(17);
        pthread_mutex_lock(m);
        if (f0) w(0); if (f1) w(1); if (f2) w(2); if (f3) w(3); if (f4) w(4); if (f5) w(5);
        if (f6) w(6); if (f7) w(7); if (f8) w(8); if (f9) w(9); if (f10) w(10); if (f11) w(11);
        if (f12) w(12); if (f13) w(13); if (f14) w(14); if (f15) w(15); if (f16) w(16); if (f17) w(17);
        if (f0) w(0); if (f1) w(1); if (f2) w(2); if (f3) w(3); if (f4) w(4); if (f5) w(5);
        if (f6) w(6); if (f7) w(7); if (f8) w(8); if (f9) w(9); if (f10) w(10); if (f11) w(11);
        if (f12) w(12); if (f13) w(13); if (f14) w(14); if (f15) w(15); if (f16) w(16); if (f17) w(17);
        pthread_mutex_unlock(m);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/twice.c" in at most 2500 MiB and 40 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[{"file":"$DIR/twice.c","line":4,"function":"f"}]
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

  Scenario: A statement-expression macro used 24 times into one variable stays in its bounds
    Each use leaves the pointer of the macro, which the variable stood for, freed on one side of the test and null on
    the other: once the variable gets the next value nothing names it, and it leaves the state.

    Given the C file "macro.c" holds, with ITEMS as 24 times " s = TAKE(); if (s) free(s);":
      """
      #include <stdlib.h>
      #include "cchecker.h"
      CC_OWNS char *make(void);
      #define TAKE() ({ CC_OWNS char *t_ = make(); t_; })
      void many(void) {
        char *s;ITEMS
      }
      """
    When I run cchecker with "--tools rules --json $DIR/macro.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: A local struct of eight CC_OWNS fields set under conditions stays in its bounds
    Given the C file "fields.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"
      CC_OWNS char *make(void);
      int pick(void);
      struct many { CC_OWNS char *f0; CC_OWNS char *f1; CC_OWNS char *f2; CC_OWNS char *f3; CC_OWNS char *f4; CC_OWNS char *f5; CC_OWNS char *f6; CC_OWNS char *f7; };
      void fill(void) {
        struct many m = {0};
        if (pick()) m.f0 = make();
        if (pick()) m.f1 = make();
        if (pick()) m.f2 = make();
        if (pick()) m.f3 = make();
        if (pick()) m.f4 = make();
        if (pick()) m.f5 = make();
        if (pick()) m.f6 = make();
        if (pick()) m.f7 = make();
        free(m.f0);
        free(m.f1);
        free(m.f2);
        free(m.f3);
        free(m.f4);
        free(m.f5);
        free(m.f6);
        free(m.f7);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/fields.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: Local structs that escape in 24 blocks of a loop stay in their bounds
    A struct escapes on one side of each test and frees its field on the other: at the end of its block both leave
    the state, so the blocks do not multiply the states.

    Given the C file "escapes.c" holds, with ITEMS as 24 times " { struct pair p = {0}; p.left = make(); if (pick()) keep(&p); else free(p.left); }":
      """
      #include <stdlib.h>
      #include "cchecker.h"
      struct pair { CC_OWNS char *left; CC_OWNS char *right; };
      CC_OWNS char *make(void);
      int pick(void);
      void keep(struct pair *p);
      void many(int n) {
        for (int i = 0; i < n; i++) {ITEMS
        }
      }
      """
    When I run cchecker with "--tools rules --json $DIR/escapes.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: Fields set from a local in 24 blocks of a loop stay in their bounds
    The field stands for the local: on one side of each test the struct escapes and takes the local along, on the other
    a free of the field frees the local. At the end of its block both leave the state.

    Given the C file "aliases.c" holds, with ITEMS as 24 times " { CC_OWNS char *b = make(); struct pair p = { .left = b }; if (pick()) keep(&p); else free(p.left); }":
      """
      #include <stdlib.h>
      #include "cchecker.h"
      struct pair { CC_OWNS char *left; CC_OWNS char *right; };
      CC_OWNS char *make(void);
      int pick(void);
      void keep(struct pair *p);
      void many(int n) {
        for (int i = 0; i < n; i++) {ITEMS
        }
      }
      """
    When I run cchecker with "--tools rules --json $DIR/aliases.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: Local structs cleared, freed and cleaned up in 24 blocks of a loop stay in their bounds
    Given the C file "clears.c" holds, with ITEMS as 24 times " { struct pair p __attribute__((cleanup(pair_done))); memset(&p, 0, sizeof p); p.left = make(); if (pick()) zap(&p.left); else { free(p.left); p = (struct pair){0}; } }":
      """
      #include <stdlib.h>
      #include <string.h>
      #include "cchecker.h"
      struct pair { CC_OWNS char *left; CC_OWNS char *right; };
      CC_OWNS char *make(void);
      int pick(void);
      void zap(CC_FREES char **p);
      void pair_done(struct pair *p);
      void many(int n) {
        for (int i = 0; i < n; i++) {ITEMS
        }
      }
      """
    When I run cchecker with "--tools rules --json $DIR/clears.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: Nested structs of 16 CC_OWNS fields, the bound, in 24 blocks of a loop stay in their bounds
    The struct has three levels: a member escapes on one side of each test and a nested field is freed on the other.
    At the end of its block every field leaves the state.

    Given the C file "nested.c" holds, with ITEMS as 24 times " { struct top p = {0}; p.x.a.f0 = make(); p.y.b.f3 = make(); if (pick()) keep(&p.x); else free(p.x.a.f0); free(p.y.b.f3); memset(&p.y, 0, sizeof p.y); }":
      """
      #include <stdlib.h>
      #include <string.h>
      #include "cchecker.h"
      struct leaf { CC_OWNS char *f0; CC_OWNS char *f1; CC_OWNS char *f2; CC_OWNS char *f3; };
      struct mid { struct leaf a; struct leaf b; };
      struct top { struct mid x; struct mid y; };
      CC_OWNS char *make(void);
      int pick(void);
      void keep(struct mid *p);
      void many(int n) {
        for (int i = 0; i < n; i++) {ITEMS
        }
      }
      """
    When I run cchecker with "--tools rules --json $DIR/nested.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: A struct of 512 nested CC_OWNS fields, over the bound, is not followed and stays in its bounds
    Each test lends one struct in it of one of two variables, so a followed struct would keep a state for each choice
    of every test. Over the bound of 16 fields the struct is not followed.

    Given the C file "wide.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"
      struct leaf { CC_OWNS char *f0; CC_OWNS char *f1; CC_OWNS char *f2; CC_OWNS char *f3; CC_OWNS char *f4; CC_OWNS char *f5; CC_OWNS char *f6; CC_OWNS char *f7; };
      struct mid { struct leaf l0; struct leaf l1; struct leaf l2; struct leaf l3; struct leaf l4; struct leaf l5; struct leaf l6; struct leaf l7; };
      struct top { struct mid m0; struct mid m1; struct mid m2; struct mid m3; struct mid m4; struct mid m5; struct mid m6; struct mid m7; };
      CC_OWNS char *make(void);
      int pick(void);
      void keep(struct mid *m);
      void many(int n) {
        struct top p = {0}, q = {0};
        for (int i = 0; i < n; i++) {
          if (pick()) keep(&p.m0); else keep(&q.m0);
          if (pick()) keep(&p.m1); else keep(&q.m1);
          if (pick()) keep(&p.m2); else keep(&q.m2);
          if (pick()) keep(&p.m3); else keep(&q.m3);
          if (pick()) keep(&p.m4); else keep(&q.m4);
          if (pick()) keep(&p.m5); else keep(&q.m5);
          if (pick()) keep(&p.m6); else keep(&q.m6);
          if (pick()) keep(&p.m7); else keep(&q.m7);
        }
      }
      """
    When I run cchecker with "--tools rules --json $DIR/wide.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: Arrays of structs of 16 CC_OWNS fields, the bound, in 24 blocks of a loop stay in their bounds
    Each item of the array is a struct of its own: one is passed by value on one side of each test and its field is
    freed on the other, and the array is cleared at the end. At the end of its block every field leaves the state.

    Given the C file "items.c" holds, with ITEMS as 24 times " { struct pair a[8] = {0}; a[0].left = make(); a[7].right = make(); if (pick()) lend(a[0]); else free(a[0].left); free(a[7].right); memset(a, 0, sizeof a); }":
      """
      #include <stdlib.h>
      #include <string.h>
      #include "cchecker.h"
      struct pair { CC_OWNS char *left; CC_OWNS char *right; };
      CC_OWNS char *make(void);
      int pick(void);
      void lend(struct pair p);
      void many(int n) {
        for (int i = 0; i < n; i++) {ITEMS
        }
      }
      """
    When I run cchecker with "--tools rules --json $DIR/items.c -- -I../include" in at most 1500 MiB and 20 seconds
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
      """

  Scenario: Arrays of structs over the bound of 16 CC_OWNS fields are not followed and stay in their bounds
    Each test lends one pointer of an item of one of two arrays, so a followed array would keep a state for each
    choice of every test. Over the bound of 16 fields (9 items of 2) the arrays are not followed.

    Given the C file "wide.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"
      struct pair { CC_OWNS char *left; CC_OWNS char *right; };
      void keep(char **m);
      int pick(void);
      void many(int n) {
        struct pair p[9] = {0}, q[9] = {0};
        for (int i = 0; i < n; i++) {
          if (pick()) keep(&p[0].left); else keep(&q[0].left);
          if (pick()) keep(&p[1].right); else keep(&q[1].right);
          if (pick()) keep(&p[2].left); else keep(&q[2].left);
          if (pick()) keep(&p[3].right); else keep(&q[3].right);
          if (pick()) keep(&p[4].left); else keep(&q[4].left);
          if (pick()) keep(&p[5].right); else keep(&q[5].right);
          if (pick()) keep(&p[6].left); else keep(&q[6].left);
          if (pick()) keep(&p[7].right); else keep(&q[7].right);
        }
      }
      """
    When I run cchecker with "--tools rules --json $DIR/wide.c -- -I../include" in at most 1500 MiB and 20 seconds
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
