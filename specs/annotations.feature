Feature: The annotation header
  include/cchecker.h defines the macros that mark the rules of a project. They expand to something only while cchecker
  dumps the AST (CCHECKER_AST, clang); in every other build, with any compiler, they are empty.

  Scenario: clang keeps each annotation in the AST dump of the rules
    When clang dumps the AST of "fixtures/annotated.c" with CCHECKER_AST
    Then the exit code is 0
    And the output includes:
      """
      "cchecker:short"
      """
    And the output includes:
      """
      "cchecker:blocking"
      """
    And the output includes:
      """
      "cchecker:hot"
      """
    And the output includes:
      """
      "cchecker:owns"
      """
    And the output includes:
      """
      "cchecker:pair(mask_signals, restore_signals)"
      """
    And the output includes:
      """
      "cchecker:no_syscall_under(table_lock)"
      """
    And the output includes:
      """
      "cchecker:may_jump"
      """
    And the output includes:
      """
      "cchecker:noreturn"
      """
    And the output includes:
      """
      "cchecker:stop"
      """

  Scenario: A normal clang compile carries no annotation
    When clang preprocesses "fixtures/annotated.c"
    Then the exit code is 0
    And the output includes:
      """
      int next_id(void);
      """
    And the output does not include:
      """
      annotate("
      """
    And the output does not include:
      """
      cchecker:
      """
    And the output does not include:
      """
      deprecated
      """

  Scenario: The rules still find a finding on a marked file
    Given the C file "mark.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      int f(int n) { CC_OWNS char *b = malloc(n); if (n > 3) return 1; free(b); return 0; }
      """
    When I run cchecker with "--tools rules --json $DIR/mark.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "code":"CC-OWN-LEAK"
      """

  Scenario: A marked file that frees its pointer on every path has no finding
    Given the C file "mark.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      int f(int n) { CC_OWNS char *b = malloc(n); if (n > 3) { free(b); return 1; } free(b); return 0; }
      """
    When I run cchecker with "--tools rules --json $DIR/mark.c -- -I../include"
    Then the exit code is 0
    And the output does not include:
      """
      CC-OWN-LEAK
      """

  Scenario Outline: The macros are empty for gcc, in every C standard
    When I run cchecker with "--tools gcc fixtures/annotated.c -- -I../include -std=<standard> -Wall -pedantic-errors"
    Then the exit code is 0

    Examples:
      | standard |
      | c99      |
      | c11      |
      | gnu17    |

  Scenario: clang-tidy reads the annotated file without findings
    When I run cchecker with "--tools clang-tidy fixtures/annotated.c -- -I../include"
    Then the exit code is 0
