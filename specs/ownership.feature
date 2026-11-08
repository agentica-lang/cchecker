Feature: Ownership on every path
  CC_OWNS says that a place owns the memory its pointer points to: a local variable, a parameter (the function takes
  what the caller passes), a function (it returns an owned value) or a field. A pointer that a function owns is freed
  or handed on on every path that returns: returned, stored in a CC_OWNS field, or passed to a CC_OWNS parameter.
  `free` frees, and so does a function on its CC_FREES parameter. A local variable that gets an owned value owns it
  too. A value is not freed twice, and not used after it was freed or handed on. The finding is at the function, and
  `path` is the path that breaks the rule.

  Scenario Outline: An owned pointer that a path does not free or hand on is a finding at the function (<case>)
    Given the C file "own.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"

      struct box { char *loose; CC_OWNS char *held; };
      int work(char *p); int fill(char **out); void adopt(CC_OWNS char *p); void drop(CC_FREES char *p); CC_OWNS char *make(int n);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/own.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-OWN-LEAK","tool":"rules","file":"$DIR/own.c","line":7,"column":<column>,
      """

    Examples:
      | case                   | column | code                                                                                                         |
      | early return           | 5      | int f(int n) { CC_OWNS char *b = malloc(n); if (!b) return -1; if (work(b)) return -1; free(b); return 0; } |
      | owned parameter        | 6      | void f(CC_OWNS char *p) { if (work(p)) return; free(p); }                                                  |
      | freed parameter        | 6      | void f(CC_FREES char *p) { if (work(p)) return; free(p); }                                                 |
      | owning call kept       | 5      | int f(int n) { char *p = make(n); return work(p); }                                                        |
      | owning call dropped    | 6      | void f(int n) { make(n); }                                                                                 |
      | owning call lent       | 5      | int f(int n) { return work(make(n)); }                                                                     |
      | owning call in a field | 6      | void f(struct box *x, int n) { x->loose = make(n); }                                                       |
      | overwritten            | 6      | void f(int n) { CC_OWNS char *b = malloc(n); b = malloc(n); free(b); }                                     |
      | set in a loop          | 6      | void f(int n) { CC_OWNS char *b = NULL; for (int i = 0; i < n; i++) b = malloc(n); free(b); }              |
      | field that does not own | 6     | void f(struct box *x, int n) { CC_OWNS char *b = malloc(n); x->loose = b; }                                |
      | lent                   | 6      | void f(int n) { CC_OWNS char *b = malloc(n); work(b); }                                                    |
      | moved to a local       | 6      | void f(int n) { CC_OWNS char *b = malloc(n); char *c = b; work(c); }                                       |
      | null on the other side | 5      | int f(int n) { CC_OWNS char *b = malloc(n); if (b) return -1; free(b); return 0; }                         |

  Scenario Outline: An owned pointer freed or handed on on every path passes (<case>)
    Given the C file "own.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"

      struct box { char *loose; CC_OWNS char *held; };
      int work(char *p); int fill(char **out); void adopt(CC_OWNS char *p); void drop(CC_FREES char *p); CC_OWNS char *make(int n);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/own.c -- -I../include"
    Then the exit code is 0

    Examples:
      | case                  | code                                                                                                                                          |
      | freed on both paths   | int f(int n) { CC_OWNS char *b = malloc(n); if (!b) return -1; if (work(b)) { free(b); return -1; } free(b); return 0; }                   |
      | compared with NULL    | int f(int n) { CC_OWNS char *b = malloc(n); if (b == NULL) return -1; free(b); return 0; }                                                  |
      | set in the condition  | int f(int n) { CC_OWNS char *b; if (!(b = malloc(n))) return -1; free(b); return 0; }                                                       |
      | set and compared      | int f(int n) { CC_OWNS char *b; if ((b = malloc(n)) == NULL) return -1; free(b); return 0; }                                                |
      | returned              | CC_OWNS char *f(int n) { CC_OWNS char *b = malloc(n); if (b && work(b)) { free(b); return NULL; } return b; }                               |
      | handed to a parameter | void f(int n) { CC_OWNS char *b = malloc(n); adopt(b); }                                                                                    |
      | owning field          | void f(struct box *x, int n) { CC_OWNS char *b = malloc(n); x->held = b; }                                                                  |
      | freed by the project  | void f(int n) { char *p = make(n); drop(p); }                                                                                               |
      | owning call freed     | void f(int n) { free(make(n)); }                                                                                                            |
      | owning call handed on | void f(int n) { adopt(make(n)); }                                                                                                           |
      | owning call stored    | void f(struct box *x, int n) { x->held = make(n); }                                                                                         |
      | owning call returned  | CC_OWNS char *f(int n) { return make(n); }                                                                                                  |
      | owning call in ?:     | void f(int n) { char *p = n ? make(n) : NULL; free(p); }                                                                                    |
      | owned parameter       | void f(CC_OWNS char *p) { if (!p) return; work(p); free(p); }                                                                               |
      | goto cleanup          | int f(int n) { int rc = -1; CC_OWNS char *b = malloc(n); if (!b) goto out; if (work(b)) goto out; rc = 0; out: free(b); return rc; }       |
      | realloc               | int f(int n) { CC_OWNS char *b = malloc(n); if (!b) return -1; char *t = realloc(b, 2 * n); if (!t) { free(b); return -1; } b = t; free(b); return 0; } |
      | realloc in place      | void f(int n) { CC_OWNS char *b = malloc(n); b = realloc(b, 2 * n); free(b); }                                                              |
      | moved to a local      | void f(int n) { CC_OWNS char *b = malloc(n); char *c = b; free(c); }                                                                        |
      | does not return       | void f(int n) { CC_OWNS char *b = malloc(n); if (work(b)) abort(); free(b); }                                                               |
      | same condition        | void f(int n) { CC_OWNS char *b = NULL; if (n) b = malloc(n); work(b); if (n) free(b); }                                                    |
      | filled by a call      | int f(void) { CC_OWNS char *b; if (fill(&b) < 0) return -1; free(b); return 0; }                                                            |
      | filled after a free   | void f(int n) { CC_OWNS char *b = malloc(n); free(b); if (fill(&b) < 0) return; free(b); }                                                  |
      | cleanup               | static void release(CC_FREES char **p) { free(*p); } void f(int n) { CC_OWNS char *b __attribute__((cleanup(release))) = malloc(n); work(b); } |
      | set again after free  | void f(int n) { CC_OWNS char *b = malloc(n); free(b); b = malloc(n); work(b); free(b); }                                                    |
      | freed in a loop       | void f(int n) { for (int i = 0; i < n; i++) { CC_OWNS char *b = malloc(n); work(b); free(b); } }                                            |
      | not marked            | void f(int n) { char *b = malloc(n); work(b); }                                                                                             |
      | freed and nulled      | static void release(CC_FREES char **p) { free(*p); *p = NULL; }                                                                             |
      | freed when not null   | static void release(CC_FREES char **p) { if (*p) free(*p); }                                                                                |
      | ?: tested again       | void f(int n) { char *p = n ? make(n) : NULL; if (!n) return; work(p); free(p); }                                                           |
      | alias set again       | void f(CC_OWNS char *p) { char *c = p; free(c); c = malloc(8); work(c); }                                                                   |
      | statement expression  | void f(int n) { char *p = ({ char *q = make(n); if (!q) abort(); q; }); free(p); }                                                       |

  Scenario Outline: A pointer freed or handed on twice on a path is a finding at the function (<case>)
    Given the C file "own.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"

      int work(char *p); void adopt(CC_OWNS char *p); void drop(CC_FREES char *p); CC_OWNS char *make(int n);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/own.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-OWN-DOUBLE-FREE","tool":"rules","file":"$DIR/own.c","line":6,"column":6,
      """
    And the output does not include:
      """
      CC-OWN-USE-AFTER-FREE
      """

    Examples:
      | case              | code                                                                         |
      | twice             | void f(int n) { CC_OWNS char *b = malloc(n); free(b); free(b); }             |
      | on one path       | void f(int n) { CC_OWNS char *b = malloc(n); if (work(b)) free(b); free(b); } |
      | after handing on  | void f(int n) { CC_OWNS char *b = malloc(n); adopt(b); free(b); }            |
      | freed by the project | void f(int n) { char *p = make(n); drop(p); drop(p); }                    |
      | owned parameter   | void f(CC_OWNS char *p) { free(p); free(p); }                                |

  Scenario Outline: A pointer used after a path freed it or handed it on is a finding at the function (<case>)
    Given the C file "own.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"

      int work(char *p); void adopt(CC_OWNS char *p);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/own.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-OWN-USE-AFTER-FREE","tool":"rules","file":"$DIR/own.c","line":6,"column":<column>,
      """

    Examples:
      | case               | column | code                                                                       |
      | read               | 6      | void f(int n) { CC_OWNS char *b = malloc(n); free(b); work(b); }           |
      | written through    | 6      | void f(int n) { CC_OWNS char *b = malloc(n); free(b); b[0] = 0; }          |
      | after handing on   | 6      | void f(int n) { CC_OWNS char *b = malloc(n); adopt(b); work(b); }          |
      | handed on twice    | 6      | void f(int n) { CC_OWNS char *b = malloc(n); adopt(b); adopt(b); }         |
      | returned           | 15     | CC_OWNS char *f(int n) { CC_OWNS char *b = malloc(n); free(b); return b; } |
      | through a pointer  | 6      | void f(CC_FREES char *p) { free(p); *p = 0; }                              |

  Scenario: The path of a finding goes from where the pointer got its value to the return that leaks it
    Given the C file "own.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"

      int work(char *p);

      int f(int n) {
        if (n < 0)
          return -1;
        CC_OWNS char *b = malloc(n);
        if (!b)
          return -1;
        if (work(b))
          return -1;
        free(b);
        return 0;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/own.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "line":6,"column":5,"message":"f does not free or hand on b on every path","path":["9:21 b = malloc","10:8 true","12:7 true","13:5 returns"]
      """

  Scenario: A function with more paths than the rules follow is checked on those it went through and counted
    Given the C file "many.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"
      int pick(int i);
      void many(void) {
        CC_OWNS char *b0 = NULL;
        CC_OWNS char *b1 = NULL;
        CC_OWNS char *b2 = NULL;
        CC_OWNS char *b3 = NULL;
        CC_OWNS char *b4 = NULL;
        CC_OWNS char *b5 = NULL;
        CC_OWNS char *b6 = NULL;
        CC_OWNS char *b7 = NULL;
        CC_OWNS char *b8 = NULL;
        CC_OWNS char *b9 = NULL;
        CC_OWNS char *b10 = NULL;
        CC_OWNS char *b11 = NULL;
        CC_OWNS char *b12 = NULL;
        CC_OWNS char *b13 = NULL;
        CC_OWNS char *b14 = NULL;
        CC_OWNS char *b15 = NULL;
        CC_OWNS char *b16 = NULL;
        CC_OWNS char *b17 = NULL;
        CC_OWNS char *b18 = NULL;
        CC_OWNS char *b19 = NULL;
        if (pick(0)) b0 = malloc(8);
        if (pick(1)) b1 = malloc(8);
        if (pick(2)) b2 = malloc(8);
        if (pick(3)) b3 = malloc(8);
        if (pick(4)) b4 = malloc(8);
        if (pick(5)) b5 = malloc(8);
        if (pick(6)) b6 = malloc(8);
        if (pick(7)) b7 = malloc(8);
        if (pick(8)) b8 = malloc(8);
        if (pick(9)) b9 = malloc(8);
        if (pick(10)) b10 = malloc(8);
        if (pick(11)) b11 = malloc(8);
        if (pick(12)) b12 = malloc(8);
        if (pick(13)) b13 = malloc(8);
        if (pick(14)) b14 = malloc(8);
        if (pick(15)) b15 = malloc(8);
        if (pick(16)) b16 = malloc(8);
        if (pick(17)) b17 = malloc(8);
        if (pick(18)) b18 = malloc(8);
        if (pick(19)) b19 = malloc(8);
        free(b0);
        free(b1);
        free(b2);
        free(b3);
        free(b4);
        free(b5);
        free(b6);
        free(b7);
        free(b8);
        free(b9);
        free(b10);
        free(b11);
        free(b12);
        free(b13);
        free(b14);
        free(b15);
        free(b16);
        free(b17);
        free(b18);
        free(b19);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/many.c -- -I../include"
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":1
      """

  Scenario: The marks of a prototype hold in the definition and in the callers that include it
    Given the C file "own.h" holds:
      """
      #include "cchecker.h"

      CC_OWNS char *make(int n);
      void adopt(CC_OWNS char *p);
      """
    And the C file "user.c" holds:
      """
      #include <stdlib.h>
      #include "own.h"

      void adopt(char *p) {
        if (*p)
          return;
        free(p);
      }

      int keep(int n) {
        char *p = make(n);
        return *p;
      }

      void pass(int n) {
        adopt(make(n));
      }
      """
    When I run cchecker with "--tools rules --json $DIR/user.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-OWN-LEAK","tool":"rules","file":"$DIR/user.c","line":4,"column":6,
      """
    And the output includes:
      """
      {"code":"CC-OWN-LEAK","tool":"rules","file":"$DIR/user.c","line":10,"column":5,
      """
    And the output does not include:
      """
      "line":15
      """

  Scenario: CC_IGNORE and a comment suppress a finding of ownership
    Given the C file "own.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"

      int work(char *p);

      CC_IGNORE("CC-OWN-LEAK", "the pool frees it") void kept(int n) {
        CC_OWNS char *b = malloc(n);
        work(b);
      }

      // cchecker: ignore CC-OWN-*: the caller checks it
      void twice(int n) {
        CC_OWNS char *b = malloc(n);
        free(b);
        free(b);
      }
      """
    When I run cchecker with "--tools rules --json $DIR/own.c -- -I../include"
    Then the exit code is 0
    And the output includes:
      """
      "suppressed":[{"code":"CC-OWN-LEAK","tool":"rules","file":"$DIR/own.c","line":6,
      """
    And the output includes:
      """
      {"code":"CC-OWN-DOUBLE-FREE","tool":"rules","file":"$DIR/own.c","line":12,
      """
