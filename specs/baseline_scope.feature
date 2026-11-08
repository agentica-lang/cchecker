Feature: What a baseline covers
  A run covers the tools and the files it ran. It counts as fixed only the accepted findings of those, and an update
  keeps the entries of the rest.

  Background:
    Given the C file "a.c" holds:
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
    And the C file "b.c" holds:
      """
      #include <stdlib.h>

      void release_twice(void) {
        int *p = malloc(sizeof *p);
        if (p == NULL) {
          return;
        }
        free(p);
        free(p);
      }
      """
    When I run cchecker with "--baseline $DIR/base.json --update-baseline $DIR/a.c $DIR/b.c"
    Then the exit code is 0
    And the file "$DIR/base.json" exists
    And the file "$DIR/base.json.tmp" does not exist

  Scenario: Both tools and both files are in the baseline
    When I run cchecker with "--json --baseline $DIR/base.json $DIR/a.c $DIR/b.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":4,"fixed":0
      """

  Scenario: A run with one tool does not count the findings of the other as fixed
    When I run cchecker with "--json --tools gcc --baseline $DIR/base.json $DIR/a.c $DIR/b.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":2,"fixed":0
      """

  Scenario: A run with one file does not count the findings of the other as fixed
    When I run cchecker with "--json --baseline $DIR/base.json $DIR/a.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":2,"fixed":0
      """

  Scenario: Updating with one tool keeps the entries of the other
    When I run cchecker with "--tools gcc --baseline $DIR/base.json --update-baseline $DIR/a.c $DIR/b.c"
    Then the exit code is 0
    When I run cchecker with "--json --baseline $DIR/base.json $DIR/a.c $DIR/b.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":4,"fixed":0
      """

  Scenario: Updating with one file keeps the entries of the other and drops those of a fixed finding
    Given the C file "a.c" holds:
      """
      int use_buffer(int n) { return n; }
      """
    When I run cchecker with "--baseline $DIR/base.json --update-baseline $DIR/a.c"
    Then the exit code is 0
    When I run cchecker with "--json --baseline $DIR/base.json $DIR/a.c $DIR/b.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":2,"fixed":0
      """

  Scenario: A baseline cannot be updated with other checks than the default ones
    When I run cchecker with "--checks=-*,bugprone-integer-division -b $DIR/base.json --update-baseline $DIR/a.c"
    Then the exit code is 2
    When I run cchecker with "--json --baseline $DIR/base.json $DIR/a.c $DIR/b.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":4,"fixed":0
      """

  Scenario: A failed run leaves the baseline as it was
    When I run cchecker with "--gcc no-such-gcc --baseline $DIR/base.json --update-baseline $DIR/a.c $DIR/b.c"
    Then the exit code is 2
    When I run cchecker with "--json --baseline $DIR/base.json $DIR/a.c $DIR/b.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":4,"fixed":0
      """

  Scenario: A file that does not compile is not accepted by an update
    Given the C file "c.c" holds:
      """
      int call_missing(void) { return undeclared_function(1); }
      """
    When I run cchecker with "--tools gcc --baseline $DIR/base.json --update-baseline $DIR/c.c"
    Then the exit code is 2
    When I run cchecker with "--json --baseline $DIR/base.json $DIR/a.c $DIR/b.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":4,"fixed":0
      """

  Scenario: A baseline that cannot be read is found before any tool runs
    Given the file "scratch/ran.marker" is removed
    When I run cchecker with "--tools gcc --gcc fixtures/fake_gcc_marker.sh -b $DIR/missing.json fixtures/clean.c"
    Then the exit code is 2
    And the file "scratch/ran.marker" does not exist
    When I run cchecker with "--tools gcc --gcc fixtures/fake_gcc_marker.sh fixtures/clean.c"
    Then the exit code is 0
    And the file "scratch/ran.marker" exists

  Scenario: A job that failed does not make its accepted findings fixed
    Given the C file "b.c" holds:
      """
      int release_twice(void) { return missing_name; }
      """
    When I run cchecker with "--json --baseline $DIR/base.json $DIR/a.c $DIR/b.c"
    Then the exit code is 2
    And the output includes:
      """
      "findings":[],"baselined":2,"fixed":0
      """

  Scenario: An update from a database with files outside the working directory is refused
    Given the C file "old.json" holds:
      """
      {
        "version": 1,
        "findings": [
          {"code": "CC-GCC-ANALYZER-MALLOC-LEAK", "file": "fixtures/leak.c", "message": "leak of 'buf'", "count": 1}
        ]
      }
      """
    When I run cchecker with "--tools gcc -p fixtures/outside -b $DIR/old.json --update-baseline"
    Then the exit code is 2
    When I run cchecker with "--json --tools gcc -b $DIR/old.json fixtures/leak.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":1,"fixed":0
      """

  Scenario: An update with the flags that show another finding of a header keeps the first one
    Given the C file "h.h" holds:
      """
      #include <stdlib.h>
      #ifdef X
      #define NAME pa
      #else
      #define NAME pb
      #endif

      static inline int take(int n) {
        char *NAME = malloc(10);
        if (n > 3) {
          return 1;
        }
        free(NAME);
        return 0;
      }
      """
    And the C file "uses.c" holds:
      """
      #include "h.h"

      int from_uses(void) { return take(1); }
      """
    When I run cchecker with "--tools gcc -b $DIR/header.json --update-baseline $DIR/uses.c"
    Then the exit code is 0
    When I run cchecker with "--tools gcc -b $DIR/header.json --update-baseline $DIR/uses.c -- -DX"
    Then the exit code is 0
    When I run cchecker with "--json --tools gcc -b $DIR/header.json $DIR/uses.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":1,"fixed":0
      """
    When I run cchecker with "--json --tools gcc -b $DIR/header.json $DIR/uses.c -- -DX"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":1,"fixed":0
      """
