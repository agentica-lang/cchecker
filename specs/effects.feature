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

  Scenario Outline: More ways to store or call a function reach it
    When I run cchecker with "--tools rules --json fixtures/effects/<file> -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":[<path>]
      """

    Examples:
      | file                        | path                           |
      | pointer_conditional.c       | "entry","slow","sleep"         |
      | pointer_const_table.c       | "entry","slow","sleep"         |
      | pointer_union.c             | "entry","slow","sleep"         |
      | pointer_anonymous_union.c   | "entry","slow","sleep"         |
      | pointer_bitfield.c          | "entry","slow","sleep"         |
      | cleanup.c                   | "entry","release","sleep"      |
      | pasted_name.c               | "entry","wait_ready","sleep"   |
      | pasted_struct.c             | "entry","slow","sleep"         |
      | deprecated_too.c            | "entry","slow","sleep"         |
      | cast_void_pointer.c         | "entry","slow","sleep"         |
      | cast_void_array.c           | "entry","slow","sleep"         |
      | cast_integer.c              | "entry","slow","sleep"         |

  Scenario: Fields of the same name in the anonymous unions of two structs are two places
    When I run cchecker with "--tools rules fixtures/effects/pointer_anonymous_twin.c -- -I../include"
    Then the exit code is 0

  Scenario: A static function declared in a shared header is the one each file defines
    When I run cchecker with "--tools rules fixtures/effects/shared_a.c fixtures/effects/shared_b.c -- -I../include"
    Then the exit code is 0

  Scenario Outline: The known calls are spelled right
    Given the C file "known.c" holds:
      """
      #include "cchecker.h"

      int <name>();
      <mark> int entry(void) { return <name>(); }
      """
    When I run cchecker with "--tools rules --json $DIR/known.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "code":"<code>"
      """

    Examples:
      | name                 | mark     | code                    |
      | uv_mutex_lock        | CC_SHORT | CC-EFFECT-SHORT-BLOCKS  |
      | uv_fs_fsync          | CC_SHORT | CC-EFFECT-SHORT-BLOCKS  |
      | pthread_cond_wait    | CC_SHORT | CC-EFFECT-SHORT-BLOCKS  |
      | GC_gcollect          | CC_SHORT | CC-EFFECT-SHORT-BLOCKS  |
      | free                 | CC_HOT   | CC-EFFECT-HOT-ALLOCATES |
      | GC_malloc            | CC_HOT   | CC-EFFECT-HOT-ALLOCATES |
      | SSL_new              | CC_HOT   | CC-EFFECT-HOT-ALLOCATES |
      | mmap                 | CC_HOT   | CC-EFFECT-HOT-SYSCALL   |
      | pthread_mutex_unlock | CC_HOT   | CC-EFFECT-HOT-SYSCALL   |

  Scenario: A large table of numbers is left out of the graph, and the rest of the file is checked
    Given the C file "table.c" holds, with ITEMS as 100000 times "7,":
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      static const unsigned char TABLE[] = {ITEMS};
      CC_SHORT int entry(int i) { return TABLE[i] + (int)sleep(1); }
      """
    When I run cchecker with "--tools rules --json $DIR/table.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["entry","sleep"]
      """

  Scenario: A declaration too large to keep is a tool error, and the rest of the file is checked
    Given the C file "ops.c" holds, with ITEMS as 30000 times "{1, quick},":
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      static int quick(int x) { return x; }
      struct op { int n; int (*run)(int); };
      static const struct op OPS[] = {ITEMS};
      CC_SHORT int entry(int i) { return OPS[i].run(i) + (int)sleep(1); }
      """
    When I run cchecker with "--tools rules --json $DIR/ops.c -- -I../include"
    Then the exit code is 2
    And the output includes:
      """
      "path":["entry","sleep"]
      """
    And the output includes:
      """
      "errors":[{"tool":"rules",
      """

  Scenario: A table of typedef'd numbers is left out by its items
    Given the C file "rom.c" holds, with ITEMS as 30000 times "7,":
      """
      #include <stdint.h>
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      static const uint8_t ROM[] = {ITEMS};
      CC_SHORT int entry(int i) { return ROM[i] + (int)sleep(1); }
      """
    When I run cchecker with "--tools rules --json $DIR/rom.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["entry","sleep"]
      """
    And the output includes:
      """
      "skipped_declarations":0
      """

  Scenario Outline: A table of functions whose first item is a null pointer is followed
    Given the C file "nulls.c" holds:
      """
      #define NULL 0
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      typedef int (*fn)(int);
      static int slow(int x) { sleep(1); return x; }
      <table>
      CC_SHORT int entry(int i) { return <call>; }
      """
    When I run cchecker with "--tools rules --json $DIR/nulls.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["entry","slow","sleep"]
      """

    Examples:
      | table                                         | call              |
      | static int (*table[])(int) = {0, slow};       | table[i](i)       |
      | static int (*const table[])(int) = {0, slow}; | table[i](i)       |
      | static fn table[] = {0, slow};                | table[i](i)       |
      | static const fn table[] = {0, slow};          | table[i](i)       |
      | static fn table[] = {NULL, slow};             | table[i](i)       |
      | static void *table[] = {0, (void *)slow};     | ((fn)table[i])(i) |

  Scenario Outline: A declaration too large to keep that names no function is skipped and counted
    Given the C file "big.c" holds, with ITEMS as <count> times "<item>":
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      enum color { RED, GREEN };
      struct point { int x; int y; };
      static const <type> BIG[] = {ITEMS};
      CC_SHORT int entry(int i) { return (int)sizeof BIG[i] + (int)sleep(1); }
      """
    When I run cchecker with "--tools rules --json $DIR/big.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["entry","sleep"]
      """
    And the output includes:
      """
      "skipped_declarations":1
      """

    Examples:
      | type         | count | item    |
      | enum color   | 60000 | GREEN,  |
      | struct point | 30000 | {1, 2}, |

  Scenario Outline: A call of libuv's file functions blocks when it has no callback
    Given the C file "fs.c" holds:
      """
      #include "cchecker.h"

      typedef void (*fs_cb)(void *req);
      int uv_fs_open(void *loop, void *req, const char *path, int flags, int mode, fs_cb cb);
      static void opened(void *req) { (void)req; }
      CC_SHORT int entry(void *loop, void *req) { return uv_fs_open(loop, req, "x", 0, 0, <callback>); }
      """
    When I run cchecker with "--tools rules $DIR/fs.c -- -I../include"
    Then the exit code is <code>

    Examples:
      | callback | code |
      | 0        | 1    |
      | (fs_cb)0 | 1    |
      | opened   | 0    |

  Scenario: A dump that ends early is an error of the rules tool
    When I run cchecker with "--tools rules --clang fixtures/fake_clang_truncated.sh --json fixtures/clean.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"rules","file":"fixtures/clean.c",
      """

  Scenario: The folder of a run that was killed is removed by the next run
    Given there is a private folder "$DIR/tmp/cchecker-999999999-1" holding "0.json"
    When I run cchecker with "--tools rules fixtures/effects/short_blocks.c -- -I../include" and TMPDIR "$DIR/tmp"
    Then the exit code is 1
    And the folder "$DIR/tmp" is empty

  Scenario: Only a folder of a dead run of this user that holds dumps alone is removed
    Given there is a private folder "$DIR/tmp/cchecker-$PID-1" holding "0.json"
    And there is a private folder "$DIR/tmp/cchecker-abc-1" holding "0.json"
    And there is a private folder "$DIR/tmp/cchecker-999999999-2" holding "notes.txt"
    And there is a folder "$DIR/tmp/cchecker-999999999-3" holding "0.json"
    When I run cchecker with "--tools rules fixtures/effects/short_blocks.c -- -I../include" and TMPDIR "$DIR/tmp"
    Then the exit code is 1
    And the file "$DIR/tmp/cchecker-$PID-1" exists
    And the file "$DIR/tmp/cchecker-abc-1" exists
    And the file "$DIR/tmp/cchecker-999999999-2" exists
    And the file "$DIR/tmp/cchecker-999999999-3" exists

  Scenario: A relative TMPDIR holds for a compile database whose files are in another folder
    Given the C file "sub/a.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      CC_SHORT int entry(void) { return (int)sleep(1); }
      """
    And the C file "compile_commands.json" holds:
      """
      [{"directory": "sub", "file": "a.c", "arguments": ["cc", "-I../../../../include", "-c", "a.c"]}]
      """
    When I run cchecker with "--tools rules -p $DIR" and TMPDIR "$DIR/tmp"
    Then the exit code is 1

  Scenario: The AST dumps are removed at the end of the run
    When I run cchecker with "--tools rules fixtures/effects/short_blocks.c -- -I../include" and TMPDIR "$DIR/tmp"
    Then the exit code is 1
    And the folder "$DIR/tmp" is empty

  Scenario: The findings of the rules go into the baseline, and a run of the whole database counts them fixed
    Given the C file "hot.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"

      CC_HOT void *grab(size_t n) { return malloc(n); }
      """
    And the C file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "hot.c", "arguments": ["cc", "-I../../../include", "-c", "hot.c"]}]
      """
    When I run cchecker with "--tools rules -b $DIR/base.json --update-baseline -p $DIR"
    Then the exit code is 0
    When I run cchecker with "--tools rules -b $DIR/base.json --json -p $DIR"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":1,"fixed":0
      """
    Given the C file "hot.c" holds:
      """
      #include "cchecker.h"

      CC_HOT int grab(int n) { return n; }
      """
    When I run cchecker with "--tools rules -b $DIR/base.json --json -p $DIR"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":0,"fixed":1
      """

  Scenario: An update of the baseline on one file of two keeps the findings of the rules
    Given the C file "a.c" holds:
      """
      #include "cchecker.h"

      int helper(void);
      CC_SHORT int top(void) { return helper(); }
      """
    And the C file "b.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      int helper(void) { return (int)sleep(1); }
      """
    When I run cchecker with "--tools rules -b $DIR/base.json --update-baseline $DIR/a.c $DIR/b.c -- -I../include"
    Then the exit code is 0
    When I run cchecker with "--tools rules -b $DIR/base.json --json $DIR/a.c -- -I../include"
    Then the exit code is 0
    And the output includes:
      """
      "fixed":0
      """
    When I run cchecker with "--tools rules -b $DIR/base.json --update-baseline $DIR/a.c -- -I../include"
    Then the exit code is 0
    When I run cchecker with "--tools rules -b $DIR/base.json --json $DIR/a.c $DIR/b.c -- -I../include"
    Then the exit code is 0
    And the output includes:
      """
      "baselined":1
      """

  Scenario: The baseline holds a finding of the rules whose call path changed
    Given the C file "short.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      static int helper(void) { return (int)sleep(1); }
      CC_SHORT int top(void) { return helper(); }
      """
    When I run cchecker with "--tools rules -b $DIR/base.json --update-baseline $DIR/short.c -- -I../include"
    Then the exit code is 0
    Given the C file "short.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      static int renamed_helper(void) { return (int)sleep(1); }
      CC_SHORT int top(void) { return renamed_helper(); }
      """
    When I run cchecker with "--tools rules -b $DIR/base.json --json $DIR/short.c -- -I../include"
    Then the exit code is 0
    And the output includes:
      """
      "baselined":1
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
