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
      "clean":true,"findings":[],"baselined":0,"fixed":0,"errors":[],"skipped":0
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
    And the output includes:
      """
      fixtures/flags.c:11:12 CC-GCC-ANALYZER-MALLOC-LEAK
      """
    And the output does not include:
      """
      fixtures/clean.c
      """

  Scenario: The number of runs at once is bounded by --jobs
    When I run cchecker with "--tools gcc --gcc fixtures/fake_gcc_serial.sh -j 1 fixtures/clean.c fixtures/leak.c"
    Then the exit code is 0
    When I run cchecker with "--tools gcc --gcc fixtures/fake_gcc_serial.sh -j 2 fixtures/clean.c fixtures/leak.c"
    Then the exit code is 2

  Scenario: A file that does not compile is a tool error, not a finding
    When I run cchecker with "--json fixtures/broken.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"gcc","file":"fixtures/broken.c"
      """

  Scenario: A file whose header is not there is not checked, with a warning, and the run goes on
    Given the C file "lonely.c" holds:
      """
      #include "not_installed/thing.h"
      int f(void) { return 0; }
      """
    When I run cchecker with "--json $DIR/lonely.c"
    Then the exit code is 0
    And the output includes:
      """
      "unchecked_files":[{"file":"$DIR/lonely.c","missing":"not_installed/thing.h"}]
      """
    And the output includes:
      """
      "errors":[]
      """
    When I run cchecker with "$DIR/lonely.c"
    Then the exit code is 0
    And the errors include:
      """
      cchecker: warning: $DIR/lonely.c not checked: not_installed/thing.h not found
      """

  Scenario: The other files of a run with a missing header are still checked
    Given the C file "lonely.c" holds:
      """
      #include <not_installed.h>
      int f(void) { return 0; }
      """
    When I run cchecker with "--json $DIR/lonely.c fixtures/leak.c"
    Then the exit code is 1
    And the output includes:
      """
      CC-GCC-ANALYZER-MALLOC-LEAK
      """
    And the output includes:
      """
      "unchecked_files":[{"file":"$DIR/lonely.c","missing":"not_installed.h"}]
      """

  Scenario Outline: An excluded file or folder is skipped
    When I run cchecker with "--exclude <exclude> fixtures/nested/deep_leak.c fixtures/clean.c"
    Then the exit code is 0

    Examples:
      | exclude                         |
      | fixtures/nested/deep_leak.c     |
      | ./fixtures/nested/deep_leak.c   |
      | fixtures/nested                 |
      | fixtures/nested/                |
      | other,./fixtures/nested         |
      | fixtures/../fixtures/nested     |

  Scenario Outline: An exclusion matches whole path parts, never a part of a name
    When I run cchecker with "--exclude <exclude> fixtures/nested/deep_leak.c"
    Then the exit code is 1

    Examples:
      | exclude                         |
      | fixtures/nested/deep            |
      | fixtures/nest                   |
      | fixtures/nested/deep_leak.cc    |

  Scenario: A file outside the working directory is reported as skipped
    When I run cchecker with "--json ../include/cchecker.h fixtures/clean.c"
    Then the exit code is 0
    And the output includes:
      """
      "skipped":1
      """
    And the errors include:
      """
      ../include/cchecker.h
      """

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
    When I run cchecker with "--tools gcc fixtures/uses_a.c fixtures/uses_b.c"
    Then the exit code is 1
    And the output includes:
      """
      fixtures/shared.h:6:12 CC-GCC-ANALYZER-MALLOC-LEAK
      """
    And the output includes:
      """
      cchecker: 1 new finding in 1 file
      """

  Scenario: A file that gcc 14 refuses is a tool error, never a finding
    When I run cchecker with "--json --tools gcc fixtures/implicit.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"gcc","file":"fixtures/implicit.c"
      """
    And the output does not include:
      """
      IMPLICIT-FUNCTION-DECLARATION
      """

  Scenario: A gcc that dies after its warnings is a tool error
    When I run cchecker with "--json --tools gcc --gcc fixtures/fake_gcc_ice.sh fixtures/clean.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"gcc","file":"fixtures/clean.c"
      """

  Scenario: Warnings of the build flags are not findings
    When I run cchecker with "fixtures/unused.c -- -Wall -Wextra"
    Then the exit code is 0

  Scenario Outline: A warning that -Werror turns into an error keeps its code
    When I run cchecker with "--tools gcc fixtures/leak.c -- <flag>"
    Then the exit code is 1
    And the output includes:
      """
      fixtures/leak.c:9:12 CC-GCC-ANALYZER-MALLOC-LEAK
      """

    Examples:
      | flag                           |
      | -Werror                        |
      | -Werror=analyzer-malloc-leak   |

  Scenario: -Werror does not make the other warnings of the build errors
    When I run cchecker with "--tools gcc fixtures/unused.c -- -Wall -Werror"
    Then the exit code is 0

  Scenario: An analyzer error of -Werror is a finding when gcc ran to the end
    When I run cchecker with "--tools gcc --gcc fixtures/fake_gcc_werror.sh fixtures/clean.c -- -Werror"
    Then the exit code is 1
    And the output includes:
      """
      fixtures/clean.c:1:1 CC-GCC-ANALYZER-MALLOC-LEAK
      """

  Scenario: A gcc that was killed after an analyzer error is a tool error, not a finding
    When I run cchecker with "--json --tools gcc --gcc fixtures/fake_gcc_killed.sh fixtures/clean.c -- -Werror"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"gcc","file":"fixtures/clean.c"
      """

  Scenario Outline: The tools run with the C locale
    When I run cchecker with "--tools <tool> --<tool> fixtures/fake_tool_locale.sh fixtures/clean.c"
    Then the exit code is 0

    Examples:
      | tool         |
      | gcc          |
      | clang-tidy   |

  Scenario: A .clang-tidy that makes warnings errors does not make findings tool errors
    When I run cchecker with "--tools clang-tidy fixtures/werror_tidy/div.c"
    Then the exit code is 1
    And the output includes:
      """
      fixtures/werror_tidy/div.c:2:17 CC-TIDY-BUGPRONE-INTEGER-DIVISION
      """

  Scenario: A tool that is killed by a signal is a tool error
    When I run cchecker with "--json --tools gcc --gcc fixtures/fake_gcc_suicide.sh fixtures/clean.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"gcc","file":"fixtures/clean.c"
      """

  Scenario Outline: A tool that does not end in time is stopped with everything it started
    Given the file "scratch/hang.pid" is removed
    When I run cchecker with "--json --tools gcc --gcc fixtures/<tool> --timeout 1 fixtures/clean.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"gcc","file":"fixtures/clean.c"
      """
    And the process written in "scratch/hang.pid" has ended

    Examples:
      | tool                          |
      | fake_gcc_hang.sh              |
      | fake_gcc_ignores_term.sh      |

  Scenario: A database with a file outside the working directory is reported as skipped
    When I run cchecker with "--json --tools gcc -p fixtures/outside"
    Then the exit code is 1
    And the output includes:
      """
      "skipped":1
      """
