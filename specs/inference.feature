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
      "path":["slow","sleep"],"source":"libuv_callbacks_short+libc_blocking","root":"callback of <call> at loop.c:6"}
      """

    Examples:
      | call                    | args                   |
      | uv_timer_start          | h, slow, 0, 0          |
      | uv_poll_start           | h, 0, slow             |
      | uv_async_init           | h, h, slow             |
      | uv_close                | h, slow                |
      | uv_read_start           | h, slow, quick         |
      | uv_read_start           | h, quick, slow         |
      | uv_write                | h, h, h, 1, slow       |
      | uv_write2               | h, h, h, 1, h, slow    |
      | uv_shutdown             | h, h, slow             |
      | uv_tcp_connect          | h, h, h, slow          |
      | uv_pipe_connect         | h, h, h, slow          |
      | uv_pipe_connect2        | h, h, h, 0, 0, slow    |
      | uv_queue_work           | h, h, quick, slow      |
      | uv_listen               | h, h, slow             |
      | uv_idle_start           | h, slow                |
      | uv_prepare_start        | h, slow                |
      | uv_check_start          | h, slow                |
      | uv_signal_start         | h, slow, h             |
      | uv_signal_start_oneshot | h, slow, h             |
      | uv_tcp_close_reset      | h, slow                |
      | uv_udp_recv_start       | h, slow, quick         |
      | uv_udp_recv_start       | h, quick, slow         |
      | uv_udp_send             | h, h, h, h, h, slow    |
      | uv_getaddrinfo          | h, h, slow, h, h, h    |
      | uv_getnameinfo          | h, h, slow, h, h       |
      | uv_random               | h, h, h, h, h, slow    |
      | uv_fs_event_start       | h, slow, h, h          |
      | uv_fs_poll_start        | h, slow, h, h          |
      | uv_fs_access            | h, h, h, h, slow       |
      | uv_fs_chmod             | h, h, h, h, slow       |
      | uv_fs_chown             | h, h, h, h, h, slow    |
      | uv_fs_close             | h, h, h, slow          |
      | uv_fs_closedir          | h, h, h, slow          |
      | uv_fs_copyfile          | h, h, h, h, h, slow    |
      | uv_fs_fchmod            | h, h, h, h, slow       |
      | uv_fs_fchown            | h, h, h, h, h, slow    |
      | uv_fs_fdatasync         | h, h, h, slow          |
      | uv_fs_fstat             | h, h, h, slow          |
      | uv_fs_fsync             | h, h, h, slow          |
      | uv_fs_ftruncate         | h, h, h, h, slow       |
      | uv_fs_futime            | h, h, h, h, h, slow    |
      | uv_fs_lchown            | h, h, h, h, h, slow    |
      | uv_fs_link              | h, h, h, h, slow       |
      | uv_fs_lstat             | h, h, h, slow          |
      | uv_fs_lutime            | h, h, h, h, h, slow    |
      | uv_fs_mkdir             | h, h, h, h, slow       |
      | uv_fs_mkdtemp           | h, h, h, slow          |
      | uv_fs_mkstemp           | h, h, h, slow          |
      | uv_fs_open              | h, h, h, h, h, slow    |
      | uv_fs_opendir           | h, h, h, slow          |
      | uv_fs_read              | h, h, h, h, h, h, slow |
      | uv_fs_readdir           | h, h, h, slow          |
      | uv_fs_readlink          | h, h, h, slow          |
      | uv_fs_realpath          | h, h, h, slow          |
      | uv_fs_rename            | h, h, h, h, slow       |
      | uv_fs_rmdir             | h, h, h, slow          |
      | uv_fs_scandir           | h, h, h, h, slow       |
      | uv_fs_sendfile          | h, h, h, h, h, h, slow |
      | uv_fs_stat              | h, h, h, slow          |
      | uv_fs_statfs            | h, h, h, slow          |
      | uv_fs_symlink           | h, h, h, h, h, slow    |
      | uv_fs_unlink            | h, h, h, slow          |
      | uv_fs_utime             | h, h, h, h, h, slow    |
      | uv_fs_write             | h, h, h, h, h, h, slow |
      | uv_walk                 | h, slow, h             |

  Scenario Outline: A function stored in the exit_cb of uv_process_options_t is a CC_SHORT root (<case>)
    Given the C file "spawn.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      typedef struct uv_process_options_s {
        void (*exit_cb)(void *process, long status, int signal);
        const char *file;
      } uv_process_options_t;
      int uv_spawn(void *loop, void *process, const uv_process_options_t *options);
      static void quick(void *process, long status, int signal) {}
      static void slow(void *process, long status, int signal) { sleep(1); }

      <setup>
      """
    When I run cchecker in its folder with "--tools rules --json spawn.c"
    Then the exit code is <exit>
    And the output includes:
      """
      <output>
      """

    Examples:
      | case               | setup                                                                                            | exit | output                                                                                                                        |
      | assignment         | void start(void *l, void *p) { uv_process_options_t o; o.exit_cb = slow; uv_spawn(l, p, &o); }   | 1    | "path":["slow","sleep"],"source":"libuv_callbacks_short+libc_blocking","root":"callback of uv_process_options_t.exit_cb at spawn.c:10"} |
      | initializer        | void start(void *l, void *p) { uv_process_options_t o = {.exit_cb = slow}; uv_spawn(l, p, &o); } | 1    | "path":["slow","sleep"],"source":"libuv_callbacks_short+libc_blocking","root":"callback of uv_process_options_t.exit_cb at spawn.c:10"} |
      | global initializer | static uv_process_options_t o = {slow, "x"};                                                     | 1    | "path":["slow","sleep"],"source":"libuv_callbacks_short+libc_blocking","root":"callback of uv_process_options_t.exit_cb at spawn.c:10"} |
      | pointer assignment | void start(void *l, void *p, uv_process_options_t *o) { o->exit_cb = slow; uv_spawn(l, p, o); } | 1 | "path":["slow","sleep"],"source":"libuv_callbacks_short+libc_blocking","root":"callback of uv_process_options_t.exit_cb at spawn.c:10"} |
      | other fields first | void start(void *l, void *p) { uv_process_options_t o = {.file = "x", .exit_cb = slow}; uv_spawn(l, p, &o); } | 1 | "path":["slow","sleep"],"source":"libuv_callbacks_short+libc_blocking","root":"callback of uv_process_options_t.exit_cb at spawn.c:10"} |
      | compound literal arg | void start(void *l, void *p) { uv_spawn(l, p, &(uv_process_options_t){.exit_cb = slow}); } | 1 | "path":["slow","sleep"],"source":"libuv_callbacks_short+libc_blocking","root":"callback of uv_process_options_t.exit_cb at spawn.c:10"} |
      | compound literal assigned | void start(void *l, void *p) { uv_process_options_t o; o = (uv_process_options_t){.exit_cb = slow}; uv_spawn(l, p, &o); } | 1 | "path":["slow","sleep"],"source":"libuv_callbacks_short+libc_blocking","root":"callback of uv_process_options_t.exit_cb at spawn.c:10"} |
      | null only | void start(void *l, void *p) { uv_process_options_t o; o.exit_cb = ((void *)0); uv_spawn(l, p, &o); } | 0 | "unresolved_callbacks":[] |
      | a quick function   | void start(void *l, void *p) { uv_process_options_t o = {.exit_cb = quick}; uv_spawn(l, p, &o); } | 0    | "unresolved_callbacks":[]                                                                                                     |
      | another struct     | typedef struct { void (*exit_cb)(void *p, long s, int g); } other_t; static other_t o = {slow};   | 0    | "unresolved_callbacks":[]                                                                                                     |

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
      | call           | args                |
      | uv_queue_work  | h, h, slow, quick   |
      | uv_timer_start | h, quick, slow, 0   |
      | uv_close       | h, 0                |
      | uv_close       | h, sleep            |
      | uv_fs_stat     | h, h, slow, 0       |
      | uv_getaddrinfo | h, h, 0, slow, h, h |

  Scenario: An exit_cb that cchecker cannot follow to a function is listed, with -1 as its place
    Given the C file "spawn.c" holds:
      """
      typedef struct uv_process_options_s {
        void (*exit_cb)(void *process, long status, int signal);
        const char *file;
      } uv_process_options_t;
      int uv_spawn(void *loop, void *process, const uv_process_options_t *options);

      void start(void *l, void *p, void (*cb)(void *, long, int)) {
        uv_process_options_t o;
        o.exit_cb = cb;
        uv_spawn(l, p, &o);
      }
      """
    When I run cchecker in its folder with "--tools rules --json spawn.c"
    Then the exit code is 0
    And the output includes:
      """
      "unresolved_callbacks":[{"call":"uv_process_options_t.exit_cb","argument":-1,"file":"spawn.c","line":9}]
      """

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

  Scenario: A callback of a call outside the working directory is listed with its absolute path
    Given the file "body.inc" holds:
      """
      uv_timer_start(h, pick(), 0, 0);
      """
    And the C file "sub/loop.c" holds:
      """
      typedef void (*timer_cb)(void *);
      int uv_timer_start(void *handle, timer_cb cb, unsigned long timeout, unsigned long repeat);
      timer_cb pick(void);

      void start(void *h) {
      #include "../body.inc"
      }
      """
    When I run cchecker in its folder "sub" with "--tools rules --json loop.c"
    Then the exit code is 0
    And the output includes:
      """
      "unresolved_callbacks":[{"call":"uv_timer_start","argument":1,"file":"/
      """
    And the output includes:
      """
      /body.inc","line":1}]
      """

  Scenario Outline: --update-baseline is refused while a check is turned off, as it would drop accepted findings
    Given the C file "loop.c" holds:
      """
      unsigned int sleep(unsigned int seconds);
      typedef void (*timer_cb)(void *);
      int uv_timer_start(void *handle, timer_cb cb, unsigned long timeout, unsigned long repeat);

      static void on_tick(void *handle) { (void)handle; sleep(1); }
      void start(void *handle) { uv_timer_start(handle, on_tick, 10, 0); }
      """
    And the file "off.toml" holds:
      """
      [library]
      <flag> = false
      """
    When I run cchecker in its folder with "--tools rules -b base.json --update-baseline loop.c"
    Then the exit code is 0
    When I run cchecker in its folder with "--tools rules -b base.json --update-baseline <options> loop.c"
    Then the exit code is 2
    And the errors include:
      """
      --update-baseline
      """
    When I run cchecker in its folder with "--tools rules -b base.json --json loop.c"
    Then the exit code is 0
    And the output includes:
      """
      "baselined":1
      """

    Examples:
      | flag                  | options     |
      | libc_blocking         | --no-infer  |
      | libuv_callbacks_short | -c off.toml |
      | libc_blocking         | -c off.toml |
