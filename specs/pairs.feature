Feature: Pairs of calls restored on every path
  CC_PAIR(set, restore) on a function says that in its body, every call of `set` is followed by a call of `restore`
  on every path that returns. On the declaration of `set` itself, it says so in every function that calls `set`. A
  call of `restore` with no `set` before it does nothing, and a path that ends in a call that does not return does
  not need the restore. The body of a `set` that carries its own CC_PAIR is how the pair works: it may leave another
  pair set for its caller.

  Scenario Outline: A call of a set that a path does not restore is a finding at the function (<case>)
    Given the C file "guard.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"

      void mask_signals(void); void restore_signals(void); void log_restore(void); int work(int n);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/guard.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-PAIR-NOT-RESTORED","tool":"rules","file":"$DIR/guard.c","line":6,"column":<column>,
      """

    Examples:
      | case          | column | code                                                                                                                                                         |
      | early return  | 44     | CC_PAIR(mask_signals, restore_signals) int guarded(int n) { mask_signals(); if (work(n)) return -1; restore_signals(); return 0; }                         |
      | error path    | 44     | CC_PAIR(mask_signals, restore_signals) int guarded(int n) { mask_signals(); if (work(n)) goto fail; restore_signals(); return 0; fail: return -1; }        |
      | set twice     | 44     | CC_PAIR(mask_signals, restore_signals) int guarded(int n) { mask_signals(); mask_signals(); restore_signals(); return n; }                                 |
      | restore first | 44     | CC_PAIR(mask_signals, restore_signals) int guarded(int n) { restore_signals(); mask_signals(); return n; }                                                 |
      | set form      | 69     | CC_PAIR(mask_signals, restore_signals) void mask_signals(void); int guarded(int n) { mask_signals(); if (work(n)) return -1; restore_signals(); return 0; } |
      | marked twice  | 133    | CC_PAIR(mask_signals, restore_signals) void mask_signals(void); CC_PAIR(mask_signals, restore_signals) void mask_signals(void); int guarded(int n) { mask_signals(); mask_signals(); restore_signals(); return n; } |
      | both forms    | 108    | CC_PAIR(mask_signals, restore_signals) void mask_signals(void); CC_PAIR(mask_signals, restore_signals) int guarded(int n) { mask_signals(); mask_signals(); restore_signals(); return n; } |
      | two pairs on a set | 79     | CC_PAIR(mask_signals, restore_signals) CC_PAIR(mask_signals, log_restore) int guarded(int n) { mask_signals(); log_restore(); log_restore(); return n; } |

  Scenario Outline: A set restored on every path passes (<case>)
    Given the C file "guard.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"

      void mask_signals(void); void restore_signals(void); void log_restore(void); int work(int n);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/guard.c -- -I../include"
    Then the exit code is 0

    Examples:
      | case              | code                                                                                                                                                                                                       |
      | both paths        | CC_PAIR(mask_signals, restore_signals) int guarded(int n) { mask_signals(); if (work(n)) { restore_signals(); return -1; } restore_signals(); return 0; }                                                 |
      | goto out          | CC_PAIR(mask_signals, restore_signals) int guarded(int n) { int rc = 0; mask_signals(); if (work(n)) { rc = -1; goto out; } work(n); out: restore_signals(); return rc; }                                |
      | same condition    | CC_PAIR(mask_signals, restore_signals) int guarded(int n) { if (n) mask_signals(); work(n); if (n) restore_signals(); return 0; }                                                                        |
      | cleanup           | static void restore_at(int *p) { (void)p; restore_signals(); } CC_PAIR(mask_signals, restore_at) int guarded(int n) { mask_signals(); int g __attribute__((cleanup(restore_at))) = 0; return work(n + g); } |
      | does not return   | CC_PAIR(mask_signals, restore_signals) int guarded(int n) { mask_signals(); if (work(n)) abort(); restore_signals(); return 0; }                                                                         |
      | another function  | CC_PAIR(mask_signals, restore_signals) int guarded(int n); int other(int n) { mask_signals(); return work(n); }                                                                                           |
      | set form          | CC_PAIR(mask_signals, restore_signals) void mask_signals(void); int guarded(int n) { mask_signals(); work(n); restore_signals(); return 0; }                                                              |
      | set defined       | CC_PAIR(mask_signals, restore_signals) void mask_signals(void); void mask_signals(void) { work(0); } int guarded(int n) { mask_signals(); restore_signals(); return n; }                                  |
      | a set that wraps  | CC_PAIR(mask_signals, restore_signals) void mask_signals(void); CC_PAIR(enter_quiet, leave_quiet) void enter_quiet(void); void leave_quiet(void); void enter_quiet(void) { mask_signals(); } void leave_quiet(void) { restore_signals(); } |
      | restore alone     | CC_PAIR(mask_signals, restore_signals) void mask_signals(void); int reset(int n) { restore_signals(); return n; }                                                                                         |

  Scenario: The path of a finding goes from the set to the return that skips the restore
    Given the C file "guard.c" holds:
      """
      #include "cchecker.h"

      void mask_signals(void);
      void restore_signals(void);

      CC_PAIR(mask_signals, restore_signals) int guarded(int n) {
        mask_signals();
        if (n)
          return -1;
        restore_signals();
        return 0;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/guard.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "line":6,"column":44,
      """
    And the output includes:
      """
      "path":["7:3 calls mask_signals","8:7 true","9:5 returns"]
      """

  Scenario: A pair on a prototype of a header holds in the files that include it
    Given the C file "pairs.h" holds:
      """
      #include "cchecker.h"

      void mask_signals(void);
      void restore_signals(void);
      CC_PAIR(enter_quiet, leave_quiet) void enter_quiet(void);
      void leave_quiet(void);
      CC_PAIR(mask_signals, restore_signals) int guarded(int n);
      """
    And the C file "user.c" holds:
      """
      #include "pairs.h"

      int guarded(int n) {
        mask_signals();
        return n;
      }

      void tick(void) {
        enter_quiet();
      }

      void tock(void) {
        enter_quiet();
        leave_quiet();
      }
      """
    When I run cchecker with "--tools rules --json $DIR/user.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-PATH-PAIR-NOT-RESTORED","tool":"rules","file":"$DIR/user.c","line":3,"column":5,
      """
    And the output includes:
      """
      {"code":"CC-PATH-PAIR-NOT-RESTORED","tool":"rules","file":"$DIR/user.c","line":8,"column":6,
      """
    And the output does not include:
      """
      "line":12
      """
