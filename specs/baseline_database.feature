Feature: Updating a baseline from a whole compile database
  A run of a whole database covers every file, the headers too. A run that left a file out keeps its entries.

  Background:
    Given the C file "h.h" holds:
      """
      #include <stdlib.h>

      static inline int take(int n) {
        char *p = malloc(10);
        if (n > 3) {
          return 1;
        }
        free(p);
        return 0;
      }
      """
    And the C file "a.c" holds:
      """
      #include "h.h"

      int from_a(void) { return take(1); }
      """
    And the C file "b.c" holds:
      """
      #include <stdlib.h>

      void release_twice(void) {
        int *q = malloc(sizeof *q);
        if (q == NULL) {
          return;
        }
        free(q);
        free(q);
      }
      """
    And the C file "compile_commands.json" holds:
      """
      [
        {"directory": ".", "command": "cc -c a.c", "file": "a.c"},
        {"directory": ".", "command": "cc -c b.c", "file": "b.c"}
      ]
      """
    When I run cchecker with "--tools gcc -p $DIR -b $DIR/base.json --update-baseline"
    Then the exit code is 0

  Scenario: The baseline of a whole database holds the findings of the header and of the other file
    When I run cchecker with "--json --tools gcc -p $DIR -b $DIR/base.json"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":2,"fixed":0
      """

  Scenario: A full update drops a file that left the database and a header that was fixed
    Given the C file "h.h" holds:
      """
      static inline int take(int n) { return n; }
      """
    And the C file "compile_commands.json" holds:
      """
      [
        {"directory": ".", "command": "cc -c a.c", "file": "a.c"}
      ]
      """
    When I run cchecker with "--tools gcc -p $DIR -b $DIR/base.json --update-baseline"
    Then the exit code is 0
    Given the C file "b.c" holds:
      """
      int release_twice(void) { return 0; }
      """
    And the C file "compile_commands.json" holds:
      """
      [
        {"directory": ".", "command": "cc -c a.c", "file": "a.c"},
        {"directory": ".", "command": "cc -c b.c", "file": "b.c"}
      ]
      """
    When I run cchecker with "--json --tools gcc -p $DIR -b $DIR/base.json"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":0,"fixed":0
      """

  Scenario: An update that leaves a file out keeps the entries of that file
    When I run cchecker with "--tools gcc -p $DIR -b $DIR/base.json --update-baseline --exclude $DIR/b.c"
    Then the exit code is 0
    When I run cchecker with "--json --tools gcc -p $DIR -b $DIR/base.json"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":2,"fixed":0
      """

  Scenario: An update of some files of the database keeps the entries of the others
    When I run cchecker with "--tools gcc -b $DIR/base.json --update-baseline $DIR/a.c"
    Then the exit code is 0
    When I run cchecker with "--json --tools gcc -p $DIR -b $DIR/base.json"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":2,"fixed":0
      """

  Scenario: A file that does not compile in a whole database run does not make its accepted findings fixed
    Given the C file "b.c" holds:
      """
      int release_twice(void) { return missing_name; }
      """
    When I run cchecker with "--json --tools gcc -p $DIR -b $DIR/base.json"
    Then the exit code is 2
    And the output includes:
      """
      "findings":[],"baselined":1,"fixed":0
      """
