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

  Scenario Outline: A suppression without a reason or a code is a usage error
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
