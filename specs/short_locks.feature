Feature: Short locks inferred from their critical sections
  A lock that no call made while it is held reaches a blocking call is held for a few instructions: taking it is not
  blocking for CC_SHORT, as for a lock marked CC_NO_SYSCALL_UNDER() or named in `[assume] short_locks`. `--json` lists
  the classes it found in `inferred_short_locks`, and `[library] short_lock_sections = false` turns it off.

  Scenario Outline: A lock whose sections never block is short (<case>)
    Given the C file "sections.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h" /* found in the system folders */
      #include "cchecker.h"

      struct loop { pthread_mutex_t mutex; int n; };
      struct other { pthread_mutex_t mu; } o;
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
    When I run cchecker in its folder with "--tools rules --json sections.c -- -I../../../include"
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
      | case                      | more                                                                                              | under                                                    | setting                     | exit | found            | inferred                 |
      | short sections            |                                                                                                   | l->n++;                                                  |                             | 0    | does not include | ["loop.mutex"]           |
      | a sleep under it          |                                                                                                   | l->n = sleep(1);                                         |                             | 1    | includes         | []                       |
      | a sleep it reaches        |                                                                                                   | slow(l);                                                 |                             | 1    | includes         | []                       |
      | turned off                |                                                                                                   | l->n++;                                                  | short_lock_sections = false | 1    | includes         | []                       |
      | a short lock under it     |                                                                                                   | pthread_mutex_lock(&o.mu); pthread_mutex_unlock(&o.mu);  |                             | 0    | does not include | ["loop.mutex","other.mu"] |
      | a long lock under it      | void wait_other(void) { pthread_mutex_lock(&o.mu); (void)sleep(1); pthread_mutex_unlock(&o.mu); } | pthread_mutex_lock(&o.mu); pthread_mutex_unlock(&o.mu);  |                             | 1    | includes         | []                       |
      | a helper that sleeps      | CC_ACQUIRES(l->mutex) void lock_slow(struct loop *l) { pthread_mutex_lock(&l->mutex); slow(l); }  | l->n++;                                                  |                             | 1    | includes         | []                       |
      | a lock through a pointer  | void with(pthread_mutex_t *m) { pthread_mutex_lock(m); (void)sleep(1); pthread_mutex_unlock(m); } | l->n++;                                                  |                             | 1    | includes         | []                       |
