Feature: A strict baseline
  An entry of the baseline whose finding is gone stays in the file, and a new finding of the same code, file and
  message would match it later. The summary names each such stale entry of the scope of the run (the tools and files
  it ran), and `--strict-baseline` makes those fail the run. An entry outside the scope never fails it.

  Background:
    Given the C file "leak.c" holds:
      """
      #include "stdlib.h" /* found in the system folders */

      int use_buffer(int n) {
        char *buf = malloc(10);
        if (n > 3) {
          return 1;
        }
        free(buf);
        return 0;
      }
      """
    And the C file "other.c" holds:
      """
      int add(int a, int b) { return a + b; }
      """
    And the file "compile_commands.json" holds:
      """
      [
        {"directory": ".", "command": "cc -c leak.c", "file": "leak.c"},
        {"directory": ".", "command": "cc -c other.c", "file": "other.c"}
      ]
      """
    When I run cchecker in its folder with "-b base.json --update-baseline"
    Then the exit code is 0

  Scenario: A run with no stale entry passes with --strict-baseline
    When I run cchecker in its folder with "--json -b base.json --strict-baseline"
    Then the exit code is 0
    And the output includes:
      """
      "fixed":0,"stale":[]
      """

  Scenario: A stale entry fails the run with --strict-baseline, which names it
    Given the C file "leak.c" holds:
      """
      #include "stdlib.h" /* found in the system folders */

      int use_buffer(int n) {
        char *buf = malloc(10);
        free(buf);
        return n;
      }
      """
    When I run cchecker in its folder with "--json -b base.json --strict-baseline"
    Then the exit code is 1
    And the output includes:
      """
      "clean":false,"findings":[]
      """
    And the output includes:
      """
      {"code":"CC-GCC-ANALYZER-MALLOC-LEAK","file":"leak.c",
      """
    When I run cchecker in its folder with "-b base.json --strict-baseline"
    Then the exit code is 1
    And the output includes:
      """
      leak.c CC-GCC-ANALYZER-MALLOC-LEAK
      """

  Scenario: Without --strict-baseline a stale entry passes, and the summary names it
    Given the C file "leak.c" holds:
      """
      #include "stdlib.h" /* found in the system folders */

      int use_buffer(int n) {
        char *buf = malloc(10);
        free(buf);
        return n;
      }
      """
    When I run cchecker in its folder with "-b base.json"
    Then the exit code is 0
    And the output includes:
      """
      leak.c CC-GCC-ANALYZER-MALLOC-LEAK
      """
    When I run cchecker in its folder with "--json -b base.json"
    Then the exit code is 0
    And the output includes:
      """
      "clean":true,"findings":[]
      """
    And the output includes:
      """
      {"code":"CC-GCC-ANALYZER-MALLOC-LEAK","file":"leak.c",
      """

  Scenario Outline: Only a stale entry of the scope of the run fails it (<case>)
    Given the C file "leak.c" holds:
      """
      #include "stdlib.h" /* found in the system folders */

      int use_buffer(int n) {
        char *buf = malloc(10);
        free(buf);
        return n;
      }
      """
    When I run cchecker in its folder with "--json -b base.json --strict-baseline <options>"
    Then the exit code is <exit>
    And the output <named>:
      """
      {"code":"CC-GCC-ANALYZER-MALLOC-LEAK","file":"leak.c",
      """

    Examples:
      | case                  | options           | exit | named            |
      | the file excluded     | --exclude leak.c  | 0    | does not include |
      | other files           | other.c           | 0    | does not include |
      | another tool          | --tools rules     | 0    | does not include |
      | another file excluded | --exclude other.c | 1    | includes         |
      | the file named        | leak.c            | 1    | includes         |
      | the tool named        | --tools gcc       | 1    | includes         |

  Scenario: A kind found fewer times than the baseline holds is stale for the rest
    Given the C file "twice.c" holds:
      """
      #include "stdlib.h" /* found in the system folders */

      int first(int n) { char *buf = malloc(10); if (n > 3) { return 1; } free(buf); return 0; }
      int second(int n) { char *buf = malloc(10); if (n > 3) { return 1; } free(buf); return 0; }
      """
    When I run cchecker in its folder with "--tools gcc -b twice.json --update-baseline twice.c"
    Then the exit code is 0
    Given the C file "twice.c" holds:
      """
      #include "stdlib.h" /* found in the system folders */

      int first(int n) { char *buf = malloc(10); if (n > 3) { return 1; } free(buf); return 0; }
      int second(int n) { char *buf = malloc(10); free(buf); return n; }
      """
    When I run cchecker in its folder with "--json --tools gcc -b twice.json --strict-baseline twice.c"
    Then the exit code is 1
    And the output includes:
      """
      "baselined":1,"fixed":1,"stale":[{"code":"CC-GCC-ANALYZER-MALLOC-LEAK","file":"twice.c",
      """
    And the output includes:
      """
      "count":1}]
      """

  Scenario Outline: A stale entry of the rules fails the run only with every check of the rules on (<case>)
    Given the C file "tick.c" holds:
      """
      #include "unistd.h" /* found in the system folders */
      #include "cchecker.h"

      CC_SHORT void tick(int fd) { (void)write(fd, "x", 1); }
      """
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "command": "cc -c tick.c -I../../../include", "file": "tick.c"}]
      """
    And the file "less.toml" holds:
      """
      [library]
      libc_blocking = false
      """
    When I run cchecker in its folder with "--tools rules -b rules.json --update-baseline"
    Then the exit code is 0
    Given the C file "tick.c" holds:
      """
      #include "cchecker.h"

      CC_SHORT void tick(int fd) { (void)fd; }
      """
    When I run cchecker in its folder with "--json --tools rules -b rules.json --strict-baseline <options>"
    Then the exit code is <exit>
    And the output includes:
      """
      "stale":[{"code":"CC-EFFECT-SHORT-BLOCKS","file":"tick.c",
      """
    And the errors <warned>:
      """
      --strict-baseline
      """

    Examples:
      | case           | options      | exit | warned         |
      | every check on |              | 1    | do not include |
      | no inference   | --no-infer   | 0    | include        |
      | a library flag | -c less.toml | 0    | include        |
