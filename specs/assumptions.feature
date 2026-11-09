Feature: What the project assumes of its functions
  A project can say once what cchecker cannot see in the C: that a function counts as fine for CC_SHORT (it runs inline
  on the right thread only, or reads a descriptor that never blocks), or that no walk goes into a function at all (a
  trace call behind a runtime flag), or that a lock is held for a few instructions only. CC_ASSUME_SHORT, CC_STOP and
  CC_NO_SYSCALL_UNDER() say it in the C, `[assume] short`, `stop` and `short_locks` in the settings; `[assume]
  stop_fields` names the function-pointer fields that no walk follows, `[assume] may_jump` the functions that may jump
  out of their caller (as CC_MAY_JUMP), and `[assume] jumps` those that always do (as CC_JUMPS). A name of `[assume]`
  that nothing of the compile database has is an error.

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

  Scenario Outline: name@file in [assume] marks the function of that file only (<list>)
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
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json a.c b.c -- -I../../../include"
    Then the exit code is 1
    And the output <a>:
      """
      "file":"a.c","line":4,
      """
    And the output <b>:
      """
      "file":"b.c","line":4,
      """

    Examples:
      | list                      | a                | b                |
      | stop = ["trace@a.c"]      | does not include | includes         |
      | stop = ["trace@b.c"]      | includes         | does not include |
      | short = ["trace@b.c"]     | includes         | does not include |
      | jumps = ["trace@a.c"]     | does not include | includes         |

  Scenario: A name@file of [assume] that no function has is an error, as a bare name is (and likewise may_jump, jumps)
    Given the C file "a.c" holds:
      """
      static void put(void) {}
      void run(void) { put(); }
      """
    And the C file "b.c" holds:
      """
      static void put(void) {}
      void run_b(void) { put(); }
      """
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "a.c", "arguments": ["cc", "-c", "a.c"]},
       {"directory": ".", "file": "b.c", "arguments": ["cc", "-c", "b.c"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      stop = ["put@a.c", "put@b.c"]
      may_jump = ["put@a.c"]
      jumps = ["put@b.c"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 0
    Given the file "cchecker.toml" holds:
      """
      [assume]
      stop = ["put@a.c", "put@c.c", "run@b.c"]
      may_jump = ["put@a.c", "put@d.c"]
      jumps = ["put@b.c", "put@e.c"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 2
    And the errors include:
      """
      put@c.c (assume.stop)
      """
    And the errors include:
      """
      run@b.c (assume.stop)
      """
    And the errors include:
      """
      put@d.c (assume.may_jump)
      """
    And the errors include:
      """
      put@e.c (assume.jumps)
      """
    And the errors do not include:
      """
      put@a.c
      """

  Scenario Outline: name@file of [assume] names the file of the definition or of any declaration (<path>)
    Given the file "slow.h" holds:
      """
      void slow(int fd);
      """
    And the C file "slow.c" holds:
      """
      #include "slow.h"
      #include "unistd.h"
      void slow(int fd) { (void)write(fd, "x", 1); }
      """
    And the C file "tick.c" holds:
      """
      #include "slow.h"
      #include "cchecker.h"
      CC_SHORT void tick(int fd) { slow(fd); }
      """
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "slow.c", "arguments": ["cc", "-c", "slow.c", "-I../../../include"]},
       {"directory": ".", "file": "tick.c", "arguments": ["cc", "-c", "tick.c", "-I../../../include"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      short = ["slow@<path>"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 0

    Examples:
      | path     |
      | slow.h   |
      | slow.c   |
      | ./slow.c |

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
      may_jump = ["external"]
      jumps = ["external"]
      catches = ["tick"]
      jump_releases = ["helper"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 0
    Given the file "cchecker.toml" holds:
      """
      [assume]
      stop = ["helper", "tracer"]
      may_jump = ["raise_error"]
      jumps = ["raise_fatal"]
      catches = ["run_guarded"]
      jump_releases = ["take_recorded"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 2
    And the errors include:
      """
      tracer (assume.stop)
      """
    And the errors include:
      """
      raise_error (assume.may_jump)
      """
    And the errors include:
      """
      raise_fatal (assume.jumps)
      """
    And the errors include:
      """
      run_guarded (assume.catches)
      """
    And the errors include:
      """
      take_recorded (assume.jump_releases)
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
    When I run cchecker in its folder with "--tools rules <flags> fields.c -- -I../../../include"
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
      | case                 | code                                | list                           | flags              | exit | found            |
      | not listed           | r->call(r->fd);                     |                                | --json             | 1    | includes         |
      | listed               | r->call(r->fd);                     | stop_fields = ["request.call"] | --json             | 0    | does not include |
      | listed, all paths    | r->call(r->fd);                     | stop_fields = ["request.call"] | --all-paths --json | 0    | does not include |
      | another field        | r->done(r->fd);                     | stop_fields = ["request.call"] | --json             | 1    | includes         |
      | through a local copy | void (*f)(int) = r->call; f(r->fd); | stop_fields = ["request.call"] | --json             | 1    | includes         |

  Scenario Outline: A field of a struct nested in a typedef'd anonymous struct is named by the typedef (<case>)
    Given the C file "fields.c" holds:
      """
      #include "unistd.h"
      #include "cchecker.h"

      typedef struct { struct { void (*call)(int); } ops; int fd; } conn_t;
      static void slow(int fd) { (void)write(fd, "x", 1); }
      void setup(conn_t *c) { c->ops.call = slow; }
      CC_SHORT void tick(conn_t *c) { c->ops.call(c->fd); }
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

    Examples:
      | case       | list                          | exit | found            |
      | not listed |                               | 1    | includes         |
      | listed     | stop_fields = ["conn_t.call"] | 0    | does not include |

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

  Scenario Outline: [assume] stop_calls cuts one call edge and keeps the same callee for its other callers (<list>)
    Given the C file "calls.c" holds:
      """
      #include "unistd.h"
      #include "cchecker.h"
      static void trace(int fd) { (void)write(fd, "a", 1); }
      CC_SHORT void first(int fd) { trace(fd); }
      CC_SHORT void second(int fd) { trace(fd); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json calls.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <first>:
      """
      "file":"calls.c","line":4,
      """
    And the output <second>:
      """
      "file":"calls.c","line":5,
      """

    Examples:
      | list                                             | exit | first            | second           |
      | stop_calls = ["first>trace"]                     | 1    | does not include | includes         |
      | stop_calls = ["second>trace"]                    | 1    | includes         | does not include |
      | stop_calls = ["first>trace", "second>trace"]     | 0    | does not include | does not include |
      | stop_calls = ["first@calls.c>trace@calls.c"]     | 1    | does not include | includes         |
      | stop = ["trace"]                                 | 0    | does not include | does not include |

  Scenario: A pair of [assume] stop_calls that matches no call is an error, and the others still apply
    Given the C file "a.c" holds:
      """
      static void put(void) {}
      void run(void) { put(); }
      """
    And the C file "b.c" holds:
      """
      static void put(void) {}
      void run_b(void) { put(); }
      """
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "a.c", "arguments": ["cc", "-c", "a.c"]},
       {"directory": ".", "file": "b.c", "arguments": ["cc", "-c", "b.c"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      stop_calls = ["run@a.c>put@a.c", "run_b>put@b.c"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 0
    Given the file "cchecker.toml" holds:
      """
      [assume]
      stop_calls = ["run@a.c>put@a.c", "run@b.c>put@b.c", "put>run", "gone>put"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 2
    And the errors include:
      """
      run@b.c>put@b.c (assume.stop_calls)
      """
    And the errors include:
      """
      put>run (assume.stop_calls)
      """
    And the errors include:
      """
      gone>put (assume.stop_calls)
      """
    And the errors do not include:
      """
      run@a.c>put@a.c
      """

  Scenario Outline: [assume] stop_calls cuts all the calls of the callee in the caller, and not a path through another function (<case>)
    Given the C file "calls.c" holds:
      """
      #include "unistd.h"
      #include "cchecker.h"
      static void trace(int fd) { (void)write(fd, "a", 1); }
      static void mid(int fd) { trace(fd); }
      <code>
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json calls.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      "file":"calls.c","line":5,
      """

    Examples:
      | case                  | code                                                      | list                       | exit | found            |
      | two call sites        | CC_SHORT void first(int fd) { trace(fd); trace(fd); }     | stop_calls = ["first>trace"] | 0  | does not include |
      | another path          | CC_SHORT void first(int fd) { trace(fd); mid(fd); }       | stop_calls = ["first>trace"] | 1  | includes         |
      | the edge below        | CC_SHORT void first(int fd) { mid(fd); }                  | stop_calls = ["mid>trace"]   | 0  | does not include |
      | the edge above        | CC_SHORT void first(int fd) { mid(fd); }                  | stop_calls = ["first>mid"]   | 0  | does not include |
      | no pair               | CC_SHORT void first(int fd) { trace(fd); trace(fd); }     |                              | 1  | includes         |

  Scenario Outline: [assume] stop_calls also cuts the call for the lock rules (<list>)
    Given the C file "held.c" holds:
      """
      #include "pthread.h"
      #include "unistd.h"
      #include "cchecker.h"
      struct queue { CC_NO_SYSCALL_UNDER() pthread_mutex_t mu; int fd; };
      static void deep(int fd) { (void)write(fd, "x", 1); }
      static void mid(int fd) { deep(fd); }
      void push(struct queue *q) { pthread_mutex_lock(&q->mu); mid(q->fd); pthread_mutex_unlock(&q->mu); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json held.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      "CC-PATH-SYSCALL-UNDER-LOCK"
      """

    Examples:
      | list                          | exit | found            |
      | stop_calls = ["mid>deep"]     | 0    | does not include |
      | stop_calls = ["push>mid"]     | 1    | includes         |
      | stop = ["unused"]             | 1    | includes         |

  Scenario Outline: [assume] stop_calls also cuts the call from the inference of may_jump_callers (<list>)
    Given the C file "jump.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      CC_JUMPS void fail(void);
      int w(int n) { if (0 > n) fail(); return n; }
      int x(int n) { return w(n) + 1; }
      int start(int n) { CC_OWNS char *p = malloc(8); if (!p) return -1; p[0] = (char)x(n); free(p); return 0; }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json jump.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      "source":"may_jump_callers"
      """

    Examples:
      | list                      | exit | found            |
      | stop_calls = ["x>w"]      | 0    | does not include |
      | stop_calls = ["x>fail"]   | 1    | includes         |
      | stop = ["unused"]         | 1    | includes         |

  Scenario Outline: [assume] acquires and releases mark a lock wrapper that the C cannot be marked (<case>)
    Given the C file "wrap.c" holds:
      """
      #include "pthread.h"
      void my_lock(pthread_mutex_t *m) { pthread_mutex_lock(m); }
      void my_unlock(pthread_mutex_t *m) { pthread_mutex_unlock(m); }
      void work(pthread_mutex_t *m) { my_lock(m); my_unlock(m); }
      void leak(pthread_mutex_t *m) { my_lock(m); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <acquires>
      <releases>
      """
    When I run cchecker in its folder with "--tools rules --json wrap.c"
    Then the exit code is 1
    And the output <take>:
      """
      "CC-PATH-LOCK-NOT-RELEASED","tool":"rules","file":"wrap.c","line":2,
      """
    And the output <give>:
      """
      "CC-PATH-LOCK-NOT-HELD","tool":"rules","file":"wrap.c","line":3,
      """
    And the output does not include:
      """
      "file":"wrap.c","line":4,
      """
    And the output <leak>:
      """
      "CC-PATH-LOCK-NOT-RELEASED","tool":"rules","file":"wrap.c","line":5,
      """

    Examples:
      | case             | acquires                          | releases                            | take             | give             | leak             |
      | not listed       | stop = ["unused"]                 |                                     | includes         | includes         | does not include |
      | listed           | acquires = ["my_lock(0)"]         | releases = ["my_unlock(0)"]         | does not include | does not include | includes         |
      | listed by file   | acquires = ["my_lock@wrap.c(0)"]  | releases = ["my_unlock@wrap.c(0)"]  | does not include | does not include | includes         |

  Scenario Outline: [assume] short_locks takes a wrapper whose locks are short (<case>)
    Given the C file "short.c" holds:
      """
      #include "pthread.h"
      #include "cchecker.h"
      typedef struct { int fd; } uv_mutex_t;
      void uv_mutex_lock(uv_mutex_t *handle); void uv_mutex_unlock(uv_mutex_t *handle);
      void my_lock(pthread_mutex_t *m) { pthread_mutex_lock(m); pthread_mutex_unlock(m); }
      CC_SHORT void tick(uv_mutex_t *m) { uv_mutex_lock(m); uv_mutex_unlock(m); }
      CC_SHORT void tock(pthread_mutex_t *m) { my_lock(m); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json short.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <tick>:
      """
      "file":"short.c","line":6,
      """
    And the output <tock>:
      """
      "file":"short.c","line":7,
      """

    Examples:
      | case                  | list                                         | exit | tick             | tock             |
      | not listed            | short_locks = ["queue.mu"]                   | 1    | includes         | includes         |
      | library wrapper      | short_locks = ["uv_mutex_lock(0)"]           | 1    | does not include | includes         |
      | project wrapper      | short_locks = ["my_lock(0)"]                 | 1    | includes         | does not include |
      | both                  | short_locks = ["uv_mutex_lock(0)", "my_lock(0)"] | 0 | does not include | does not include |

  Scenario: A wrapper of acquires, releases or short_locks that no function has is an error
    Given the C file "wrap.c" holds:
      """
      #include "pthread.h"
      void my_lock(pthread_mutex_t *m) { pthread_mutex_lock(m); }
      void my_unlock(pthread_mutex_t *m) { pthread_mutex_unlock(m); }
      void work(pthread_mutex_t *m) { my_lock(m); my_unlock(m); }
      """
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "wrap.c", "arguments": ["cc", "-c", "wrap.c"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      acquires = ["my_lock(0)"]
      releases = ["my_unlock@wrap.c(0)"]
      short_locks = ["my_lock(0)", "uv_mutex_lock(0)"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 0
    Given the file "cchecker.toml" holds:
      """
      [assume]
      acquires = ["my_lock(0)", "my_lok(0)", "my_lock(1)"]
      releases = ["my_unlock@other.c(0)"]
      short_locks = ["my_lock(0)", "mine(0)"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 2
    And the errors include:
      """
      my_lok(0) (assume.acquires)
      """
    And the errors include:
      """
      my_lock(1) (assume.acquires)
      """
    And the errors include:
      """
      my_unlock@other.c(0) (assume.releases)
      """
    And the errors include:
      """
      mine(0) (assume.short_locks)
      """
    And the errors do not include:
      """
      my_lock(0) (assume
      """

  Scenario: A lock wrapper of acquires and releases is one lock for the callers of its prototype and of its definition
    Given the C file "lock.h" holds:
      """
      #include "pthread.h"
      void my_lock(pthread_mutex_t *mutex);
      void my_unlock(pthread_mutex_t *mutex);
      """
    And the C file "def.c" holds:
      """
      #include "lock.h"
      void my_lock(pthread_mutex_t *m) { pthread_mutex_lock(m); }
      void my_unlock(pthread_mutex_t *m) { pthread_mutex_unlock(m); }
      void inside(pthread_mutex_t *m) { my_lock(m); my_unlock(m); }
      """
    And the C file "use.c" holds:
      """
      #include "lock.h"
      void work(pthread_mutex_t *m) { my_lock(m); my_unlock(m); }
      void leak(pthread_mutex_t *m) { my_lock(m); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      acquires = ["my_lock(0)"]
      releases = ["my_unlock(0)"]
      """
    When I run cchecker in its folder with "--tools rules --json def.c use.c"
    Then the exit code is 1
    And the output includes once:
      """
      "CC-PATH-LOCK-NOT-RELEASED"
      """
    And the output includes:
      """
      "file":"use.c","line":3,
      """

  Scenario Outline: A wrapper of acquires and releases is one lock whatever its declarations call the parameter (<case>)
    Given the C file "lock.h" holds:
      """
      #include "pthread.h"
      void my_lock(pthread_mutex_t *mutex);
      void my_unlock(pthread_mutex_t *);
      """
    And the C file "def.c" holds:
      """
      #include "lock.h"
      void my_lock(pthread_mutex_t *m) { pthread_mutex_lock(m); }
      void my_unlock(pthread_mutex_t *m) { pthread_mutex_unlock(m); }
      void inside(pthread_mutex_t *m) { my_lock(m); my_unlock(m); }
      """
    And the C file "use.c" holds:
      """
      #include "lock.h"
      void work(pthread_mutex_t *m) { my_lock(m); my_unlock(m); }
      void twice(pthread_mutex_t *m) { my_lock(m); my_unlock(m); my_unlock(m); }
      void leak(pthread_mutex_t *m) { my_lock(m); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      acquires = ["<take>"]
      releases = ["<give>"]
      """
    When I run cchecker in its folder with "--tools rules --json def.c use.c"
    Then the exit code is 1
    And the output includes:
      """
      "CC-PATH-LOCK-NOT-HELD","tool":"rules","file":"use.c","line":3,
      """
    And the output includes:
      """
      "CC-PATH-LOCK-NOT-RELEASED","tool":"rules","file":"use.c","line":4,
      """
    And the output does not include:
      """
      "file":"use.c","line":2,
      """
    And the output does not include:
      """
      "file":"def.c"
      """

    Examples:
      | case                | take                | give                  |
      | by name             | my_lock(0)          | my_unlock(0)          |
      | by the definition   | my_lock@def.c(0)    | my_unlock@def.c(0)    |
      | by the prototype    | my_lock@lock.h(0)   | my_unlock@lock.h(0)   |

  Scenario: A static wrapper is marked by the file of its definition
    Given the C file "a.c" holds:
      """
      #include "pthread.h"
      static void grab(pthread_mutex_t *m) { pthread_mutex_lock(m); }
      void leak_a(pthread_mutex_t *m) { grab(m); }
      """
    And the C file "b.c" holds:
      """
      #include "pthread.h"
      static void grab(pthread_mutex_t *m) { pthread_mutex_lock(m); }
      void leak_b(pthread_mutex_t *m) { grab(m); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      acquires = ["grab@a.c(0)"]
      """
    When I run cchecker in its folder with "--tools rules --json a.c b.c"
    Then the exit code is 1
    And the output includes:
      """
      "CC-PATH-LOCK-NOT-RELEASED","tool":"rules","file":"a.c","line":3,
      """
    And the output does not include:
      """
      "file":"b.c","line":3,
      """

  Scenario Outline: A wrapper of short_locks is matched by any declaration of the function (<list>)
    Given the C file "uv.h" holds:
      """
      typedef struct { int fd; } uv_mutex_t;
      void uv_mutex_lock(uv_mutex_t *handle);
      void uv_mutex_unlock(uv_mutex_t *handle);
      """
    And the C file "short.c" holds:
      """
      #include "cchecker.h"
      #include "uv.h"
      CC_SHORT void tick(uv_mutex_t *m) { uv_mutex_lock(m); uv_mutex_unlock(m); }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      short_locks = ["<list>"]
      """
    When I run cchecker in its folder with "--tools rules --json short.c -- -I../../../include"
    Then the exit code is <exit>

    Examples:
      | list                      | exit |
      | uv_mutex_lock@uv.h(0)     | 0    |
      | uv_mutex_lock@other.h(0)  | 1    |
