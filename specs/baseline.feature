Feature: The baseline
  A baseline holds the findings a project accepts, so that a run fails only on new ones. A finding matches by its code,
  its file and its message, not by its line.

  Background:
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
    When I run cchecker with "--tools gcc --baseline $DIR/base.json --update-baseline $DIR/leak.c"
    Then the exit code is 0

  Scenario: The accepted findings do not fail the run
    When I run cchecker with "--tools gcc --baseline $DIR/base.json --json $DIR/leak.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":1,"fixed":0
      """

  Scenario: Without the baseline the same file fails
    When I run cchecker with "--tools gcc $DIR/leak.c"
    Then the exit code is 1

  Scenario: A finding that moved to another line is still accepted
    Given the C file "leak.c" holds:
      """
      #include <stdlib.h>
      /* three lines */
      /* that move */
      /* the leak */

      int use_buffer(int n) {
        char *buf = malloc(10);
        if (n > 3) {
          return 1;
        }
        free(buf);
        return 0;
      }
      """
    When I run cchecker with "--tools gcc --baseline $DIR/base.json --json $DIR/leak.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":1
      """

  Scenario: A new finding fails the run and the accepted one stays quiet
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

      void twice(void) {
        int *p = malloc(sizeof *p);
        if (p == NULL) {
          return;
        }
        free(p);
        free(p);
      }
      """
    When I run cchecker with "--tools gcc --baseline $DIR/base.json --json $DIR/leak.c"
    Then the exit code is 1
    And the output includes:
      """
      CC-GCC-ANALYZER-DOUBLE-FREE
      """
    And the output does not include:
      """
      CC-GCC-ANALYZER-MALLOC-LEAK
      """
    And the output includes:
      """
      "baselined":1
      """

  Scenario: A second finding of the same kind is new even though the baseline holds one
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

      int use_other_buffer(int n) {
        char *buf = malloc(20);
        if (n > 3) {
          return 1;
        }
        free(buf);
        return 0;
      }
      """
    When I run cchecker with "--tools gcc --baseline $DIR/base.json --json $DIR/leak.c"
    Then the exit code is 1
    And the output includes:
      """
      "baselined":1
      """

  Scenario: A finding that was fixed is counted
    Given the C file "leak.c" holds:
      """
      #include <stdlib.h>

      int use_buffer(int n) {
        char *buf = malloc(10);
        free(buf);
        return n;
      }
      """
    When I run cchecker with "--tools gcc --baseline $DIR/base.json --json $DIR/leak.c"
    Then the exit code is 0
    And the output includes:
      """
      "baselined":0,"fixed":1
      """

  Scenario: A baseline that is not there is an error
    When I run cchecker with "--tools gcc --baseline $DIR/missing.json $DIR/leak.c"
    Then the exit code is 2

  Scenario: Updating the baseline refuses a run where a tool failed
    When I run cchecker with "--tools gcc --gcc no-such-gcc --baseline $DIR/other.json --update-baseline $DIR/leak.c"
    Then the exit code is 2
