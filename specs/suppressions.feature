Feature: Suppressions
  A comment `cchecker: ignore CODE: reason` on the line of a finding, or on the line above it, takes the finding out of
  the report, and CC_IGNORE("CODE", "reason") does it for a finding of the rules on a function. `--json` lists what was
  taken out under `suppressed`, with the reason. A suppression that matches no finding is a finding itself,
  CC-UNUSED-IGNORE.

  Scenario: A comment on the line of the finding suppresses it
    Given the C file "leak.c" holds:
      """
      #include <stdlib.h>

      int use_buffer(int n) {
        char *buf = malloc(10);
        if (n > 3) {
          return 1; /* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: the caller frees it */
        }
        free(buf);
        return 0;
      }
      """
    When I run cchecker with "--tools gcc --json $DIR/leak.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[]
      """
    And the output includes:
      """
      "suppressed":[{"code":"CC-GCC-ANALYZER-MALLOC-LEAK","tool":"gcc",
      """
    And the output includes:
      """
      "reason":"the caller frees it"}]
      """

  Scenario: A comment on the line above the finding suppresses it, and two lines above it does not
    Given the C file "leak.c" holds:
      """
      #include <stdlib.h>

      int use_buffer(int n) {
        char *buf = malloc(10);
        if (n > 3) {
          // cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: the caller frees it
          return 1;
        }
        free(buf);
        return 0;
      }
      """
    When I run cchecker with "--tools gcc $DIR/leak.c"
    Then the exit code is 0
    Given the C file "leak.c" holds:
      """
      #include <stdlib.h>

      int use_buffer(int n) {
        char *buf = malloc(10);
        // cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: the caller frees it
        if (n > 3) {
          return 1;
        }
        free(buf);
        return 0;
      }
      """
    When I run cchecker with "--tools gcc --json $DIR/leak.c"
    Then the exit code is 1
    And the output includes:
      """
      "code":"CC-GCC-ANALYZER-MALLOC-LEAK"
      """
    And the output includes:
      """
      "code":"CC-UNUSED-IGNORE"
      """

  Scenario Outline: A comment takes several codes or a prefix
    Given the C file "leak.c" holds:
      """
      #include "stdlib.h" /* found in the system folders */

      int use_buffer(int n) {
        char *buf = malloc(10);
        if (n > 3) {
          /* cchecker: ignore <codes>: the caller frees it */
          return 1;
        }
        free(buf);
        return 0;
      }
      """
    When I run cchecker with "--tools gcc,clang-tidy --json $DIR/leak.c"
    Then the exit code is <code>

    Examples:
      | codes                                                           | code |
      | CC-GCC-ANALYZER-MALLOC-LEAK, CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC | 0    |
      | CC-GCC-ANALYZER-*, CC-TIDY-CLANG-ANALYZER-*                     | 0    |
      | CC-GCC-ANALYZER-MALLOC-LEAK                                     | 1    |

  Scenario: A trailing comment holds for its own line only, and each one gets its finding
    Given the C file "leaks.c" holds:
      """
      #include <stdlib.h>
      void f1(void) { char *x = malloc(1); } // cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: one
      void f2(void) { char *x = malloc(1); } // cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: two
      """
    When I run cchecker with "--tools gcc --json $DIR/leaks.c"
    Then the exit code is 0
    And the output includes:
      """
      "line":3,"column":
      """
    And the output includes:
      """
      "reason":"two"}]
      """
    Given the C file "leaks.c" holds:
      """
      #include <stdlib.h>
      void f1(void) { char *x = malloc(1); } // cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: one
      void f2(void) { char *x = malloc(1); }
      """
    When I run cchecker with "--tools gcc --json $DIR/leaks.c"
    Then the exit code is 1
    And the output includes:
      """
      "line":3,"column":38,"message":"leak of 'x'","path":[],"source":"","root":""}]
      """

  Scenario: The marker in a string or in a comment that only mentions it is no suppression
    Given the C file "notes.c" holds:
      """
      #include <stdio.h>

      /* Write "cchecker: ignore CODE: reason" next to a false positive. */
      void hint(void) { puts("cchecker: ignore CODE: reason"); }
      """
    When I run cchecker with "--tools gcc --json $DIR/notes.c"
    Then the exit code is 0

  Scenario Outline: A suppression without a reason, a code or a code of a tool is a usage error
    Given the C file "leak.c" holds:
      """
      #include "stdlib.h" /* found in the system folders */

      int use_buffer(int n) {
        char *buf = malloc(10);
        if (n > 3) {
          <comment>
          return 1;
        }
        free(buf);
        return 0;
      }
      """
    When I run cchecker with "--tools gcc $DIR/leak.c"
    Then the exit code is <code>

    Examples:
      | comment                                                      | code |
      | /* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: a reason */ | 0    |
      | /* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK */           | 2    |
      | /* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: */          | 2    |
      | /* cchecker: ignore : a reason */                            | 2    |
      | /* cchecker: ignore    CC-GCC-ANALYZER-MALLOC-LEAK: spaces */ | 0    |
      | /* cchecker: ignore CC-GCCC-ANALYZER-MALLOC-LEAK: a reason */ | 2    |
      | /// cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: doc comment  | 0    |
      | //! cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: doc comment  | 0    |
      | // cchecker: ignore: a reason                                | 2    |
      | // cchecker: ignore,CC-GCC-ANALYZER-MALLOC-LEAK: a reason    | 2    |
      | // cchecker: ignored CC-GCC-ANALYZER-MALLOC-LEAK: a reason   | 2    |
      | // cchecker: ignore CC-GCC-*-LEAK: a star inside a code      | 2    |
      | // cchecker: ignore CC-UNUSED-IGNORE: the unused code        | 2    |

  Scenario: A suppression that matches no finding is a finding
    Given the C file "clean.c" holds:
      """
      int add(int a, int b) {
        /* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: left from an old version */
        return a + b;
      }
      """
    When I run cchecker with "--tools gcc --json $DIR/clean.c"
    Then the exit code is 1
    And the output includes:
      """
      "code":"CC-UNUSED-IGNORE","tool":"gcc",
      """
    And the output includes:
      """
      "line":2,"column":6,
      """

  Scenario: A suppression for a tool that did not run is not unused
    Given the C file "clean.c" holds:
      """
      int add(int a, int b) {
        /* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: left from an old version */
        return a + b;
      }
      """
    When I run cchecker with "--tools clang-tidy --json $DIR/clean.c"
    Then the exit code is 0

  Scenario Outline: CC_IGNORE on a function suppresses a finding of the rules on it
    Given the C file "hot.c" holds:
      """
      #include "stdlib.h" /* found in the system folders */
      #include "cchecker.h"

      <ignore>
      CC_HOT void *grab(size_t n);

      void *grab(size_t n) { return malloc(n); }
      """
    And the C file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "hot.c", "arguments": ["cc", "-I../../../include", "-c", "hot.c"]}]
      """
    When I run cchecker with "--tools rules --json -p $DIR"
    Then the exit code is <code>
    And the output includes:
      """
      <expected>
      """

    Examples:
      | ignore                                                         | code | expected                    |
      | CC_IGNORE("CC-EFFECT-HOT-ALLOCATES", "the pool is warm")       | 0    | "reason":"the pool is warm" |
      | CC_IGNORE("CC-EFFECT-HOT-SYSCALL", "never a system call here") | 1    | "code":"CC-UNUSED-IGNORE"   |

  Scenario: CC_IGNORE suppresses a finding whose path goes through a table whose first item is a null pointer
    Given the C file "nulls.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      static int slow(int x) { sleep(1); return x; }
      static int (*table[])(int) = {0, slow};
      CC_IGNORE("CC-EFFECT-SHORT-BLOCKS", "only at startup") CC_SHORT int entry(int i) { return table[i](i); }
      """
    When I run cchecker with "--tools rules --json $DIR/nulls.c -- -I../include"
    Then the exit code is 0
    And the output includes:
      """
      "reason":"only at startup"
      """

  Scenario: A CC_IGNORE that matched nothing in a run of some files is not unused: the run saw part of the graph
    Given the C file "hot.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"

      CC_IGNORE("CC-EFFECT-HOT-SYSCALL", "never a system call here") CC_HOT int add(int a, int b) { return a + b; }
      """
    When I run cchecker with "--tools rules --json $DIR/hot.c -- -I../include"
    Then the exit code is 0

  Scenario: CC_IGNORE without a reason is a usage error
    Given the C file "hot.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"

      CC_IGNORE("CC-EFFECT-HOT-ALLOCATES", "") CC_HOT void *grab(size_t n) { return malloc(n); }
      """
    When I run cchecker with "--tools rules $DIR/hot.c -- -I../include"
    Then the exit code is 2

  Scenario Outline: CC_IGNORE takes only codes of the rules
    Given the C file "hot.c" holds:
      """
      #include "stdlib.h" /* found in the system folders */
      #include "cchecker.h"

      CC_IGNORE("<code>", "a reason") CC_HOT void *grab(size_t n) { return malloc(n); }
      """
    When I run cchecker with "--tools rules $DIR/hot.c -- -I../include"
    Then the exit code is <exit>

    Examples:
      | code                        | exit |
      | CC-EFFECT-HOT-ALLOCATES     | 0    |
      | CC-EFFECT-*                 | 0    |
      | CC-GCC-ANALYZER-MALLOC-LEAK | 2    |
      | CC-TIDY-*                   | 2    |

  Scenario: CC_IGNORE on the prototype in a header suppresses the finding of the definition
    Given the C file "pool.h" holds:
      """
      #include <stddef.h>
      #include "cchecker.h"

      CC_IGNORE("CC-EFFECT-HOT-ALLOCATES", "the pool is warm") CC_HOT void *grab(size_t n);
      """
    And the C file "pool.c" holds:
      """
      #include <stdlib.h>
      #include "pool.h"

      void *grab(size_t n) { return malloc(n); }
      """
    And the C file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "pool.c", "arguments": ["cc", "-I../../../include", "-c", "pool.c"]}]
      """
    When I run cchecker with "--tools rules --json -p $DIR"
    Then the exit code is 0
    And the output includes:
      """
      "reason":"the pool is warm"
      """

  Scenario: A suppression in a file that does not compile is not unused, and the run is a tool error
    Given the C file "broken.c" holds:
      """
      #include "cchecker.h"

      /* cchecker: ignore CC-EFFECT-SHORT-BLOCKS: kept for later */
      CC_IGNORE("CC-EFFECT-HOT-SYSCALL", "kept for later") CC_SHORT int f(void) { return missing; }
      """
    And the C file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "broken.c", "arguments": ["cc", "-I../../../include", "-c", "broken.c"]}]
      """
    When I run cchecker with "--tools rules --json -p $DIR"
    Then the exit code is 2
    And the output does not include:
      """
      CC-UNUSED-IGNORE
      """

  Scenario: A suppressed finding never goes into the baseline
    Given the C file "leak.c" holds:
      """
      #include <stdlib.h>

      int use_buffer(int n) {
        char *buf = malloc(10);
        if (n > 3) {
          return 1; /* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: the caller frees it */
        }
        free(buf);
        return 0;
      }
      """
    When I run cchecker with "--tools gcc -b $DIR/base.json --update-baseline $DIR/leak.c"
    Then the exit code is 0
    Given the C file "leak.c" holds:
      """
      #include <stdlib.h>

      int use_buffer(int n) {
        char *buf = malloc(10);
        if (n > 3) {
          return 1;
        }
        free(buf);
        return 0;
      }
      """
    When I run cchecker with "--tools gcc -b $DIR/base.json --json $DIR/leak.c"
    Then the exit code is 1
    And the output includes:
      """
      "baselined":0
      """

  Scenario: An unused suppression never goes into the baseline
    Given the C file "clean.c" holds:
      """
      int add(int a, int b) {
        /* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: left from an old version */
        return a + b;
      }
      """
    When I run cchecker with "--tools gcc -b $DIR/base.json --update-baseline $DIR/clean.c"
    Then the exit code is 0
    When I run cchecker with "--tools gcc -b $DIR/base.json --json $DIR/clean.c"
    Then the exit code is 1
    And the output includes:
      """
      "code":"CC-UNUSED-IGNORE"
      """
    And the output includes:
      """
      "baselined":0
      """
