Feature: What the project assumes of its functions
  A project can say once what cchecker cannot see in the C: that a function counts as fine for CC_SHORT (it runs
  inline on the right thread only, or reads a descriptor that never blocks), or that no walk goes into a function at
  all (a trace call behind a runtime flag), or that a lock is held for a few instructions only. CC_ASSUME_SHORT, CC_STOP
  and CC_NO_SYSCALL_UNDER() say it in the C, `[assume] short`, `stop` and `short_locks` in the settings;
  `[assume] stop_fields` names the function-pointer fields that no walk follows. A name of `[assume]` that nothing of
  the compile database has is an error.

  Scenario Outline: A function trusted for CC_SHORT is not walked into by the short rule only (<case>)
    Given the C file "short.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "stdlib.h"
      #include "unistd.h"
      #include "cchecker.h"

      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; int fd; };
      <mark> int run_or_queue(int fd) { free(malloc(8)); return (int)write(fd, "x", 1); }
      CC_SHORT int tick(int fd) { return run_or_queue(fd); }
      CC_HOT int hot(int fd) { return run_or_queue(fd); }
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); run_or_queue(q->fd); pthread_mutex_unlock(&q->mu); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json short.c -- -I../../../include"
    Then the exit code is 1
    And the output <short>:
      """
      "CC-EFFECT-SHORT-BLOCKS"
      """
    And the output includes:
      """
      "CC-EFFECT-HOT-ALLOCATES"
      """
    And the output includes:
      """
      "CC-EFFECT-HOT-SYSCALL"
      """
    And the output includes:
      """
      "CC-PATH-SYSCALL-UNDER-LOCK"
      """

    Examples:
      | case     | mark            | list                     | short            |
      | no mark  |                 |                          | includes         |
      | marked   | CC_ASSUME_SHORT |                          | does not include |
      | listed   |                 | short = ["run_or_queue"] | does not include |

  Scenario Outline: No rule walks into a stopped function (<case>)
    Given the C file "stop.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      CC_LOCK_LEVEL(1) pthread_mutex_t low;
      struct queue { CC_NO_SYSCALL_UNDER() CC_LOCK_LEVEL(2) pthread_mutex_t mu; int fd; };
      <mark> void trace(int fd) { pthread_mutex_lock(&low); pthread_mutex_unlock(&low); (void)write(fd, "t", 1); }
      CC_SHORT void tick(int fd) { trace(fd); }
      CC_HOT void hot(int fd) { trace(fd); }
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); trace(q->fd); pthread_mutex_unlock(&q->mu); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json stop.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      "CC-EFFECT-SHORT-BLOCKS"
      """
    And the output <found>:
      """
      "CC-EFFECT-HOT-SYSCALL"
      """
    And the output <found>:
      """
      "CC-PATH-SYSCALL-UNDER-LOCK"
      """
    And the output <found>:
      """
      "CC-PATH-LOCK-ORDER"
      """

    Examples:
      | case    | mark    | list              | exit | found            |
      | no mark |         |                   | 1    | includes         |
      | marked  | CC_STOP |                   | 0    | does not include |
      | listed  |         | stop = ["trace"]  | 0    | does not include |

  Scenario Outline: An assumption leaves the body of a root, and a function that blocks itself, to the rules (<case>)
    Given the C file "root.c" holds:
      """
      #include "unistd.h"
      #include "cchecker.h"

      <mark> void wait_disk(int fd) { (void)fd; }
      CC_SHORT void tick(int fd) { <body> }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json root.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-EFFECT-SHORT-BLOCKS","tool":"rules","file":"root.c","line":5,
      """

    Examples:
      | case                       | mark                        | body                      | list             |
      | a root assumed short       |                             | (void)write(fd, "x", 1);  | short = ["tick"] |
      | a stopped root             |                             | (void)write(fd, "x", 1);  | stop = ["tick"]  |
      | blocking and assumed short | CC_BLOCKING CC_ASSUME_SHORT | wait_disk(fd);            |                  |

  Scenario Outline: Taking a short lock is not blocking for CC_SHORT (<case>)
    Given the C file "lock.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "cchecker.h"

      struct queue { <mark> pthread_mutex_t mu; pthread_mutex_t big; int n; }; pthread_mutex_t shared; static pthread_mutex_t mine;
      CC_ASSUME_SHORT CC_ACQUIRES(q->big) void lock_big(struct queue *q) { pthread_mutex_lock(&q->big); }
      CC_SHORT void tick(struct queue *q) { <take> q->n++; }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json lock.c -- -I../../../include"
    Then the exit code is <exit>

    Examples:
      | case               | mark                  | take                                                                                      | list                       | exit |
      | no mark            |                       | pthread_mutex_lock(&q->mu); pthread_mutex_unlock(&q->mu);                                 |                            | 1    |
      | marked             | CC_NO_SYSCALL_UNDER() | pthread_mutex_lock(&q->mu); pthread_mutex_unlock(&q->mu);                                 |                            | 0    |
      | listed             |                       | pthread_mutex_lock(&q->mu); pthread_mutex_unlock(&q->mu);                                 | short_locks = ["queue.mu"] | 0    |
      | another lock       | CC_NO_SYSCALL_UNDER() | pthread_mutex_lock(&q->big); pthread_mutex_unlock(&q->big);                               |                            | 1    |
      | a short and a long | CC_NO_SYSCALL_UNDER() | pthread_mutex_lock(&q->mu); pthread_mutex_unlock(&q->mu); pthread_mutex_lock(&q->big); pthread_mutex_unlock(&q->big); | | 1 |
      | a listed global    |                       | pthread_mutex_lock(&shared); pthread_mutex_unlock(&shared);                               | short_locks = ["shared"]   | 0    |
      | a listed static    |                       | pthread_mutex_lock(&mine); pthread_mutex_unlock(&mine);                                   | short_locks = ["mine"]     | 0    |
      | a static by file   |                       | pthread_mutex_lock(&mine); pthread_mutex_unlock(&mine);                                   | short_locks = ["mine@lock.c"] | 0  |
      | a wrapper assumed  |                       | lock_big(q); pthread_mutex_unlock(&q->big);                                               |                            | 0    |

  Scenario Outline: A short lock leaves the other rules and the other locks as they are (<case>)
    Given the C file "rest.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"
      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; pthread_mutex_t big; int fd; };
      void take_big(struct queue *q) { pthread_mutex_lock(&q->big); pthread_mutex_unlock(&q->big); }
      void lock_it(pthread_mutex_t *m) { pthread_mutex_lock(m); pthread_mutex_unlock(m); }
      <code>
      """
    When I run cchecker in its folder with "--tools rules --json rest.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      "<found>"
      """

    Examples:
      | case                     | found                      | code                                                                                                             |
      | through a parameter      | CC-EFFECT-SHORT-BLOCKS     | CC_SHORT void tick(struct queue *q) { lock_it(&q->mu); }                                                         |
      | and a long lock below    | CC-EFFECT-SHORT-BLOCKS     | CC_SHORT void tick(struct queue *q) { pthread_mutex_lock(&q->mu); pthread_mutex_unlock(&q->mu); take_big(q); }   |
      | a system call under it   | CC-PATH-SYSCALL-UNDER-LOCK | void push(struct queue *q) { pthread_mutex_lock(&q->mu); (void)write(q->fd, "x", 1); pthread_mutex_unlock(&q->mu); } |
      | hot                      | CC-EFFECT-HOT-SYSCALL      | CC_HOT void hot(struct queue *q) { pthread_mutex_lock(&q->mu); pthread_mutex_unlock(&q->mu); }                   |

  Scenario: A lock of [assume] short_locks that no lock of the compile database has is an error
    Given the C file "lock.c" holds:
      """
      #include <pthread.h>
      struct queue { pthread_mutex_t mu; int n; };
      void bump(struct queue *q) { pthread_mutex_lock(&q->mu); q->n++; pthread_mutex_unlock(&q->mu); }
      """
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "lock.c", "arguments": ["cc", "-c", "lock.c"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      short_locks = ["queue.mu"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 0
    Given the file "cchecker.toml" holds:
      """
      [assume]
      short_locks = ["queue.mu", "queue.mux"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 2
    And the errors include:
      """
      no function, lock or field of the compile database is named queue.mux (assume.short_locks)
      """

  Scenario: A name of [assume] holds for the static functions of that name in every file
    Given the C file "a.c" holds:
      """
      #include "unistd.h"
      #include "cchecker.h"
      static void trace(int fd) { (void)write(fd, "a", 1); }
      CC_SHORT void a(int fd) { trace(fd); }
      """
    And the C file "b.c" holds:
      """
      #include "unistd.h"
      #include "cchecker.h"
      static void trace(int fd) { (void)write(fd, "b", 1); }
      CC_SHORT void b(int fd) { trace(fd); }
      """
    When I run cchecker in its folder with "--tools rules --json a.c b.c -- -I../../../include"
    Then the exit code is 1
    Given the file "cchecker.toml" holds:
      """
      [assume]
      stop = ["trace"]
      """
    When I run cchecker in its folder with "--tools rules --json a.c b.c -- -I../../../include"
    Then the exit code is 0

  Scenario: A name of [assume] that no function of the compile database has is an error
    Given the C file "tick.c" holds:
      """
      int helper(void) { return 1; }
      int external(void);
      int tick(void) { return helper() + external(); }
      """
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "tick.c", "arguments": ["cc", "-c", "tick.c"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      short = ["helper"]
      stop = ["helper", "external"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 0
    Given the file "cchecker.toml" holds:
      """
      [assume]
      stop = ["helper", "tracer"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 2
    And the errors include:
      """
      tracer (assume.stop)
      """
    When I run cchecker in its folder with "--tools rules tick.c"
    Then the exit code is 0
    And the errors include:
      """
      cchecker: the names of [assume] were not checked
      """

  Scenario Outline: No rule follows a call through a field of [assume] stop_fields (<case>)
    Given the C file "fields.c" holds:
      """
      #include "pthread.h" /* found in the system folders */
      #include "unistd.h"
      #include "cchecker.h"

      struct request { void (*call)(int); void (*done)(int); int fd; };
      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; };
      static void slow(int fd) { (void)write(fd, "x", 1); }
      void setup(struct request *r) { r->call = slow; r->done = slow; }
      CC_SHORT void tick(struct request *r) { <code> }
      void push(struct queue *q, struct request *r) { pthread_mutex_lock(&q->mu); <code> pthread_mutex_unlock(&q->mu); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json fields.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      "CC-EFFECT-SHORT-BLOCKS"
      """
    And the output <found>:
      """
      "CC-PATH-SYSCALL-UNDER-LOCK"
      """

    Examples:
      | case                 | code                                  | list                           | exit | found            |
      | not listed           | r->call(r->fd);                       |                                | 1    | includes         |
      | listed               | r->call(r->fd);                       | stop_fields = ["request.call"] | 0    | does not include |
      | another field        | r->done(r->fd);                       | stop_fields = ["request.call"] | 1    | includes         |
      | through a local copy | void (*f)(int) = r->call; f(r->fd);   | stop_fields = ["request.call"] | 1    | includes         |

  Scenario: A field of [assume] stop_fields that no record of the compile database has is an error
    Given the C file "fields.c" holds:
      """
      struct request { void (*call)(int); int fd; };
      void run(struct request *r) { r->call(r->fd); }
      """
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "fields.c", "arguments": ["cc", "-c", "fields.c"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      stop_fields = ["request.call"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 0
    Given the file "cchecker.toml" holds:
      """
      [assume]
      stop_fields = ["request.call", "request.cal"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 2
    And the errors include:
      """
      no function, lock or field of the compile database is named request.cal (assume.stop_fields)
      """
