Feature: The versions of the tools in the baseline
  The findings of gcc -fanalyzer and clang-tidy change with their versions, so an update of every file writes the
  versions of the tools it ran into the baseline, and a run with other versions says so. It is a warning: the counts
  still decide the exit code. The fake tools of specs/fixtures/ (links to fake_tool.sh) print a version for `--version`
  that depends on their name; the runs here start in the folder of the scenario.

  Background:
    Given the C file "clean.c" holds:
      """
      int add(int a, int b) { return a + b; }
      """
    And the C file "other.c" holds:
      """
      int twice(int a) { return a * 2; }
      """
    And the file "compile_commands.json" holds:
      """
      [
        {"directory": ".", "command": "cc -c clean.c", "file": "clean.c"},
        {"directory": ".", "command": "cc -c other.c", "file": "other.c"}
      ]
      """

  Scenario: An update of every file writes the version of each tool it ran
    When I run cchecker in its folder with "-b base.json --update-baseline"
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
    When I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline"
    Then the exit code is 0
    And the file "$DIR/base.json" includes:
      """
      "tools": {"gcc":"fake tool 1.0.0"}
      """

  Scenario: The same versions give no warning
    When I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline"
    And I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json"
    Then the exit code is 0
    And the errors do not include:
      """
      fake tool
      """
    When I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json"
    Then the output includes:
      """
      "version_changes":[]
      """

  Scenario: Another build of the same version number is no change
    When I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline"
    And I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/fake_tool_v1_other.sh -b base.json"
    Then the exit code is 0
    And the output includes:
      """
      "version_changes":[]
      """

  Scenario: Other versions are named with both and do not fail the run
    When I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline"
    And I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v2.sh -b base.json"
    Then the exit code is 0
    And the errors include:
      """
      fake tool 1.0.0
      """
    And the errors include:
      """
      fake tool 2.0.0
      """
    When I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/fake_tool_v2.sh -b base.json"
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
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "command": "cc -c leak.c", "file": "leak.c"}]
      """
    When I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline"
    And I run cchecker in its folder with "--json --tools gcc -b base.json"
    Then the exit code is 1
    And the output includes:
      """
      "version_changes":[{"tool":"gcc","baseline":"fake tool 1.0.0"
      """

  Scenario: A tool that did not run is not compared
    When I run cchecker in its folder with "--tools gcc,clang-tidy --gcc ../../fixtures/fake_tool_v1.sh --clang-tidy ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline"
    And I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json"
    Then the exit code is 0
    And the output includes:
      """
      "version_changes":[]
      """

  Scenario: An update changes the versions of the tools it ran and keeps the others
    When I run cchecker in its folder with "--tools gcc,clang-tidy --gcc ../../fixtures/fake_tool_v1.sh --clang-tidy ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline"
    And I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v2.sh -b base.json --update-baseline"
    Then the exit code is 0
    And the file "$DIR/base.json" includes:
      """
      "clang-tidy":"fake tool 1.0.0"
      """
    And the file "$DIR/base.json" includes:
      """
      "gcc":"fake tool 2.0.0"
      """

  Scenario: An update of some files keeps the stored versions
    When I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline"
    And I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v2.sh -b base.json --update-baseline clean.c"
    Then the exit code is 0
    And the file "$DIR/base.json" includes:
      """
      "gcc":"fake tool 1.0.0"
      """
    When I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v2.sh -b base.json --exclude other.c --update-baseline"
    Then the file "$DIR/base.json" includes:
      """
      "gcc":"fake tool 1.0.0"
      """

  Scenario Outline: A tool that prints no version loses its stored version after an update of every file
    When I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline"
    And I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/<tool>.sh -b base.json --update-baseline"
    Then the exit code is 0
    And the errors are not empty
    And the file "$DIR/base.json" does not include:
      """
      "gcc":"
      """
    When I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/fake_tool_v2.sh -b base.json"
    Then the output includes:
      """
      "version_changes":[]
      """

    Examples:
      | tool                    |
      | fake_tool_no_version    |
      | fake_tool_version_fails |

  Scenario: A baseline without versions still reads, and the next update of every file adds them
    Given the file "base.json" holds:
      """
      {"version": 1, "findings": []}
      """
    When I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json"
    Then the exit code is 0
    And the output includes:
      """
      "version_changes":[]
      """
    When I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline clean.c"
    Then the file "$DIR/base.json" does not include:
      """
      "gcc":"
      """
    When I run cchecker in its folder with "--tools gcc --gcc ../../fixtures/fake_tool_v1.sh -b base.json --update-baseline"
    Then the file "$DIR/base.json" includes:
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
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "command": "cc -c leak.c", "file": "leak.c"}]
      """
    When I run cchecker in its folder with "--tools gcc -b base.json --update-baseline"
    And I run cchecker in its folder with "--json --tools gcc --gcc ../../fixtures/fake_tool_v2.sh -b base.json --strict-baseline"
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
