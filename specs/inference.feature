Feature: Roots inferred from libuv callbacks
  A function passed as a callback to a libuv call that runs it on the loop thread is a CC_SHORT root without a mark:
  it runs on the event loop, so it must never block. The finding says which call made the root, in `root`, and
  `source` is the flag that turns the inference off. A callback cchecker cannot follow to a function is listed in
  `unresolved_callbacks`, never dropped.

  Scenario Outline: A function passed to a libuv call that runs it on the loop is a CC_SHORT root
    Given the C file "loop.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      int <call>();
      static void quick(void) {}
      static void slow(void) { sleep(1); }

      void start(void *h) { <call>(<args>); }
      """
    When I run cchecker in its folder with "--tools rules --json loop.c"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-EFFECT-SHORT-BLOCKS","tool":"rules","file":"loop.c","line":4,"column":13,
      """
    And the output includes:
      """
      "path":["slow","sleep"],"source":"libuv_callbacks_short","root":"callback of <call> at loop.c:6"}
      """

    Examples:
      | call             | args                  |
      | uv_timer_start   | h, slow, 0, 0         |
      | uv_poll_start    | h, 0, slow            |
      | uv_async_init    | h, h, slow            |
      | uv_close         | h, slow               |
      | uv_read_start    | h, slow, quick        |
      | uv_read_start    | h, quick, slow        |
      | uv_write         | h, h, h, 1, slow      |
      | uv_write2        | h, h, h, 1, h, slow   |
      | uv_shutdown      | h, h, slow            |
      | uv_tcp_connect   | h, h, h, slow         |
      | uv_pipe_connect  | h, h, h, slow         |
      | uv_pipe_connect2 | h, h, h, 0, 0, slow   |
      | uv_queue_work    | h, h, quick, slow     |

  Scenario Outline: A function libuv runs off the loop or at no callback place, or of a library, is no root
    Given the C file "loop.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      int <call>();
      static void quick(void) {}
      static void slow(void) { sleep(1); }

      void start(void *h) { <call>(<args>); }
      """
    When I run cchecker in its folder with "--tools rules --json loop.c"
    Then the exit code is 0
    And the output includes:
      """
      "unresolved_callbacks":[]
      """

    Examples:
      | call           | args              |
      | uv_queue_work  | h, h, slow, quick |
      | uv_timer_start | h, quick, slow, 0 |
      | uv_close       | h, 0              |
      | uv_close       | h, sleep          |

  Scenario: A callback passed on through a parameter is followed, and the text report names the root
    Given the C file "loop.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      typedef void (*timer_cb)(void *);
      int uv_timer_start(void *handle, timer_cb cb, unsigned long timeout, unsigned long repeat);

      static void on_tick(void *handle) { (void)handle; sleep(1); }
      static void arm(void *handle, timer_cb cb) { uv_timer_start(handle, cb, 10, 0); }
      void start(void *handle) { arm(handle, on_tick); }
      """
    When I run cchecker in its folder with "--tools rules loop.c"
    Then the exit code is 1
    And the output includes:
      """
      on_tick -> sleep (root: callback of uv_timer_start at loop.c:6)
      """

  Scenario Outline: A callback that cchecker cannot follow to a function is listed
    Given the C file "loop.c" holds:
      """
      typedef void (*timer_cb)(void *);
      int uv_timer_start(void *handle, timer_cb cb, unsigned long timeout, unsigned long repeat);
      timer_cb pick(void);

      <code>
      """
    When I run cchecker in its folder with "--tools rules --json loop.c"
    Then the exit code is 0
    And the output includes:
      """
      "unresolved_callbacks":[{"call":"uv_timer_start","argument":1,"file":"loop.c","line":5}]
      """
    When I run cchecker in its folder with "--tools rules loop.c"
    Then the exit code is 0
    And the errors include:
      """
      cchecker: 1 callback of a libuv call
      """

    Examples:
      | code                                                                  |
      | void start(void *h) { uv_timer_start(h, pick(), 0, 0); }              |
      | void arm(void *h, timer_cb cb) { uv_timer_start(h, cb, 0, 0); }       |

  Scenario: --no-infer and libuv_callbacks_short = false turn the inference off
    Given the C file "loop.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      typedef void (*timer_cb)(void *);
      int uv_timer_start(void *handle, timer_cb cb, unsigned long timeout, unsigned long repeat);
      timer_cb pick(void);

      static void on_tick(void *handle) { (void)handle; sleep(1); }
      void start(void *handle) { uv_timer_start(handle, on_tick, 10, 0); uv_timer_start(handle, pick(), 10, 0); }
      """
    When I run cchecker in its folder with "--tools rules --json loop.c"
    Then the exit code is 1
    When I run cchecker in its folder with "--tools rules --json --no-infer loop.c"
    Then the exit code is 0
    And the output includes:
      """
      "unresolved_callbacks":[]
      """
    Given the file "cchecker.toml" holds:
      """
      [library]
      libuv_callbacks_short = false
      """
    When I run cchecker in its folder with "--tools rules --json loop.c"
    Then the exit code is 0
    And the output includes:
      """
      "unresolved_callbacks":[]
      """

  Scenario: A marked callback is one root, and the baseline holds its finding when the call moves
    Given the C file "loop.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      int uv_close();
      CC_SHORT static void closed(void) { sleep(1); }
      static void gone(void) { sleep(1); }
      void stop(void *h) { uv_close(h, closed); uv_close(h, gone); }
      """
    When I run cchecker in its folder with "--tools rules --json loop.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      "path":["closed","sleep"],"source":"libc_blocking","root":""}
      """
    When I run cchecker in its folder with "--tools rules -b base.json --update-baseline loop.c -- -I../../../include"
    Then the exit code is 0
    Given the C file "loop.c" holds:
      """
      #include "cchecker.h"

      unsigned int sleep(unsigned int seconds);
      int uv_close();
      CC_SHORT static void closed(void) { sleep(1); }
      static void gone(void) { sleep(1); }

      void stop(void *h) { uv_close(h, closed); uv_close(h, gone); }
      """
    When I run cchecker in its folder with "--tools rules -b base.json --json loop.c -- -I../../../include"
    Then the exit code is 0
    And the output includes:
      """
      "baselined":2
      """
