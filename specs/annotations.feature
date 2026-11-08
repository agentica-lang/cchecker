Feature: The annotation header
  include/cchecker.h defines the macros that mark the rules of a project. clang keeps them in its AST, and every other
  compiler sees nothing.

  Scenario: clang keeps each annotation as an annotate attribute
    When clang dumps the AST of "fixtures/annotated.c"
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
