Feature: The settings of a project
  cchecker reads its settings from the first of: the file of -c (its [tool.cchecker] table when it has one, else the
  whole file), cchecker.toml in the project folder, the [tool.cchecker] table of agentica.toml there, the defaults.
  `[library]` turns the families of library knowledge on and off, and `[roots]` names CC_SHORT and CC_HOT roots
  without a mark in the C. --json says which settings were read, and a run for people says it on standard error.

  Background:
    Given the C file "blocks.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      CC_SHORT int tick(void) { return (int)sleep(1); }
      """

  Scenario: With no settings file the defaults hold, and every family is on
    When I run cchecker in its folder with "--tools rules --json blocks.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      "source":"libc_blocking"
      """
    And the output includes:
      """
      "config":"defaults"
      """
    When I run cchecker in its folder with "--tools rules blocks.c -- -I../../../include"
    Then the exit code is 1
    And the errors include:
      """
      cchecker: settings: defaults
      """

  Scenario: cchecker.toml in the project folder is read
    Given the file "cchecker.toml" holds:
      """
      [library]
      libc_blocking = false
      """
    When I run cchecker in its folder with "--tools rules --json blocks.c -- -I../../../include"
    Then the exit code is 0
    And the output includes:
      """
      "config":"cchecker.toml"
      """

  Scenario: The [tool.cchecker] table of agentica.toml is read when there is no cchecker.toml
    Given the file "agentica.toml" holds:
      """
      name = "demo"

      [tool.cchecker.library]
      libc_blocking = false
      """
    When I run cchecker in its folder with "--tools rules --json blocks.c -- -I../../../include"
    Then the exit code is 0
    And the output includes:
      """
      "config":"agentica.toml"
      """

  Scenario: cchecker.toml comes before agentica.toml
    Given the file "cchecker.toml" holds:
      """
      [library]
      libc_blocking = true
      """
    And the file "agentica.toml" holds:
      """
      name = "demo"

      [tool.cchecker.library]
      libc_blocking = false
      """
    When I run cchecker in its folder with "--tools rules --json blocks.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      "config":"cchecker.toml"
      """

  Scenario: An agentica.toml without a [tool.cchecker] table is skipped
    Given the file "agentica.toml" holds:
      """
      name = "demo"

      [style]
      blank_line_after_end = true
      """
    When I run cchecker in its folder with "--tools rules --json blocks.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      "config":"defaults"
      """

  Scenario: The file of -c comes before cchecker.toml
    Given the file "cchecker.toml" holds:
      """
      [library]
      libc_blocking = true
      """
    And the file "ci.toml" holds:
      """
      [library]
      libc_blocking = false
      """
    When I run cchecker in its folder with "--tools rules --json -c ci.toml blocks.c -- -I../../../include"
    Then the exit code is 0
    And the output includes:
      """
      "config":"ci.toml"
      """

  Scenario: The file of --config is read through its [tool.cchecker] table when it has one
    Given the file "sub/agentica.toml" holds:
      """
      name = "demo"

      [tool.cchecker.library]
      libc_blocking = false
      """
    When I run cchecker in its folder with "-t rules --json --config sub/agentica.toml blocks.c -- -I../../../include"
    Then the exit code is 0
    And the output includes:
      """
      "config":"sub/agentica.toml"
      """

  Scenario: A file of -c that is not there is an error
    When I run cchecker in its folder with "--tools rules -c missing.toml blocks.c -- -I../../../include"
    Then the exit code is 2
    And the errors include:
      """
      missing.toml
      """

  Scenario Outline: An unknown key or a value of the wrong type is an error, so a typo turns nothing off
    Given the file "cchecker.toml" holds:
      """
      <table>
      <line>
      """
    When I run cchecker in its folder with "--tools rules blocks.c -- -I../../../include"
    Then the exit code is 2
    And the errors include:
      """
      cchecker.toml: <key>
      """

    Examples:
      | table      | line                                      | key                    |
      | [librray]  |                                           | librray                |
      | [library]  | libc_blockng = false                      | library.libc_blockng   |
      | [library]  | libc_blocking = "no"                      | library.libc_blocking  |
      | [roots]    | short = "tick"                            | roots.short            |
      | [roots]    | short = [1]                               | roots.short            |
      | [effects]  | follow_cld = true                         | effects.follow_cld     |
      | [effects]  | follow_cold = 1                           | effects.follow_cold    |
      | [assume]   | shrot = ["tick"]                          | assume.shrot           |
      | [assume]   | stop = "tick"                             | assume.stop            |
      | [assume]   | short_locks = [1]                         | assume.short_locks     |
      | [assume]   | stop_fields = "a.b"                       | assume.stop_fields     |
      | [assume]   | stop_calls = "a>b"                        | assume.stop_calls      |
      | [assume]   | stop_calls = ["a"]                        | assume.stop_calls      |
      | [assume]   | stop_calls = [">b"]                       | assume.stop_calls      |
      | [assume]   | stop_calls = ["a>"]                       | assume.stop_calls      |
      | [assume]   | stop_calls = ["a->b"]                     | assume.stop_calls      |
      | [assume]   | stop_calls = ["a>b>c"]                    | assume.stop_calls      |
      | [assume]   | stop_calls = ["a > b"]                    | assume.stop_calls      |
      | [assume]   | jump_releases = "a"                       | assume.jump_releases   |
      | [assume]   | nonblocking = "a"                         | assume.nonblocking     |
      | [database] | fold_ignoring = "A"                       | database.fold_ignoring |
      | [database] | fold_ignoring = ["-DA"]                   | database.fold_ignoring |
      | [database] | fold_ignoring = ["A=1"]                   | database.fold_ignoring |
      | [database] | fold_ignores = ["A"]                      | database.fold_ignores  |
      | [assume]   | acquires = "lock(0)"                      | assume.acquires        |
      | [assume]   | acquires = ["lock"]                       | assume.acquires        |
      | [assume]   | acquires = ["lock()"]                     | assume.acquires        |
      | [assume]   | releases = ["lock(x)"]                    | assume.releases        |
      | [assume]   | releases = ["lock@(0)"]                   | assume.releases        |
      | [assume]   | short_locks = ["lock(x)"]                 | assume.short_locks     |
      | [assume]   | acquires = ["lock(99999999999999999999)"] | assume.acquires        |
      | [assume]   | acquires = ["lock a(0)"]                  | assume.acquires        |
      | [assume]   | acquires = ["uv_mutex_lock(0)"]           | assume.acquires        |
      | [assume]   | releases = ["pthread_mutex_unlock(0)"]    | assume.releases        |
      | [assume]   | acquires = ["uv_mutex_trylock(0)"]        | assume.acquires        |
      | [database] | fold_ignoring = ["A,B"]                   | database.fold_ignoring |
      | [database] | fold_ignoring = ["1A"]                    | database.fold_ignoring |

  Scenario: A function in acquires and releases at once is an error
    Given the C file "blocks.c" holds:
      """
      void tick(void) {}
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      acquires = ["lock(0)"]
      releases = ["lock(1)"]
      """
    When I run cchecker in its folder with "--tools rules blocks.c"
    Then the exit code is 2
    And the errors include:
      """
      cchecker.toml: assume.acquires and releases both name lock
      """
    Given the file "cchecker.toml" holds:
      """
      [assume]
      acquires = ["lock@a.c(0)"]
      releases = ["lock@b.c(0)", "unlock(0)"]
      """
    When I run cchecker in its folder with "--tools rules blocks.c"
    Then the exit code is 0

  Scenario Outline: Each family of library knowledge can be turned off
    Given the C file "family.c" holds:
      """
      #include "cchecker.h"

      int <call>();
      CC_SHORT int tick(void) { return <call>(); }
      """
    When I run cchecker in its folder with "--tools rules --json family.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      "source":"<flag>"
      """
    Given the file "cchecker.toml" holds:
      """
      [library]
      <flag> = false
      """
    When I run cchecker in its folder with "--tools rules --json family.c -- -I../../../include"
    Then the exit code is 0

    Examples:
      | call               | flag             |
      | sleep              | libc_blocking    |
      | pthread_mutex_lock | pthread_blocking |
      | uv_run             | libuv_blocking   |
      | GC_gcollect        | libgc_blocking   |

  Scenario Outline: A function named in [roots] gives the same finding as its mark
    Given the C file "roots.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      void *malloc(unsigned long size);
      <mark> int entry(void) { return (int)sleep(1) + (malloc(1) != 0); }
      """
    And the file "cchecker.toml" holds:
      """
      [roots]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json roots.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"<code>","tool":"rules","file":"roots.c","line":5,"column":<column>,
      """

    Examples:
      | mark     | list              | code                    | column |
      | CC_SHORT |                   | CC-EFFECT-SHORT-BLOCKS  | 14     |
      |          | short = ["entry"] | CC-EFFECT-SHORT-BLOCKS  | 6      |
      | CC_HOT   |                   | CC-EFFECT-HOT-ALLOCATES | 12     |
      |          | hot = ["entry"]   | CC-EFFECT-HOT-ALLOCATES | 6      |

  Scenario: A name of [roots] that no function of the compile database has is an error
    Given the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "blocks.c", "arguments": ["cc", "-I../../../include", "-c", "blocks.c"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [roots]
      short = ["tick"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 1
    Given the file "cchecker.toml" holds:
      """
      [roots]
      short = ["tick", "tock"]
      """
    When I run cchecker in its folder with "--tools rules"
    Then the exit code is 2
    And the errors include:
      """
      tock
      """

  Scenario: A file of -c without a [tool.cchecker] table is read whole, and the error says so
    Given the file "sub/agentica.toml" holds:
      """
      name = "demo"
      """
    When I run cchecker in its folder with "--tools rules -c sub/agentica.toml blocks.c -- -I../../../include"
    Then the exit code is 2
    And the errors include:
      """
      (no [tool.cchecker] table; read as a cchecker file)
      """

  Scenario: A plain file of -c with an unknown key gets no note about a manifest
    Given the file "other.toml" holds:
      """
      [rots]
      short = ["tick"]
      """
    When I run cchecker in its folder with "--tools rules -c other.toml blocks.c -- -I../../../include"
    Then the exit code is 2
    And the errors include:
      """
      rots
      """
    And the errors do not include:
      """
      no [tool.cchecker] table
      """

  Scenario: name@file in [roots] is the function of that file only
    Given the C file "a.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      static int tick(void) { return (int)sleep(1); }
      int a(void) { return tick(); }
      """
    And the C file "b.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      static int tick(void) { return (int)sleep(2); }
      int b(void) { return tick(); }
      """
    And the file "compile_commands.json" holds:
      """
      [{"directory": ".", "file": "a.c", "arguments": ["cc", "-c", "a.c"]},
       {"directory": ".", "file": "b.c", "arguments": ["cc", "-c", "b.c"]}]
      """
    And the file "cchecker.toml" holds:
      """
      [roots]
      short = ["tick@b.c"]
      """
    When I run cchecker in its folder with "--tools rules --json"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-EFFECT-SHORT-BLOCKS","tool":"rules","file":"b.c","line":2,
      """
    And the output does not include:
      """
      "file":"a.c"
      """
    Given the file "cchecker.toml" holds:
      """
      [roots]
      short = ["tick@b.c", "tick@c.c"]
      """
    When I run cchecker in its folder with "--tools rules --json"
    Then the exit code is 2
    And the errors include:
      """
      tick@c.c
      """

  Scenario: --update-baseline with -c is refused when the file leaves out a short root, even named as hot
    Given the C file "more.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      int tock(void) { return (int)sleep(1); }
      """
    And the file "cchecker.toml" holds:
      """
      [roots]
      short = ["tock"]
      """
    And the file "other.toml" holds:
      """
      [roots]
      hot = ["tock"]
      """
    When I run cchecker in its folder with "--tools rules -b base.json --update-baseline -c other.toml more.c"
    Then the exit code is 2
    And the errors include:
      """
      (short: tock)
      """
    And the file "$DIR/base.json" does not exist
    When I run cchecker in its folder with "--tools rules -b base.json --update-baseline more.c"
    Then the exit code is 0

  Scenario: --update-baseline with --no-infer names only that cause
    When I run cchecker in its folder with "--tools rules -b base.json --update-baseline --no-infer blocks.c"
    Then the exit code is 2
    And the errors include:
      """
      --no-infer
      """
    And the errors do not include:
      """
      defaults
      """

  Scenario: A run of some files says that it did not check the names of [roots]
    Given the file "cchecker.toml" holds:
      """
      [roots]
      short = ["tock"]
      """
    When I run cchecker in its folder with "--tools rules blocks.c -- -I../../../include"
    Then the exit code is 1
    And the errors include:
      """
      cchecker: the names of [roots] were not checked
      """

  Scenario: A name of [roots] holds for the static functions of that name in every file
    Given the C file "a.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      static int tick(void) { return (int)sleep(1); }
      int a(void) { return tick(); }
      """
    And the C file "b.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      static int tick(void) { return (int)sleep(2); }
      int b(void) { return tick(); }
      """
    And the file "cchecker.toml" holds:
      """
      [roots]
      short = ["tick"]
      """
    When I run cchecker in its folder with "--tools rules --json a.c b.c"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-EFFECT-SHORT-BLOCKS","tool":"rules","file":"a.c","line":2,
      """
    And the output includes:
      """
      {"code":"CC-EFFECT-SHORT-BLOCKS","tool":"rules","file":"b.c","line":2,
      """
