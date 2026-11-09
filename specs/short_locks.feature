Feature: Short locks inferred from their critical sections
  A lock that no call made while it is held reaches a blocking call is held for a few instructions: taking it is not
  blocking for CC_SHORT, as for a lock marked CC_NO_SYSCALL_UNDER() or named in `[assume] short_locks`. The inference is
  experimental and off unless `[library] short_lock_sections = true`. Only a full run of a compile database infers.
  `--json` lists the classes it found in `inferred_short_locks`.

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
    And the output <listed>:
      """
      "inferred_short_locks":<inferred>
      """

    Examples:
      | case                                    | more                                                                                                                                                                                                                                                                                                                        | under                                                                    | setting                     | exit | found            | listed           | inferred                  |
      | short sections                          |                                                                                                                                                                                                                                                                                                                             | l->n++;                                                                  | short_lock_sections = true  | 0    | does not include | includes         | ["loop.mutex"]            |
      | a sleep under it                        |                                                                                                                                                                                                                                                                                                                             | l->n = sleep(1);                                                         | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a sleep it reaches                      |                                                                                                                                                                                                                                                                                                                             | slow(l);                                                                 | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | turned off                              |                                                                                                                                                                                                                                                                                                                             | l->n++;                                                                  | short_lock_sections = false | 1    | includes         | does not include |                           |
      | off by default                          |                                                                                                                                                                                                                                                                                                                             | l->n++;                                                                  |                             | 1    | includes         | does not include |                           |
      | a short lock under it                   |                                                                                                                                                                                                                                                                                                                             | pthread_mutex_lock(&o.mu); pthread_mutex_unlock(&o.mu);                  | short_lock_sections = true  | 0    | does not include | includes         | ["loop.mutex","other.mu"] |
      | a long lock under it                    | void wait_other(void) { pthread_mutex_lock(&o.mu); (void)sleep(1); pthread_mutex_unlock(&o.mu); }                                                                                                                                                                                                                           | pthread_mutex_lock(&o.mu); pthread_mutex_unlock(&o.mu);                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a trylock of a long one                 | void wait_other(void) { pthread_mutex_lock(&o.mu); (void)sleep(1); pthread_mutex_unlock(&o.mu); }                                                                                                                                                                                                                           | if (pthread_mutex_trylock(&o.mu) == 0) pthread_mutex_unlock(&o.mu);      | short_lock_sections = true  | 0    | does not include | includes         | ["loop.mutex"]            |
      | a timedlock of a long one               | void wait_other(void) { pthread_mutex_lock(&o.mu); (void)sleep(1); pthread_mutex_unlock(&o.mu); }                                                                                                                                                                                                                           | if (pthread_mutex_timedlock(&o.mu, 0) == 0) pthread_mutex_unlock(&o.mu); | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a wait on a condition                   |                                                                                                                                                                                                                                                                                                                             | pthread_cond_wait(&ready, &l->mutex);                                    | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a helper that sleeps                    | CC_ACQUIRES(l->mutex) void lock_slow(struct loop *l) { pthread_mutex_lock(&l->mutex); slow(l); }                                                                                                                                                                                                                            | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a blocking helper with no body          | CC_BLOCKING CC_ACQUIRES(p->mu) void lock_other(struct other *p); CC_RELEASES(p->mu) void unlock_other(struct other *p);                                                                                                                                                                                                     | lock_other(&o); unlock_other(&o);                                        | short_lock_sections = true  | 1    | includes         | includes         | ["other.mu"]              |
      | held across a return                    | void lock_it(struct loop *l) { pthread_mutex_lock(&l->mutex); } void unlock_it(struct loop *l) { pthread_mutex_unlock(&l->mutex); } void wait_it(struct loop *l) { lock_it(l); slow(l); unlock_it(l); }                                                                                                                     | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | held at a jump                          | CC_MAY_JUMP int check(int n); void jump_held(struct loop *l) { pthread_mutex_lock(&l->mutex); l->n = check(l->n); pthread_mutex_unlock(&l->mutex); }                                                                                                                                                                        | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a lock through a param                  | void with(pthread_mutex_t *m) { pthread_mutex_lock(m); (void)sleep(1); pthread_mutex_unlock(m); }                                                                                                                                                                                                                           | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a lock through a field                  | struct conn { pthread_mutex_t *lk; }; void wait_conn(struct conn *c) { pthread_mutex_lock(c->lk); (void)sleep(1); pthread_mutex_unlock(c->lk); }                                                                                                                                                                            | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a lock through a global                 | pthread_mutex_t *shared; void wait_shared(void) { pthread_mutex_lock(shared); (void)sleep(1); pthread_mutex_unlock(shared); }                                                                                                                                                                                               | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a lock through an array of pointers     | struct pool { pthread_mutex_t *mus[2]; }; void wait_pool(struct pool *p) { pthread_mutex_lock(p->mus[0]); (void)sleep(1); pthread_mutex_unlock(p->mus[0]); }                                                                                                                                                                | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a global array of pointers              | pthread_mutex_t *locks[2]; void wait_locks(void) { pthread_mutex_lock(locks[0]); (void)sleep(1); pthread_mutex_unlock(locks[0]); }                                                                                                                                                                                          | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a local set from an array               | struct pool { pthread_mutex_t *mus[2]; }; void wait_pool(struct pool *p) { pthread_mutex_t *m = p->mus[1]; pthread_mutex_lock(m); (void)sleep(1); pthread_mutex_unlock(m); }                                                                                                                                                | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a lock that names no object             | struct pool { pthread_mutex_t mu; }; struct pool *current(void); void wait_current(void) { pthread_mutex_lock(&current()->mu); (void)sleep(1); pthread_mutex_unlock(&current()->mu); }                                                                                                                                      | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a pointer with no target                | void (*hook)(void);                                                                                                                                                                                                                                                                                                         | hook();                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a pointer with no target, one call down | void (*hook)(void); void call_hook(void) { hook(); }                                                                                                                                                                                                                                                                        | call_hook();                                                             | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a pointer to a short one                | static void quick(void) {} void (*hook)(void) = quick;                                                                                                                                                                                                                                                                      | hook();                                                                  | short_lock_sections = true  | 0    | does not include | includes         | ["loop.mutex"]            |
      | a lock through a global helper          | pthread_mutex_t real_mu; pthread_mutex_t *shared = &real_mu; CC_ACQUIRES(shared) void lock_shared(void); CC_RELEASES(shared) void unlock_shared(void); void wait_shared_h(void) { lock_shared(); (void)sleep(1); unlock_shared(); }                                                                                         | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | an annotation with a pointer field      | struct conn { pthread_mutex_t *lk; }; CC_ACQUIRES(c->lk) void lock_conn(struct conn *c); CC_RELEASES(c->lk) void unlock_conn(struct conn *c); void wait_conn_h(struct conn *c) { lock_conn(c); (void)sleep(1); unlock_conn(c); }                                                                                            | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | a helper that leaves another lock       | CC_ACQUIRES(p->mu) void lock_both(struct other *p, struct loop *l) { pthread_mutex_lock(&p->mu); pthread_mutex_lock(&l->mutex); } void wait_both(struct loop *l) { lock_both(&o, l); slow(l); pthread_mutex_unlock(&o.mu); }                                                                                                | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |
      | an ignored lock left held               | CC_IGNORE("CC-PATH-LOCK-NOT-RELEASED", "the caller unlocks") void lock_it(struct loop *l) { pthread_mutex_lock(&l->mutex); } CC_IGNORE("CC-PATH-LOCK-NOT-HELD", "the caller locks") void unlock_it(struct loop *l) { pthread_mutex_unlock(&l->mutex); } void wait_it(struct loop *l) { lock_it(l); slow(l); unlock_it(l); } | l->n++;                                                                  | short_lock_sections = true  | 1    | includes         | includes         | []                        |

  Scenario Outline: A lock through a pointer of [assume] owned_locks has the class of the pointer (<case>)
    A pointer field or global of `owned_locks` is the lock's own storage, which no other class names: a lock reached
    through it has its class, so its blocking sections make that class long and leave the other classes alone.

    Given the C file "sections.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h" /* found in the system folders */
      #include "cchecker.h"

      struct loop { pthread_mutex_t mutex; int n; };
      struct other { pthread_mutex_t mu; } o;
      struct conn { pthread_mutex_t *lk; int n; };
      void touch(void) { pthread_mutex_lock(&o.mu); o.mu = o.mu; pthread_mutex_unlock(&o.mu); }
      <more>
      void push(struct loop *l) { pthread_mutex_lock(&l->mutex); l->n++; pthread_mutex_unlock(&l->mutex); }
      CC_SHORT void tick(struct loop *l) { pthread_mutex_lock(&l->mutex); l->n = 0; pthread_mutex_unlock(&l->mutex); }
      """
    And the file "cchecker.toml" holds:
      """
      [library]
      short_lock_sections = true

      [assume]
      owned_locks = <owned>
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
      | case                            | more                                                                                                                                                                                                  | owned                   | exit | found            | inferred                            |
      | a field that owns its mutex     | void wait_conn(struct conn *c) { pthread_mutex_lock(c->lk); (void)sleep(1); pthread_mutex_unlock(c->lk); }                                                                                            | ["conn.lk"]             | 0    | does not include | ["loop.mutex","other.mu"]           |
      | another field named             | void wait_conn(struct conn *c) { pthread_mutex_lock(c->lk); (void)sleep(1); pthread_mutex_unlock(c->lk); }                                                                                            | ["other.mu"]            | 1    | includes         | []                                  |
      | a short field that owns         | void tap_conn(struct conn *c) { pthread_mutex_lock(c->lk); c->n++; pthread_mutex_unlock(c->lk); }                                                                                                     | ["conn.lk"]             | 0    | does not include | ["conn.lk","loop.mutex","other.mu"] |
      | a global that owns its mutex    | pthread_mutex_t *shared; void wait_shared(void) { pthread_mutex_lock(shared); (void)sleep(1); pthread_mutex_unlock(shared); }                                                                         | ["shared"]              | 0    | does not include | ["loop.mutex","other.mu"]           |
      | a helper of a field that owns   | struct lk { void *mutex; }; CC_ACQUIRES(l->mutex) void lk_take(struct lk *l); CC_RELEASES(l->mutex) void lk_drop(struct lk *l); struct lk *big; void wait_big(void) { lk_take(big); (void)sleep(1); lk_drop(big); } | ["lk.mutex"]            | 0    | does not include | ["loop.mutex","other.mu"]           |
      | a helper of a field not named   | struct lk { void *mutex; }; CC_ACQUIRES(l->mutex) void lk_take(struct lk *l); CC_RELEASES(l->mutex) void lk_drop(struct lk *l); struct lk *big; void wait_big(void) { lk_take(big); (void)sleep(1); lk_drop(big); } | ["other.mu"]            | 1    | includes         | []                                  |

  Scenario: A lock of [assume] owned_locks that no lock of the compile database has is an error
    Given the C file "sections.c" holds:
      """
      #include "pthread.h" /* found in the system folders */

      struct conn { pthread_mutex_t *lk; int n; };
      void bump(struct conn *c) { pthread_mutex_lock(c->lk); c->n++; pthread_mutex_unlock(c->lk); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      owned_locks = ["conn.lk"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 0
    Given the file "cchecker.toml" holds:
      """
      [assume]
      owned_locks = ["conn.lk", "conn.lck"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 2
    And the errors include:
      """
      no function, lock or field of the compile database is named conn.lck (assume.owned_locks)
      """

  Scenario: A static lock named like a short global of another file is not short
    Given the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "a.c", "arguments": ["cc", "-c", "a.c", "-I../../../include"]},
       {"directory": ".", "file": "b.c", "arguments": ["cc", "-c", "b.c", "-I../../../include"]}]
      """
    And the C file "a.c" holds:
      """
      #include "pthread.h" /* found in the system folders */

      pthread_mutex_t lock;
      int n;
      void quiet(void) { pthread_mutex_lock(&lock); n++; pthread_mutex_unlock(&lock); }
      """
    And the C file "b.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h" /* found in the system folders */
      #include "cchecker.h"

      static pthread_mutex_t lock;
      static int m;
      void wait_b(void) { pthread_mutex_lock(&lock); m = sleep(1); pthread_mutex_unlock(&lock); }
      CC_SHORT void tick(void) { pthread_mutex_lock(&lock); m++; pthread_mutex_unlock(&lock); }
      """
    And the file "cchecker.toml" holds:
      """
      [library]
      short_lock_sections = true
      """
    When I run cchecker in its folder with "--tools rules --json"
    Then the exit code is 1
    And the output includes:
      """
      "CC-EFFECT-SHORT-BLOCKS"
      """
    And the output includes:
      """
      "inferred_short_locks":["lock"]
      """

  Scenario: A run of some files infers no short lock, and says so
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
      short_lock_sections = true
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

  Scenario Outline: A section that takes a lock through a wrapper of short_locks does not block (<list>)
    Given the C file "sections.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      typedef struct { int x; } uv_mutex_t;
      void uv_mutex_lock(uv_mutex_t *h);
      void uv_mutex_unlock(uv_mutex_t *h);
      struct loop { pthread_mutex_t mutex; int n; };
      void push(struct loop *l, uv_mutex_t *u) {
        pthread_mutex_lock(&l->mutex); uv_mutex_lock(u); uv_mutex_unlock(u); pthread_mutex_unlock(&l->mutex);
      }
      CC_SHORT void tick(struct loop *l) { pthread_mutex_lock(&l->mutex); l->n++; pthread_mutex_unlock(&l->mutex); }
      """
    And the file "cchecker.toml" holds:
      """
      [library]
      short_lock_sections = true

      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json"
    Then the output includes:
      """
      "inferred_short_locks":<inferred>
      """

    Examples:
      | list                                 | inferred       |
      | short_locks = ["uv_mutex_lock(0)"]   | ["loop.mutex"] |
      | short_locks = ["uv_mutex_unlock(0)"] | []             |
