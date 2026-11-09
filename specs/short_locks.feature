Feature: Short locks inferred from their critical sections
  A lock that no call made while it is held reaches a blocking call is held for a few instructions: taking it is not
  blocking for CC_SHORT, as for a lock marked CC_NO_SYSCALL_UNDER() or named in `[assume] short_locks`. Only a full run
  of a compile database infers one. `--json` lists the classes it found in `inferred_short_locks`, and `[library]
  short_lock_sections = false` turns it off.

  Background:
    Given the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "sections.c", "arguments": ["cc", "-c", "sections.c", "-I../../../include"]}]
      """

  Scenario Outline: A lock whose sections never block is short (<case>)
    Given the C file "sections.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h" /* found in the system folders */
      #include "cchecker.h"

      struct loop { pthread_mutex_t mutex; int n; };
      struct other { pthread_mutex_t mu; } o;
      pthread_cond_t ready;
      static void slow(struct loop *l) { l->n = sleep(1); }
      void move_events(struct loop *l) { l->n = 0; }
      <more>
      void push(struct loop *l) { pthread_mutex_lock(&l->mutex); <under> pthread_mutex_unlock(&l->mutex); }
      CC_SHORT void tick(struct loop *l) { pthread_mutex_lock(&l->mutex); move_events(l); pthread_mutex_unlock(&l->mutex); }
      """
    And the file "cchecker.toml" holds:
      """
      [library]
      <setting>
      """
    When I run cchecker in its folder with "--tools rules --json"
    Then the exit code is <exit>
    And the output <found>:
      """
      "CC-EFFECT-SHORT-BLOCKS"
      """
    And the output includes:
      """
      "inferred_short_locks":<inferred>
      """

    Examples:
      | case                               | more                                                                                                                                                                                                                                                                                                                        | under                                                                    | setting                     | exit | found            | inferred                  |
      | short sections                     |                                                                                                                                                                                                                                                                                                                             | l->n++;                                                                  |                             | 0    | does not include | ["loop.mutex"]            |
      | a sleep under it                   |                                                                                                                                                                                                                                                                                                                             | l->n = sleep(1);                                                         |                             | 1    | includes         | []                        |
      | a sleep it reaches                 |                                                                                                                                                                                                                                                                                                                             | slow(l);                                                                 |                             | 1    | includes         | []                        |
      | turned off                         |                                                                                                                                                                                                                                                                                                                             | l->n++;                                                                  | short_lock_sections = false | 1    | includes         | []                        |
      | a short lock under it              |                                                                                                                                                                                                                                                                                                                             | pthread_mutex_lock(&o.mu); pthread_mutex_unlock(&o.mu);                  |                             | 0    | does not include | ["loop.mutex","other.mu"] |
      | a long lock under it               | void wait_other(void) { pthread_mutex_lock(&o.mu); (void)sleep(1); pthread_mutex_unlock(&o.mu); }                                                                                                                                                                                                                           | pthread_mutex_lock(&o.mu); pthread_mutex_unlock(&o.mu);                  |                             | 1    | includes         | []                        |
      | a trylock of a long one            | void wait_other(void) { pthread_mutex_lock(&o.mu); (void)sleep(1); pthread_mutex_unlock(&o.mu); }                                                                                                                                                                                                                           | if (pthread_mutex_trylock(&o.mu) == 0) pthread_mutex_unlock(&o.mu);      |                             | 0    | does not include | ["loop.mutex"]            |
      | a timedlock of a long one          | void wait_other(void) { pthread_mutex_lock(&o.mu); (void)sleep(1); pthread_mutex_unlock(&o.mu); }                                                                                                                                                                                                                           | if (pthread_mutex_timedlock(&o.mu, 0) == 0) pthread_mutex_unlock(&o.mu); |                             | 1    | includes         | []                        |
      | a wait on a condition              |                                                                                                                                                                                                                                                                                                                             | pthread_cond_wait(&ready, &l->mutex);                                    |                             | 1    | includes         | []                        |
      | a helper that sleeps               | CC_ACQUIRES(l->mutex) void lock_slow(struct loop *l) { pthread_mutex_lock(&l->mutex); slow(l); }                                                                                                                                                                                                                            | l->n++;                                                                  |                             | 1    | includes         | []                        |
      | held across a return               | void lock_it(struct loop *l) { pthread_mutex_lock(&l->mutex); } void unlock_it(struct loop *l) { pthread_mutex_unlock(&l->mutex); } void wait_it(struct loop *l) { lock_it(l); slow(l); unlock_it(l); }                                                                                                                     | l->n++;                                                                  |                             | 1    | includes         | []                        |
      | held at a jump                     | CC_MAY_JUMP int check(int n); void jump_held(struct loop *l) { pthread_mutex_lock(&l->mutex); l->n = check(l->n); pthread_mutex_unlock(&l->mutex); }                                                                                                                                                                        | l->n++;                                                                  |                             | 1    | includes         | []                        |
      | a lock through a param             | void with(pthread_mutex_t *m) { pthread_mutex_lock(m); (void)sleep(1); pthread_mutex_unlock(m); }                                                                                                                                                                                                                           | l->n++;                                                                  |                             | 1    | includes         | []                        |
      | a lock through a field             | struct conn { pthread_mutex_t *lk; }; void wait_conn(struct conn *c) { pthread_mutex_lock(c->lk); (void)sleep(1); pthread_mutex_unlock(c->lk); }                                                                                                                                                                            | l->n++;                                                                  |                             | 1    | includes         | []                        |
      | a lock through a global            | pthread_mutex_t *shared; void wait_shared(void) { pthread_mutex_lock(shared); (void)sleep(1); pthread_mutex_unlock(shared); }                                                                                                                                                                                               | l->n++;                                                                  |                             | 1    | includes         | []                        |
      | a pointer with no target           | void (*hook)(void);                                                                                                                                                                                                                                                                                                         | hook();                                                                  |                             | 1    | includes         | []                        |
      | a pointer to a short one           | static void quick(void) {} void (*hook)(void) = quick;                                                                                                                                                                                                                                                                      | hook();                                                                  |                             | 0    | does not include | ["loop.mutex"]            |
      | a lock through a global helper     | pthread_mutex_t real_mu; pthread_mutex_t *shared = &real_mu; CC_ACQUIRES(shared) void lock_shared(void); CC_RELEASES(shared) void unlock_shared(void); void wait_shared_h(void) { lock_shared(); (void)sleep(1); unlock_shared(); }                                                                                         | l->n++;                                                                  |                             | 1    | includes         | []                        |
      | an annotation with a pointer field | struct conn { pthread_mutex_t *lk; }; CC_ACQUIRES(c->lk) void lock_conn(struct conn *c); CC_RELEASES(c->lk) void unlock_conn(struct conn *c); void wait_conn_h(struct conn *c) { lock_conn(c); (void)sleep(1); unlock_conn(c); }                                                                                            | l->n++;                                                                  |                             | 1    | includes         | []                        |
      | a helper that leaves another lock  | CC_ACQUIRES(p->mu) void lock_both(struct other *p, struct loop *l) { pthread_mutex_lock(&p->mu); pthread_mutex_lock(&l->mutex); } void wait_both(struct loop *l) { lock_both(&o, l); slow(l); pthread_mutex_unlock(&o.mu); }                                                                                                | l->n++;                                                                  |                             | 1    | includes         | []                        |
      | an ignored lock left held          | CC_IGNORE("CC-PATH-LOCK-NOT-RELEASED", "the caller unlocks") void lock_it(struct loop *l) { pthread_mutex_lock(&l->mutex); } CC_IGNORE("CC-PATH-LOCK-NOT-HELD", "the caller locks") void unlock_it(struct loop *l) { pthread_mutex_unlock(&l->mutex); } void wait_it(struct loop *l) { lock_it(l); slow(l); unlock_it(l); } | l->n++;                                                                  |                             | 1    | includes         | []                        |

  Scenario: A run of some files infers no short lock, and says so
    Given the C file "sections.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      struct loop { pthread_mutex_t mutex; int n; };
      CC_SHORT void tick(struct loop *l) { pthread_mutex_lock(&l->mutex); l->n++; pthread_mutex_unlock(&l->mutex); }
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 0
    And the errors include:
      """
      cchecker: 1 lock found short by its critical sections (first: loop.mutex); --json lists them
      """
    When I run cchecker in its folder with "--tools rules --json sections.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      "inferred_short_locks":[]
      """
    And the errors include:
      """
      cchecker: no lock was found short by its critical sections: only a full run of a compile database sees them all
      """

  Scenario: The inference turned off leaves --update-baseline and --strict-baseline as they are
    Given the C file "sections.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      struct loop { pthread_mutex_t mutex; int n; };
      CC_SHORT void tick(struct loop *l) { pthread_mutex_lock(&l->mutex); l->n++; pthread_mutex_unlock(&l->mutex); }
      """
    And the file "cchecker.toml" holds:
      """
      [library]
      short_lock_sections = false
      """
    When I run cchecker in its folder with "--tools rules --baseline base.json --update-baseline"
    Then the exit code is 0
    And the file "$DIR/base.json" includes:
      """
      CC-EFFECT-SHORT-BLOCKS
      """
    Given the C file "sections.c" holds:
      """
      struct loop { int n; };
      void tick(struct loop *l) { l->n++; }
      """
    When I run cchecker in its folder with "--tools rules --baseline base.json --strict-baseline"
    Then the exit code is 1
