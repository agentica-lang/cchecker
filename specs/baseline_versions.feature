Feature: The versions of the tools in the baseline
  The findings of gcc -fanalyzer and clang-tidy change with their versions, so an update writes the versions of the tools
  it ran into the baseline, and a run with other versions says so before the summary. It is a warning: the counts still
  decide the exit code.

  Background:
    Given the C file "clean.c" holds:
      """
      int add(int a, int b) { return a + b; }
      """

  Scenario: An update writes the version of each tool it ran
    When I run cchecker with "--baseline $DIR/base.json --update-baseline $DIR/clean.c"
    Then the exit code is 0
    And the file "$DIR/base.json" includes:
      """
      "clang":"
      """
    And the file "$DIR/base.json" includes:
      """
      "clang-tidy":"
      """
    And the file "$DIR/base.json" includes:
      """
      "gcc":"
      """

  Scenario: Only the first line of the version is kept
    When I run cchecker with "--tools gcc --gcc fixtures/fake_tool_v1.sh -b $DIR/base.json --update-baseline $DIR/clean.c"
    Then the exit code is 0
    And the file "$DIR/base.json" includes:
      """
      "tools": {"gcc":"fake tool 1.0.0"}
      """

  Scenario: The same versions give no warning
    When I run cchecker with "--tools gcc --gcc fixtures/fake_tool_v1.sh -b $DIR/base.json --update-baseline $DIR/clean.c"
    And I run cchecker with "--tools gcc --gcc fixtures/fake_tool_v1.sh -b $DIR/base.json $DIR/clean.c"
    Then the exit code is 0
    And the errors do not include:
      """
      fake tool
      """
    When I run cchecker with "--json --tools gcc --gcc fixtures/fake_tool_v1.sh -b $DIR/base.json $DIR/clean.c"
    Then the exit code is 0
    And the output includes:
      """
      "version_changes":[]
      """

  Scenario: Other versions are named with both and do not fail the run
    When I run cchecker with "--tools gcc --gcc fixtures/fake_tool_v1.sh -b $DIR/base.json --update-baseline $DIR/clean.c"
    And I run cchecker with "--tools gcc --gcc fixtures/fake_tool_v2.sh -b $DIR/base.json $DIR/clean.c"
    Then the exit code is 0
    And the errors include:
      """
      fake tool 1.0.0
      """
    And the errors include:
      """
      fake tool 2.0.0
      """
    When I run cchecker with "--json --tools gcc --gcc fixtures/fake_tool_v2.sh -b $DIR/base.json $DIR/clean.c"
    Then the exit code is 0
    And the output includes:
      """
      "clean":true
      """
    And the output includes:
      """
      "version_changes":[{"tool":"gcc","baseline":"fake tool 1.0.0","current":"fake tool 2.0.0"}]
      """

  Scenario: The counts decide the exit code when the versions differ
    When I run cchecker with "--tools gcc --gcc fixtures/fake_tool_v1.sh -b $DIR/base.json --update-baseline $DIR/clean.c"
    And I run cchecker with "--json --tools gcc -b $DIR/base.json fixtures/leak.c"
    Then the exit code is 1
    And the output includes:
      """
      "version_changes":[{"tool":"gcc","baseline":"fake tool 1.0.0"
      """

  Scenario: A tool that did not run is not compared
    When I run cchecker with "--tools gcc,clang-tidy --gcc fixtures/fake_tool_v1.sh --clang-tidy fixtures/fake_tool_v1.sh -b $DIR/base.json --update-baseline $DIR/clean.c"
    And I run cchecker with "--json --tools gcc --gcc fixtures/fake_tool_v1.sh -b $DIR/base.json $DIR/clean.c"
    Then the exit code is 0
    And the output includes:
      """
      "version_changes":[]
      """

  Scenario: An update changes the versions of the tools it ran and keeps the others
    When I run cchecker with "--tools gcc,clang-tidy --gcc fixtures/fake_tool_v1.sh --clang-tidy fixtures/fake_tool_v1.sh -b $DIR/base.json --update-baseline $DIR/clean.c"
    And I run cchecker with "--tools gcc --gcc fixtures/fake_tool_v2.sh -b $DIR/base.json --update-baseline $DIR/clean.c"
    Then the exit code is 0
    And the file "$DIR/base.json" includes:
      """
      "clang-tidy":"fake tool 1.0.0"
      """
    And the file "$DIR/base.json" includes:
      """
      "gcc":"fake tool 2.0.0"
      """

  Scenario: A tool that does not name its version keeps the stored one
    When I run cchecker with "--tools gcc --gcc fixtures/fake_tool_v1.sh -b $DIR/base.json --update-baseline $DIR/clean.c"
    And I run cchecker with "--tools gcc --gcc fixtures/fake_tool_no_version.sh -b $DIR/base.json --update-baseline $DIR/clean.c"
    Then the exit code is 0
    And the file "$DIR/base.json" includes:
      """
      "gcc":"fake tool 1.0.0"
      """
    When I run cchecker with "--json --tools gcc --gcc fixtures/fake_tool_no_version.sh -b $DIR/base.json $DIR/clean.c"
    Then the exit code is 0
    And the output includes:
      """
      "version_changes":[]
      """

  Scenario: A baseline without versions still reads, and the next update adds them
    Given the file "old.json" holds:
      """
      {
        "version": 1,
        "findings": [
          {"code": "CC-GCC-ANALYZER-MALLOC-LEAK", "file": "fixtures/leak.c", "message": "leak of 'buf'", "count": 1}
        ]
      }
      """
    When I run cchecker with "--json --tools gcc -b $DIR/old.json fixtures/leak.c"
    Then the exit code is 0
    And the output includes:
      """
      "findings":[],"baselined":1,"fixed":0
      """
    And the output includes:
      """
      "version_changes":[]
      """
    When I run cchecker with "--tools gcc --gcc fixtures/fake_tool_v1.sh -b $DIR/old.json --update-baseline $DIR/clean.c"
    Then the exit code is 0
    And the file "$DIR/old.json" includes:
      """
      "gcc":"fake tool 1.0.0"
      """

  Scenario: A change of version with stale entries fails a strict run, which names both
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
    When I run cchecker with "--tools gcc -b $DIR/base.json --update-baseline $DIR/leak.c"
    And I run cchecker with "--json --tools gcc --gcc fixtures/fake_tool_v2.sh -b $DIR/base.json --strict-baseline $DIR/leak.c"
    Then the exit code is 1
    And the output includes:
      """
      "clean":false
      """
    And the output includes:
      """
      "version_changes":[{"tool":"gcc"
      """
    And the output includes:
      """
      "current":"fake tool 2.0.0"}]
      """
