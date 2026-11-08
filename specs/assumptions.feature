Feature: What the project assumes of its functions
  A project can say once what cchecker cannot see in the C: that a function counts as fine for CC_SHORT (it runs
  inline on the right thread only, or reads a descriptor that never blocks), or that no walk goes into a function at
  all (a trace call behind a runtime flag). CC_ASSUME_SHORT and CC_STOP say it in the C, `[assume] short` and
  `[assume] stop` in the settings. A name of `[assume]` that no function of the compile database has is an error.

  Scenario Outline: A function trusted for CC_SHORT is not walked into by the short rule (<case>)
    Given the C file "short.c" holds:
      """
      #include "stdlib.h"
      #include "unistd.h"
      #include "cchecker.h"

      <mark> int run_or_queue(int fd) { free(malloc(8)); return (int)write(fd, "x", 1); }
      CC_SHORT int tick(int fd) { return run_or_queue(fd); }
      CC_HOT int hot(int fd) { return run_or_queue(fd); }
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

  Scenario: A name of [assume] that no function of the compile database has is an error
    Given the C file "tick.c" holds:
      """
      int helper(void) { return 1; }
      int tick(void) { return helper(); }
      """
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "tick.c", "arguments": ["cc", "-c", "tick.c"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      short = ["helper"]
      stop = ["helper"]
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
      tracer
      """
    When I run cchecker in its folder with "--tools rules tick.c"
    Then the exit code is 0
    And the errors include:
      """
      cchecker: the names of [assume] were not checked
      """
