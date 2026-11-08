Feature: Running the analyzers on C files
  cchecker runs gcc -fanalyzer and clang-tidy on each file and prints what they find in one format. The exit code is 0
  for no new findings, 1 for new ones and 2 for a usage or tool error.

  Scenario: A file without findings passes
    When I run cchecker with "fixtures/clean.c"
    Then the exit code is 0

  Scenario Outline: A tool finds a bug and its finding has a stable code
    When I run cchecker with "--tools <tool> fixtures/<file>"
    Then the exit code is 1
    And the output includes:
      """
      <code>
      """

    Examples:
      | tool       | file          | code                                |
      | gcc        | leak.c        | CC-GCC-ANALYZER-MALLOC-LEAK         |
      | gcc        | double_free.c | CC-GCC-ANALYZER-DOUBLE-FREE         |
      | clang-tidy | leak.c        | CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC  |
      | clang-tidy | tidy_only.c   | CC-TIDY-BUGPRONE-INTEGER-DIVISION   |

  Scenario: Both tools run by default and report the place of the bug
    When I run cchecker with "fixtures/leak.c"
    Then the exit code is 1
    And the output includes:
      """
      fixtures/leak.c:9:12 CC-GCC-ANALYZER-MALLOC-LEAK
      """
    And the output includes:
      """
      fixtures/leak.c:9:12 CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC
      """

  Scenario: A tool that was not asked for does not run
    When I run cchecker with "--tools gcc fixtures/tidy_only.c"
    Then the exit code is 0

  Scenario: The checks of clang-tidy are the ones asked for
    When I run cchecker with "--tools clang-tidy --checks=-*,bugprone-sizeof-expression fixtures/tidy_only.c"
    Then the exit code is 0

  Scenario: A check that is not in the default set runs when it is asked for
    When I run cchecker with "--tools clang-tidy fixtures/branch_clone.c"
    Then the exit code is 0
    When I run cchecker with "--tools clang-tidy --checks=-*,bugprone-branch-clone fixtures/branch_clone.c"
    Then the exit code is 1
    And the output includes:
      """
      CC-TIDY-BUGPRONE-BRANCH-CLONE
      """

  Scenario: The flags after -- reach the tools
    When I run cchecker with "fixtures/flags.c"
    Then the exit code is 0
    When I run cchecker with "fixtures/flags.c -- -DLEAK"
    Then the exit code is 1
    And the output includes:
      """
      CC-GCC-ANALYZER-MALLOC-LEAK
      """

  Scenario: The findings are JSON for tools and agents
    When I run cchecker with "--json --tools gcc fixtures/leak.c"
    Then the exit code is 1
    And the output includes:
      """
      "clean":false
      """
    And the output includes:
      """
      {"code":"CC-GCC-ANALYZER-MALLOC-LEAK","tool":"gcc","file":"fixtures/leak.c","line":9,"column":12,
      """

  Scenario: A clean run is clean in JSON too
    When I run cchecker with "--json fixtures/clean.c"
    Then the exit code is 0
    And the output includes:
      """
      "clean":true,"findings":[],"baselined":0,"fixed":0,"errors":[]
      """

  Scenario: A compile database names the files and their flags
    When I run cchecker with "-p fixtures"
    Then the exit code is 1
    And the output includes:
      """
      fixtures/leak.c:9:12 CC-GCC-ANALYZER-MALLOC-LEAK
      """
    And the output includes:
      """
      fixtures/tidy_only.c:2:17 CC-TIDY-BUGPRONE-INTEGER-DIVISION
      """
    And the output does not include:
      """
      fixtures/clean.c
      """

  Scenario: A file that does not compile is a tool error, not a finding
    When I run cchecker with "--json fixtures/broken.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"gcc","file":"fixtures/broken.c"
      """

  Scenario: Excluded paths are skipped
    When I run cchecker with "--exclude fixtures/leak fixtures/leak.c fixtures/clean.c"
    Then the exit code is 0

  Scenario: A tool that is not installed is a tool error
    When I run cchecker with "--tools gcc --gcc no-such-gcc fixtures/clean.c"
    Then the exit code is 2

  Scenario Outline: A wrong command line is a usage error
    When I run cchecker with "<arguments>"
    Then the exit code is 2

    Examples:
      | arguments                                  |
      |                                            |
      | --tools lint fixtures/clean.c              |
      | --update-baseline fixtures/clean.c         |
      | --jobs 0 fixtures/clean.c                  |
      | -p fixtures fixtures/clean.c               |
      | -- -DLEAK                                  |

  Scenario: A bug in a header that several files include is reported once
    When I run cchecker with "--json --tools gcc fixtures/uses_a.c fixtures/uses_b.c"
    Then the exit code is 1
    And the output includes:
      """
      "findings":[{"code":"CC-GCC-ANALYZER-MALLOC-LEAK","tool":"gcc","file":"fixtures/shared.h","line":6,"column":12,"message":"leak of 'p'"}],"baselined":0
      """
