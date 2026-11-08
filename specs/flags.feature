Feature: Calls that do not block by their flags
  A call of `open` or `openat` with O_NONBLOCK, or of `recv`, `send`, `recvfrom` or `sendto` with MSG_DONTWAIT, does
  not block, so it is not a blocking call for CC_SHORT. The rules read the flag argument when it is a constant, with
  the values of the target that clang builds for (Linux or macOS); a flag in a variable, or a target whose values the
  rules do not know, leaves the call blocking. `[library] libc_nonblocking_flags = false` turns this off.

  Scenario Outline: A call with a flag that makes it return at once is not blocking (<case>)
    Given the C file "flags.c" holds:
      """
      #include "fcntl.h"
      #include "sys/socket.h"
      #include "cchecker.h"

      #define READ_NOW (O_RDONLY | O_NONBLOCK)
      #define READ_CLOSE (O_RDONLY | O_CLOEXEC)
      #define SEND_NOW (MSG_DONTWAIT | MSG_NOSIGNAL)
      CC_SHORT int tick(const char *path, int fd, char *buf) { <code> }
      """
    When I run cchecker with "--tools rules --json $DIR/flags.c -- -I../include"
    Then the exit code is <exit>

    Examples:
      | case               | code                                                         | exit |
      | no flag            | return open(path, O_RDONLY);                                 | 1    |
      | O_NONBLOCK         | return open(path, READ_NOW);                                 | 0    |
      | openat             | return openat(fd, path, READ_NOW);                           | 0    |
      | another flag       | return open(path, READ_CLOSE);                               | 1    |
      | through a variable | int flags = READ_NOW; return open(path, flags);              | 1    |
      | recv without flags | return (int)recv(fd, buf, 1, 0);                             | 1    |
      | recv               | return (int)recv(fd, buf, 1, MSG_DONTWAIT);                  | 0    |
      | send               | return (int)send(fd, buf, 1, MSG_DONTWAIT);                  | 0    |
      | recvfrom           | return (int)recvfrom(fd, buf, 1, MSG_DONTWAIT, 0, 0);        | 0    |
      | sendto             | return (int)sendto(fd, buf, 1, MSG_DONTWAIT, 0, 0);          | 0    |
      | two flags          | return (int)send(fd, buf, 1, SEND_NOW);                      | 0    |
      | send, another flag | return (int)send(fd, buf, 1, MSG_NOSIGNAL);                  | 1    |
      | one call of two    | (void)recv(fd, buf, 1, MSG_DONTWAIT); return (int)recv(fd, buf, 1, 0); | 1 |

  Scenario Outline: The values of the flags are those of the target (<target>, <value>)
    Given the C file "target.c" holds:
      """
      #include "cchecker.h"

      int open(const char *path, int flags, ...);
      CC_SHORT int tick(const char *path) { return open(path, <value>); }
      """
    When I run cchecker with "--tools rules --json $DIR/target.c -- -I../include --target=<target>"
    Then the exit code is <exit>

    Examples:
      | target              | value | exit |
      | x86_64-pc-linux-gnu | 2048  | 0    |
      | x86_64-pc-linux-gnu | 4     | 1    |
      | arm64-apple-macos   | 4     | 0    |
      | arm64-apple-macos   | 2048  | 1    |

  Scenario: A target whose values the rules do not know leaves the call blocking, and the run says so
    Given the C file "target.c" holds:
      """
      #include "cchecker.h"

      int open(const char *path, int flags, ...);
      CC_SHORT int tick(const char *path) { return open(path, 4); }
      """
    When I run cchecker with "--tools rules $DIR/target.c -- -I../include --target=x86_64-unknown-freebsd"
    Then the exit code is 1
    And the errors include:
      """
      cchecker: the flags of x86_64-unknown-freebsd are not known
      """

  Scenario: [library] libc_nonblocking_flags = false reads no flag
    Given the C file "flags.c" holds:
      """
      #include <fcntl.h>
      #include "cchecker.h"

      CC_SHORT int tick(const char *path) { return open(path, O_RDONLY | O_NONBLOCK); }
      """
    When I run cchecker in its folder with "--tools rules flags.c -- -I../../../include"
    Then the exit code is 0
    Given the file "cchecker.toml" holds:
      """
      [library]
      libc_nonblocking_flags = false
      """
    When I run cchecker in its folder with "--tools rules flags.c -- -I../../../include"
    Then the exit code is 1
