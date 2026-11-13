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

  Scenario Outline: A value that starts with - can be the next word, as for --checks -*,...
    When I run cchecker with "<tools> --checks -*,bugprone-branch-clone fixtures/branch_clone.c"
    Then the exit code is 1
    And the output includes:
      """
      CC-TIDY-BUGPRONE-BRANCH-CLONE
      """

    Examples:
      | tools              |
      | --tools clang-tidy |
      | -t clang-tidy      |

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
      "clean":true,"findings":[],"baselined":0,"fixed":0,"stale":[],"errors":[],"skipped":0
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

  Scenario: A file that the database lists for a static and a shared library is checked once
    Given the C file "x.c" holds:
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
    And the C file "compile_commands.json" holds:
      """
      [
        {"directory": ".", "command": "cc -DLEVEL=1 -I. -MD -MT a.o -MF a.o.d -o a.o -c x.c", "file": "x.c"},
        {"directory": ".", "command": "cc -DLEVEL=1 -Dx_EXPORTS -I. -fPIC -MD -MT b.o -MF b.o.d -o b.o -c x.c", "file": "x.c"}
      ]
      """
    When I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/fake_gcc_count.sh -p ."
    Then the exit code is 0
    And the output includes:
      """
      "folded":1
      """
    And the file "$DIR/runs.log" includes:
      """
      ran
      """
    And the file "$DIR/runs.log" does not include:
      """
      ran
      ran
      """
    When I run cchecker in its folder with "--json --tools gcc -p ."
    Then the exit code is 1
    And the output includes once:
      """
      "code":"CC-GCC-ANALYZER-MALLOC-LEAK"
      """

  Scenario: The entries of one file with other defines are each checked
    Given the C file "x.c" holds:
      """
      int f(void) { return 0; }
      """
    And the C file "compile_commands.json" holds:
      """
      [
        {"directory": ".", "command": "cc -DA -o a.o -c x.c", "file": "x.c"},
        {"directory": ".", "command": "cc -DB -o b.o -c x.c", "file": "x.c"}
      ]
      """
    When I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/fake_gcc_count.sh -p ."
    Then the exit code is 0
    And the output includes:
      """
      "folded":0
      """
    And the file "$DIR/runs.log" includes:
      """
      ran
      ran
      """

  Scenario Outline: [database] fold_ignoring folds the entries of a file that differ only in the listed defines (<case>)
    Given the C file "x.c" holds:
      """
      int f(void) { return 0; }
      """
    And the C file "compile_commands.json" holds:
      """
      [
        {"directory": ".", "command": "cc -DLEVEL=1 -I. -o a.o -c x.c", "file": "x.c"},
        {"directory": ".", "command": "cc -DLEVEL=1 <define> -I. -o b.o -c x.c", "file": "x.c"}
      ]
      """
    And the file "cchecker.toml" holds:
      """
      [database]
      <setting>
      """
    When I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/fake_gcc_count.sh -p ."
    Then the exit code is 0
    And the output includes:
      """
      "folded":<folded>
      """
    And the file "$DIR/runs.log" <twice>:
      """
      ran
      ran
      """

    Examples:
      | case                          | define                | setting                               | folded | twice            |
      | listed                        | -DBUILDING_X_SHARED=1 | fold_ignoring = ["BUILDING_X_SHARED"] | 1      | does not include |
      | listed, no value              | -DBUILDING_X_SHARED   | fold_ignoring = ["BUILDING_X_SHARED"] | 1      | does not include |
      | listed, two words             | -D BUILDING_X_SHARED  | fold_ignoring = ["BUILDING_X_SHARED"] | 1      | does not include |
      | another define                | -DBUILDING_X_SHARED=1 | fold_ignoring = ["LEVEL"]             | 0      | includes         |
      | a name that starts the define | -DBUILDING_X_SHARED=1 | fold_ignoring = ["BUILDING_X"]        | 0      | includes         |
      | empty                         | -DBUILDING_X_SHARED=1 | fold_ignoring = []                    | 0      | includes         |

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
      | arguments                                                      |
      |                                                                |
      | --tools lint fixtures/clean.c                                  |
      | --update-baseline fixtures/clean.c                             |
      | --strict-baseline fixtures/clean.c                             |
      | -b x.json --update-baseline --strict-baseline fixtures/clean.c |
      | --checks=-* -b x.json --strict-baseline fixtures/clean.c       |
      | --jobs 0 fixtures/clean.c                                      |
      | -p fixtures fixtures/clean.c                                   |
      | -- -DLEAK                                                      |
      | fixtures/clean.c --checks                                      |
      | fixtures/clean.c -p                                            |

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

  Scenario Outline: A project that turns colours or links on loses no finding
    When I run cchecker with "<args>"
    Then the exit code is 1
    And the output includes:
      """
      <finding>
      """

    Examples:
      | args                                                        | finding                                                          |
      | --tools clang-tidy fixtures/color_tidy/div.c                | fixtures/color_tidy/div.c:2:17 CC-TIDY-BUGPRONE-INTEGER-DIVISION |
      | --tools gcc fixtures/leak.c -- -fdiagnostics-color=always   | fixtures/leak.c:9:12 CC-GCC-ANALYZER-MALLOC-LEAK                 |
      | --tools gcc fixtures/leak.c -- -fdiagnostics-urls=always    | fixtures/leak.c:9:12 CC-GCC-ANALYZER-MALLOC-LEAK                 |

  Scenario: A project that turns colours on still gets the place of a compile error of the rules
    When I run cchecker with "--json --tools rules fixtures/broken.c -- -fcolor-diagnostics"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"rules","file":"fixtures/broken.c","message":"fixtures/broken.c:1:22:
      """

  Scenario: A diagnostic line that cchecker cannot read is a tool error, not silence
    When I run cchecker with "--json --tools clang-tidy --clang-tidy fixtures/fake_tidy_color.sh fixtures/clean.c"
    Then the exit code is 2
    And the output includes:
      """
      "code":"CC-TIDY-BUGPRONE-INTEGER-DIVISION"
      """
    And the output includes:
      """
      "errors":[{"tool":"clang-tidy","file":"fixtures/clean.c"
      """

  Scenario: A tool that is killed by a signal is a tool error
    When I run cchecker with "--json --tools gcc --gcc fixtures/fake_gcc_suicide.sh fixtures/clean.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"gcc","file":"fixtures/clean.c"
      """

  # Each tool writes the pid of its child in a file of its own: the scenarios of one file run at once.
  Scenario Outline: A tool that does not end in time is stopped with everything it started
    Given the file "scratch/<pids>.pid" is removed
    When I run cchecker with "--json --tools gcc --gcc fixtures/<tool> --timeout 1 fixtures/clean.c"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"gcc","file":"fixtures/clean.c"
      """
    And the process written in "scratch/<pids>.pid" has ended

    Examples:
      | tool                          | pids         |
      | fake_gcc_hang.sh              | hang         |
      | fake_gcc_ignores_term.sh      | ignores_term |

  Scenario: A clang of the rules that does not end in time is stopped, and its dump and FIFO are removed
    Given the file "scratch/clang_hang.pid" is removed
    When I run cchecker with "--json --tools rules --clang fixtures/fake_clang_hang.sh --timeout 1 fixtures/clean.c" and TMPDIR "$DIR/tmp"
    Then the exit code is 2
    And the output includes:
      """
      "errors":[{"tool":"rules","file":"fixtures/clean.c"
      """
    And the process written in "scratch/clang_hang.pid" has ended
    And the folder "$DIR/tmp" is empty

  Scenario: A database with a file outside the working directory is reported as skipped
    When I run cchecker with "--json --tools gcc -p fixtures/outside"
    Then the exit code is 1
    And the output includes:
      """
      "skipped":1
      """
