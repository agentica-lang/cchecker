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
      #define READ_CAST (O_RDONLY | (int)O_NONBLOCK)
      CC_SHORT int tick(const char *path, int fd, char *buf) { <code> }
      """
    When I run cchecker with "--tools rules --json $DIR/flags.c -- -I../include"
    Then the exit code is <exit>
    And the output <short>:
      """
      "CC-EFFECT-SHORT-BLOCKS"
      """

    Examples:
      | case               | code                                                         | exit | short            |
      | no flag            | return open(path, O_RDONLY);                                 | 1    | includes         |
      | O_NONBLOCK         | return open(path, READ_NOW);                                 | 0    | does not include |
      | openat             | return openat(fd, path, READ_NOW);                           | 0    | does not include |
      | another flag       | return open(path, READ_CLOSE);                               | 1    | includes         |
      | through a variable | int flags = READ_NOW; return open(path, flags);              | 1    | includes         |
      | recv without flags | return (int)recv(fd, buf, 1, 0);                             | 1    | includes         |
      | recv               | return (int)recv(fd, buf, 1, MSG_DONTWAIT);                  | 0    | does not include |
      | send               | return (int)send(fd, buf, 1, MSG_DONTWAIT);                  | 0    | does not include |
      | recvfrom           | return (int)recvfrom(fd, buf, 1, MSG_DONTWAIT, 0, 0);        | 0    | does not include |
      | sendto             | return (int)sendto(fd, buf, 1, MSG_DONTWAIT, 0, 0);          | 0    | does not include |
      | a cast             | return open(path, READ_CAST);                                | 0    | does not include |
      | a literal value    | return (int)recv(fd, buf, 1, 0x40);                          | 0    | does not include |
      | two flags          | return (int)send(fd, buf, 1, SEND_NOW);                      | 0    | does not include |
      | send, another flag | return (int)send(fd, buf, 1, MSG_NOSIGNAL);                  | 1    | includes         |
      | one call of two    | (void)recv(fd, buf, 1, MSG_DONTWAIT); return (int)recv(fd, buf, 1, 0); | 1 | includes         |

  Scenario Outline: The values of the flags are those of the target (<target>, <value>)
    Given the C file "target.c" holds:
      """
      #include "cchecker.h"

      int open(const char *path, int flags, ...);
      CC_SHORT int tick(const char *path) { return open(path, <value>); }
      """
    When I run cchecker with "--tools rules --json $DIR/target.c -- -I../include <target>"
    Then the exit code is <exit>

    Examples:
      | target                       | value | exit |
      | --target=x86_64-pc-linux-gnu | 2048  | 0    |
      | --target=x86_64-pc-linux-gnu | 4     | 1    |
      | --target=arm64-apple-macos   | 4     | 0    |
      | --target=arm64-apple-macos   | 2048  | 1    |
      | -target arm64-apple-macos    | 4     | 0    |
      | -m32                         | 2048  | 0    |

  Scenario: A target whose values the rules do not know leaves the call blocking, and the run says so
    Given the C file "target.c" holds:
      """
      #include "cchecker.h"

      int open(const char *path, int flags, ...);
      CC_SHORT int tick(const char *path) { return open(path, 4); }
      CC_SHORT int tock(const char *path) { return open(path, 4); }
      """
    And the C file "other.c" holds:
      """
      #include "cchecker.h"

      int open(const char *path, int flags, ...);
      CC_SHORT int tack(const char *path) { return open(path, 4); }
      """
    When I run cchecker with "--tools rules $DIR/target.c $DIR/other.c -- -I../include --target=x86_64-unknown-freebsd"
    Then the exit code is 1
    And the errors include once:
      """
      cchecker: the flags of x86_64-unknown-freebsd are not known
      """

  Scenario: CC_HOT still counts a call with a flag that makes it return at once: it is a system call
    Given the C file "hot.c" holds:
      """
      #include <fcntl.h>
      #include "cchecker.h"

      CC_HOT int hot(const char *path) { return open(path, O_RDONLY | O_NONBLOCK); }
      """
    When I run cchecker with "--tools rules --json $DIR/hot.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "CC-EFFECT-HOT-SYSCALL"
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
