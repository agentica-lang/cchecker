Feature: Effects on the call graph
  The rules tool reads clang's AST of every file and builds one call graph for the project. A CC_SHORT function never
  reaches a blocking call, and a CC_HOT function never allocates or makes a system call. The finding is at the
  annotated function, and `path` is the chain of calls that breaks the rule.

  Scenario: A short function that reaches a blocking call is a finding with the call path
    When I run cchecker with "--tools rules --json fixtures/effects/short_blocks.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-EFFECT-SHORT-BLOCKS","tool":"rules","file":"fixtures/effects/short_blocks.c","line":7,"column":14,
      """
    And the output includes:
      """
      "path":["next_id","helper","fill","read"]
      """

  Scenario: A short function that never blocks passes, recursion included
    When I run cchecker with "--tools rules fixtures/effects/short_ok.c -- -I../include"
    Then the exit code is 0

  Scenario: A CC_BLOCKING function of another file blocks, whatever its body does
    When I run cchecker with "--tools rules --json fixtures/effects/caller.c fixtures/effects/waiter.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-EFFECT-SHORT-BLOCKS","tool":"rules","file":"fixtures/effects/caller.c","line":4,"column":5,
      """
    And the output includes:
      """
      "path":["poll_once","check","wait_ready"]
      """

  Scenario: An annotation of the definition holds in a file that declares the function without it
    When I run cchecker with "--tools rules --json fixtures/effects/def.c fixtures/effects/decl.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["ask","wait_slow"]
      """

  Scenario: Static functions of the same name in two files are two functions
    When I run cchecker with "--tools rules fixtures/effects/static_a.c fixtures/effects/static_b.c -- -I../include"
    Then the exit code is 0

  Scenario: A hot function that allocates or makes a system call is a finding for each
    When I run cchecker with "--tools rules --json fixtures/effects/hot.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-EFFECT-HOT-ALLOCATES","tool":"rules","file":"fixtures/effects/hot.c","line":7,"column":14,
      """
    And the output includes:
      """
      "path":["hot_alloc","grow","malloc"]
      """
    And the output includes:
      """
      {"code":"CC-EFFECT-HOT-SYSCALL","tool":"rules","file":"fixtures/effects/hot.c","line":8,"column":13,
      """
    And the output includes:
      """
      "path":["hot_write","write"]
      """

  Scenario: A hot function that only computes and copies passes
    When I run cchecker with "--tools rules fixtures/effects/hot_ok.c -- -I../include"
    Then the exit code is 0

  Scenario: An AST larger than 1 MiB is read whole
    When clang dumps the JSON AST of "fixtures/effects/big_headers.c"
    Then the dump is larger than 1 MiB
    When I run cchecker with "--tools rules --json fixtures/effects/big_headers.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["current_count","locked_count","pthread_mutex_lock"]
      """

  Scenario Outline: A call through a function pointer reaches the functions stored in it
    Given the C file "pointers.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      typedef int (*step_fn)(int);
      struct ops { const char *name; step_fn step; };
      typedef struct { step_fn run; } Runner;

      static int quick(int x) { return x + 1; }
      static int slow(int x) { sleep(1); return x; }

      <setup>
      CC_SHORT int entry(int x) { return <call>; }
      """
    When I run cchecker with "--tools rules --json $DIR/pointers.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["entry",<path>]
      """

    Examples:
      | setup                                                | call           | path                   |
      | struct ops T[] = {{"q", quick}, {"s", slow}};        | T[x].step(x)   | "slow","sleep"         |
      | Runner r = {.run = slow};                            | r.run(x)       | "slow","sleep"         |
      | struct ops o; void set(void) { o.step = &slow; }     | o.step(x)      | "slow","sleep"         |
      | int apply(step_fn f, int x) { return f(x); }         | apply(slow, x) | "apply","slow","sleep" |
      | step_fn steps[] = {quick, slow};                     | steps[x](x)    | "slow","sleep"         |
      | step_fn current = slow;                              | current(x)     | "slow","sleep"         |
      | int run(int x) { step_fn f = slow; return (*f)(x); } | run(x)         | "run","slow","sleep"   |

  Scenario: A pointer copied from a parameter into a field reaches the functions passed to the parameter
    Given the C file "copied.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      typedef void (*handler_fn)(void *);
      struct inbox { handler_fn handle; void *owner; };

      static void slow(void *owner) { (void)owner; sleep(1); }
      static struct inbox box;

      void inbox_open(handler_fn handle, void *owner) {
        handler_fn chosen = handle;
        box.handle = chosen;
        box.owner = owner;
      }

      void start(void) { inbox_open(slow, 0); }
      CC_SHORT void inbox_run(void) { box.handle(box.owner); }
      """
    When I run cchecker with "--tools rules --json $DIR/copied.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["inbox_run","slow","sleep"]
      """

  Scenario Outline: A call through a function pointer that holds only short functions passes
    Given the C file "pointers.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      typedef int (*step_fn)(int);
      struct ops { const char *name; step_fn step; };

      static int quick(int x) { return x + 1; }
      static int slow(int x) { sleep(1); return x; }
      static int unused(void) { return slow(1); }

      <setup>
      CC_SHORT int entry(int x) { return <call>; }
      """
    When I run cchecker with "--tools rules $DIR/pointers.c -- -I../include"
    Then the exit code is 0

    Examples:
      | setup                                        | call            |
      | struct ops T[] = {{"q", quick}};             | T[x].step(x)    |
      | int apply(step_fn f, int x) { return f(x); } | apply(quick, x) |

  Scenario: The AST dumps are removed at the end of the run
    When I run cchecker with "--tools rules fixtures/effects/short_blocks.c -- -I../include" and TMPDIR "$DIR/tmp"
    Then the exit code is 1
    And the folder "$DIR/tmp" is empty

  Scenario: The findings of the rules go into the baseline like the others
    When I run cchecker with "--tools rules -b $DIR/base.json --update-baseline fixtures/effects/hot.c -- -I../include"
    Then the exit code is 0
    When I run cchecker with "--tools rules -b $DIR/base.json --json fixtures/effects/hot.c -- -I../include"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":2
      """

  Scenario: The rules run by default
    When I run cchecker with "--json fixtures/effects/short_blocks.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "code":"CC-EFFECT-SHORT-BLOCKS"
      """

  Scenario: A file that clang cannot compile is an error of the rules tool
    When I run cchecker with "--tools rules fixtures/clean.c"
    Then the exit code is 0
    When I run cchecker with "--tools rules --json fixtures/broken.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"rules","file":"fixtures/broken.c",
      """

  Scenario: --clang names the clang to run
    When I run cchecker with "--tools rules --clang no-such-clang --json fixtures/clean.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"rules","file":"fixtures/clean.c",
      """
