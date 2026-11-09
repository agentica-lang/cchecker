Feature: A strict baseline
  An entry of the baseline whose finding is gone stays in the file, and a new finding of the same code, file and
  message would match it later. The summary names each such stale entry, and `--strict-baseline` fails a whole run
  (every file of the database, every tool, the default checks) that has one. A partial run never fails on them.

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

  Scenario: A whole run with no stale entry passes with --strict-baseline
    When I run cchecker in its folder with "--json -b base.json --strict-baseline"
    Then the exit code is 0
    And the output includes:
      """
      "fixed":0,"stale":[]
      """

  Scenario: A stale entry fails a whole run with --strict-baseline, which names it
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
    And the output includes:
      """
      --update-baseline
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

  Scenario Outline: A partial run never fails on a stale entry (<case>)
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
    Then the exit code is 0
    And the output includes:
      """
      {"code":"CC-GCC-ANALYZER-MALLOC-LEAK","file":"leak.c",
      """

    Examples:
      | case          | options                        |
      | one tool      | --tools gcc,clang-tidy         |
      | some files    | leak.c other.c                 |
      | an exclude    | --exclude other.c              |
      | other checks  | --checks clang-analyzer-*      |
      | no inference  | --no-infer                     |

  Scenario Outline: --strict-baseline needs a baseline to read, and no update (<case>)
    When I run cchecker in its folder with "<options>"
    Then the exit code is 2
    And the errors include:
      """
      <names>
      """

    Examples:
      | case            | options                                          | names                                |
      | no baseline     | --strict-baseline                                | --strict-baseline needs --baseline   |
      | with the update | -b base.json --update-baseline --strict-baseline | --strict-baseline, --update-baseline |
