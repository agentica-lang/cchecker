Feature: Ownership on every path
  CC_OWNS says that a place owns the memory its pointer points to: a local variable, a parameter (the function takes
  what the caller passes), a function (it returns an owned value) or a field. A pointer that a function owns is freed
  or handed on on every path that returns: returned, stored in a CC_OWNS field, or passed to a CC_OWNS parameter.
  `free` frees, and so does a function on its CC_FREES parameter. A local variable that gets an owned value owns it
  too. A value is not freed twice, and not used after it was freed or handed on. A call that may jump out (CC_MAY_JUMP,
  `[assume] may_jump`) is a way out too, and one that always jumps (CC_JUMPS) is a way out where the path ends. The
  finding is at the function, and `path` is the path that breaks the rule.

  Scenario Outline: An owned pointer that a path does not free or hand on is a finding at the function (<case>)
    Given the C file "own.c" holds:
      """
      #include "stdlib.h"
      #include "string.h"
      #include "cchecker.h"
      struct box { char *loose; CC_OWNS char *held; };
      int work(char *p); int fill(char **out); void adopt(CC_OWNS char *p); void drop(CC_FREES char *p); CC_OWNS char *make(int n); void zap(CC_FREES char **p);

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
      | pointer array not null | 6     | void f(int n) { CC_OWNS char **v = malloc(n * sizeof *v); if (!*v) return; free(v); }                     |
      | parameter set again    | 6      | void f(CC_OWNS char *p) { free(p); p = malloc(8); }                                                        |
      | overwritten through *p | 13     | static void replace(CC_FREES char **p, char *v) { *p = v; }                                                |
      | elvis                  | 6      | void f(char *q, int n) { char *p = q ?: make(n); work(p); }                                              |
      | old value never freed  | 6      | void f(CC_FREES char **p, char *v) { char *old = *p; *p = v; }                                            |
      | local named as a global | 23    | CC_OWNS char *g; void f(int n) { CC_OWNS char *b = malloc(n); char *g[1]; g[0] = b; } |

  Scenario Outline: An owned pointer freed or handed on on every path passes (<case>)
    Given the C file "own.c" holds:
      """
      #include "stdlib.h"
      #include "string.h"
      #include "cchecker.h"
      struct box { char *loose; CC_OWNS char *held; };
      int work(char *p); int fill(char **out); void adopt(CC_OWNS char *p); void drop(CC_FREES char *p); CC_OWNS char *make(int n); void zap(CC_FREES char **p);

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
      | noreturn pointer      | void f(int n, void (*die)(void) __attribute__((noreturn))) { CC_OWNS char *b = malloc(n); if (work(b)) die(); free(b); }                    |
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
      | nested statement expr | void f(int n) { char *p = ({ char *q = ({ char *r = make(n); r; }); q; }); free(p); }                                     |
      | ?: set in the condition | char *g(void); void f(int n) { char *q; char *p = (q = g()) ? make(n) : NULL; free(p); }                                |
      | pointer array nulled  | void f(int n) { CC_OWNS char **v = malloc(n * sizeof *v); *v = NULL; free(v); }                                               |
      | freed and set again   | static void reset(CC_FREES char **p) { free(*p); *p = strdup("x"); }                                                                        |
      | const pointer freed   | static void release(CC_FREES char *const *p) { if (*p) free(*p); }                                                                         |
      | restrict pointer freed | static void release(CC_FREES char *__restrict *p) { if (*p) free(*p); }                                                                   |
      | owning call through *p | static void reset(CC_FREES char **p) { free(*p); *p = make(1); }                                                                          |
      | owner stored through *p | static void reset(CC_FREES char **p) { free(*p); CC_OWNS char *n = malloc(8); *p = n; }                                                  |
      | old value kept         | static void replace(CC_FREES char **p, char *v) { char *old = *p; *p = v; free(old); }                                                    |
      | items freed            | void f(void) { CC_OWNS char **v = malloc(16); free(*v); free(v); }                                                                         |
      | freed through address  | void f(int n) { CC_OWNS char *b = malloc(n); zap(&b); if (!b) work(b); }                                                                  |
      | freed by a helper      | void f(int n) { CC_OWNS char *b = malloc(n); zap(&b); free(b); }                                                                         |
      | global declared twice  | extern CC_OWNS char *g; char *g; void f(int n) { CC_OWNS char *b = malloc(n); g = b; }                                                 |
      | atomic pointer freed   | static void release(CC_FREES _Atomic(char *) *p) { if (*p) free(*p); }                                                                   |
      | elvis                  | void f(char *q, int n) { char *p = q ?: make(n); free(p); }                                                                               |
      | field of a local struct | void f(int n) { struct local { CC_OWNS char *held; } x; CC_OWNS char *b = malloc(n); x.held = b; work(x.held); }                        |

  Scenario Outline: A pointer freed or handed on twice on a path is a finding at the function (<case>)
    Given the C file "own.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"

      int work(char *p); void adopt(CC_OWNS char *p); void drop(CC_FREES char *p); CC_OWNS char *make(int n); void zap(CC_FREES char **p);

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
      | freed through address | void f(int n) { CC_OWNS char *b = malloc(n); zap(&b); if (b) free(b); }    |
      | stored through *p     | void f(CC_FREES char **p) { CC_OWNS char *n = malloc(8); free(*p); *p = n; free(n); } |
      | old value freed       | void f(CC_FREES char **p) { char *old = *p; free(*p); *p = NULL; free(old); } |
      | two locals of the old value | void f(CC_FREES char **p, char *v) { char *a = *p; char *c = *p; *p = v; free(a); free(c); } |

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
      | stored through *p  | 6      | void f(CC_FREES char **p) { CC_OWNS char *n = malloc(8); free(*p); *p = n; work(n); } |
      | through a pointer  | 6      | void f(CC_FREES char *p) { free(p); *p = 0; }                              |

  Scenario Outline: A pointer handed on through an out-parameter or into an item of an owned array is followed (<case>)
    Given the C file "out.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      struct box { CC_OWNS char *held; }; int retry(void); CC_MAY_JUMP int jump(void);
      CC_MAY_JUMP int take_or_jump(CC_OWNS_OUT char **out); void renew(CC_FREES CC_OWNS_OUT char **p);
      int work(char *p); CC_OWNS char *make(int n); int take(CC_OWNS_OUT char **out);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/out.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"<finding>","tool":"rules","file":"$DIR/out.c","line":7,"column":<column>,
      """

    Examples:
      | case                          | finding            | column | code                                                                                                       |
      | read, then returned           | CC-OWN-LEAK        | 5      | int f(void) { char *b; if (take(&b) < 0) return -1; work(b); return 0; }                                |
      | read, then an error return    | CC-OWN-LEAK        | 5      | int f(void) { CC_OWNS char *b; if (take(&b) < 0) return -1; if (work(b)) return -1; free(b); return 0; } |
      | read, then a jump             | CC-OWN-LEAK        | 6      | void f(void) { CC_OWNS char *b; take(&b); work(b); jump(); free(b); }                                   |
      | not null, then returned       | CC-OWN-LEAK        | 5      | int f(void) { char *b; take(&b); if (b) return -1; return 0; }                                          |
      | read, then set to null        | CC-OWN-LEAK        | 6      | void f(void) { char *b; take(&b); work(b); b = NULL; }                                                  |
      | read through an alias         | CC-OWN-LEAK        | 6      | void f(void) { char *b; take(&b); char *c = b; work(c); }                                               |
      | filled over an owned value    | CC-OWN-LEAK        | 6      | void f(int n) { CC_OWNS char *b = malloc(n); take(&b); free(b); }                                       |
      | freed and filled again        | CC-OWN-LEAK        | 6      | void f(void) { CC_OWNS char *b = malloc(8); renew(&b); work(b); }                                       |
      | handed out, then freed        | CC-OWN-DOUBLE-FREE | 5      | int f(CC_OWNS_OUT char **out) { CC_OWNS char *p = malloc(8); if (!p) return -1; *out = p; free(p); return 0; } |
      | item handed out, then freed   | CC-OWN-DOUBLE-FREE | 5      | int f(CC_OWNS_OUT char **out) { CC_OWNS char *p = malloc(8); if (!p) return -1; out[0] = p; free(p); return 0; } |
      | stored in an item, then freed | CC-OWN-DOUBLE-FREE | 16     | CC_OWNS char **f(int n) { CC_OWNS char **v = calloc(2, sizeof *v); if (!v) return NULL; CC_OWNS char *p = malloc(n); v[0] = p; free(p); return v; } |
      | stored by ?:, then freed      | CC-OWN-DOUBLE-FREE | 6      | void f(struct box *x, int n) { CC_OWNS char *p = malloc(8); x->held = n ? NULL : p; free(p); }          |
      | item of a parameter           | CC-OWN-LEAK        | 6      | void f(char **v, int n) { v[0] = make(n); }                                                             |
      | item of a local array         | CC-OWN-LEAK        | 6      | void f(int n) { char *v[2]; v[0] = make(n); work(v[0]); }                                               |

  Scenario Outline: A pointer handed on through an out-parameter or into an item of an owned array passes (<case>)
    Given the C file "out.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      struct box { CC_OWNS char *held; }; int retry(void); CC_MAY_JUMP int jump(void);
      CC_MAY_JUMP int take_or_jump(CC_OWNS_OUT char **out); void renew(CC_FREES CC_OWNS_OUT char **p);
      int work(char *p); CC_OWNS char *make(int n); int take(CC_OWNS_OUT char **out);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/out.c -- -I../include"
    Then the exit code is 0

    Examples:
      | case                        | code                                                                                                                       |
      | filled and freed            | int f(void) { char *b; if (take(&b) < 0) return -1; work(b); free(b); return 0; }                                       |
      | filled and stored           | int f(struct box *x) { char *b = NULL; if (take(&b) < 0) return -1; x->held = b; return 0; }                            |
      | filled and null             | int f(void) { CC_OWNS char *b; take(&b); if (!b) return -1; work(b); free(b); return 0; }                               |
      | filled and not read         | int f(void) { CC_OWNS char *b; take(&b); return 0; }                                                                     |
      | filled and dropped          | void f(void) { char *b; take(&b); }                                                                                      |
      | filled and set to null      | void f(void) { char *b; take(&b); b = NULL; }                                                                            |
      | filled again in a loop      | void f(void) { char *b = NULL; while (take(&b) < 0) retry(); free(b); }                                                 |
      | filled by a jumping call    | void f(void) { CC_OWNS char *b = NULL; take_or_jump(&b); free(b); }                                                     |
      | freed and filled again      | void f(void) { CC_OWNS char *b = malloc(8); renew(&b); free(b); }                                                       |
      | takes a pointer array       | void adopt_all(CC_OWNS char **v); void f(void) { CC_OWNS char **v = malloc(16); adopt_all(v); }                         |
      | handed out                  | int f(CC_OWNS_OUT char **out) { CC_OWNS char *p = malloc(8); if (!p) return -1; *out = p; return 0; }                    |
      | handed out as an item       | int f(CC_OWNS_OUT char **out) { CC_OWNS char *p = malloc(8); if (!p) return -1; out[0] = p; return 0; }                  |
      | handed out by ?:            | void f(CC_OWNS_OUT char **out, int n) { CC_OWNS char *p = malloc(8); *out = n ? p : NULL; if (!n) free(p); }            |
      | owning call handed out      | void f(CC_OWNS_OUT char **out, int n) { *out = make(n); }                                                                |
      | items of an owned array     | CC_OWNS char **f(CC_OWNS char *path, int n) { CC_OWNS char **v = calloc(n + 2, sizeof *v); if (!v) abort(); v[0] = path; for (int i = 1; i <= n; i++) v[i] = make(i); return v; } |
      | items of an allocated array | char **f(int n) { char **v = malloc(2 * sizeof *v); if (!v) return NULL; CC_OWNS char *p = malloc(n); v[0] = p; v[1] = make(n); return v; } |
      | item stored by ?:           | CC_OWNS char **f(int n) { CC_OWNS char **v = calloc(2, sizeof *v); if (!v) return NULL; CC_OWNS char *p = malloc(n); v[0] = n ? p : NULL; if (!n) free(p); return v; } |
      | stored by x ?: y            | void f(struct box *x, char *q) { CC_OWNS char *p = malloc(8); x->held = p ?: q; }                                        |
      | stored by a statement expr  | void f(struct box *x) { x->held = ({ CC_OWNS char *p = malloc(8); p; }); }                                               |

  Scenario: The path of a leak of a filled pointer starts at the call that set it
    Given the C file "out.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"

      int work(char *p);
      int take(CC_OWNS_OUT char **out);

      int f(void) {
        char *b;
        if (take(&b) < 0)
          return -1;
        if (work(b))
          return -1;
        free(b);
        return 0;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/out.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-OWN-LEAK","tool":"rules","file":"$DIR/out.c","line":7,"column":5,
      """
    And the output includes:
      """
      "path":["9:7 take sets b","9:7 false","11:7 true","12:5 returns"]
      """

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
      "incomplete_functions":[{"file":"$DIR/many.c","line":4,"function":"many"}]
      """
    And the errors include:
      """
      as they have more paths than the path rules follow: $DIR/many.c:4 many
      """

  Scenario: Conditions that are not read again leave the state of the ownership walk too
    The walk drops the flags that nothing reads again and keeps `done`, so the pointer is freed once on every path.

    Given the C file "flags.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"
      void work(int n);
      int many(int a0, int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9, int a10, int a11, int a12, int a13, int a14, int a15, int a16, int a17, int a18, int a19, int done) {
        CC_OWNS char *p = malloc(8);
        if (a0) work(1);
        if (a0) work(2);
        if (a1) work(1);
        if (a1) work(2);
        if (a2) work(1);
        if (a2) work(2);
        if (a3) work(1);
        if (a3) work(2);
        if (a4) work(1);
        if (a4) work(2);
        if (a5) work(1);
        if (a5) work(2);
        if (a6) work(1);
        if (a6) work(2);
        if (a7) work(1);
        if (a7) work(2);
        if (a8) work(1);
        if (a8) work(2);
        if (a9) work(1);
        if (a9) work(2);
        if (a10) work(1);
        if (a10) work(2);
        if (a11) work(1);
        if (a11) work(2);
        if (a12) work(1);
        if (a12) work(2);
        if (a13) work(1);
        if (a13) work(2);
        if (a14) work(1);
        if (a14) work(2);
        if (a15) work(1);
        if (a15) work(2);
        if (a16) work(1);
        if (a16) work(2);
        if (a17) work(1);
        if (a17) work(2);
        if (a18) work(1);
        if (a18) work(2);
        if (a19) work(1);
        if (a19) work(2);

        if (done) free(p);
        if (!done) free(p);
        return 0;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/flags.c -- -I../include"
    Then the exit code is 0
    And the output includes:
      """
      "incomplete_functions":[]
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

  Scenario Outline: A call that may jump out is a way out of the function too (<case>)
    Given the C file "jump.c" holds:
      """
      #include "stdlib.h"
      #include "string.h"
      #include "cchecker.h"
      struct conf { CC_OWNS char *path; int mode; };
      <mark> int as_mode(const char *text); <adopt> int adopt_mode(CC_OWNS struct conf *c, const char *text);
      <mark> CC_OWNS char *dup_mode(const char *text); <mark> int check_conf(struct conf *c); void keep(CC_OWNS struct conf *c);

      int start(const char *path, const char *mode) { <body> }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json jump.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      "CC-OWN-LEAK"
      """

    Examples:
      | case               | mark                    | adopt       | list                   | body                                                                                                                                          | exit | found            |
      | marked             | CC_MAY_JUMP             |             |                        | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); c->mode = as_mode(mode); keep(c); return 0;            | 1    | includes         |
      | listed             |                         |             | may_jump = ["as_mode"] | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); c->mode = as_mode(mode); keep(c); return 0;            | 1    | includes         |
      | lent to the call   | CC_MAY_JUMP             |             |                        | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; int r = check_conf(c); free(c); return r;                                      | 1    | includes         |
      | not marked         |                         |             |                        | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); c->mode = as_mode(mode); keep(c); return 0;            | 0    | does not include |
      | checked first      | CC_MAY_JUMP             |             |                        | int m = as_mode(mode); CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); c->mode = m; keep(c); return 0; | 0    | does not include |
      | handed on first    | CC_MAY_JUMP             |             |                        | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); keep(c); return as_mode(mode);                         | 0    | does not include |
      | taken by the call  |                         | CC_MAY_JUMP |                        | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); return adopt_mode(c, mode);                            | 0    | does not include |
      | result of the call | CC_MAY_JUMP             |             |                        | CC_OWNS char *p = dup_mode(mode); free(p); return 0;                                                                                          | 0    | does not include |
      | jumps              | CC_JUMPS                |             |                        | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); c->mode = as_mode(mode); keep(c); return 0;            | 1    | includes         |
      | listed as jumping  |                         |             | jumps = ["as_mode"]    | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); c->mode = as_mode(mode); keep(c); return 0;            | 1    | includes         |
      | never returns      | CC_NORETURN CC_MAY_JUMP |             |                        | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); c->mode = as_mode(mode); keep(c); return 0;            | 1    | includes         |
      | jumps in a ?:      | CC_JUMPS                |             |                        | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); c->mode = mode ? as_mode(mode) : 0; keep(c); return 0; | 1    | includes         |
      | only never returns | CC_NORETURN             |             |                        | CC_OWNS struct conf *c = malloc(sizeof *c); if (!c) return -1; c->path = strdup(path); c->mode = as_mode(mode); keep(c); return 0;            | 0    | does not include |

  Scenario Outline: A function that calls a function that may jump out may jump out too (<case>)
    Given the C file "chain.c" holds:
      """
      #include "stdlib.h"
      #include "setjmp.h"
      #include "cchecker.h"
      jmp_buf env;
      <raiser> void wrong_tag(int v);
      <helper> int as_string(int v) { <check> return v; }
      int path_of(int v) { return as_string(v) + 1; }
      void keep(CC_OWNS char *p);
      int start(int v) { CC_OWNS char *b = malloc(8); if (!b) return -1; b[0] = (char)path_of(v); keep(b); return 0; }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json chain.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      "CC-OWN-LEAK"
      """
    And the output <found>:
      """
      may jump in path_of (as_string, wrong_tag)"]
      """

    Examples:
      | case               | raiser      | helper     | check                                              | list                     | exit | found            |
      | jumps              | CC_JUMPS    |            | if (v < 0) wrong_tag(v);                           |                          | 1    | includes         |
      | may jump           | CC_MAY_JUMP |            | wrong_tag(v);                                      |                          | 1    | includes         |
      | listed             |             |            | if (v < 0) wrong_tag(v);                           | jumps = ["wrong_tag"]    | 1    | includes         |
      | not marked         |             |            | if (v < 0) wrong_tag(v);                           |                          | 0    | does not include |
      | caught             | CC_JUMPS    |            | if (setjmp(env)) return -1; if (v < 0) wrong_tag(v); |                        | 0    | does not include |
      | marked as catching | CC_JUMPS    | CC_CATCHES | if (v < 0) wrong_tag(v);                           |                          | 0    | does not include |
      | listed as catching | CC_JUMPS    |            | if (v < 0) wrong_tag(v);                           | catches = ["as_string"]  | 0    | does not include |
      | not walked         | CC_JUMPS    | CC_STOP    | if (v < 0) wrong_tag(v);                           |                          | 0    | does not include |

  Scenario Outline: A function that never returns and calls a function that jumps out is a way out where the path ends (<case>)
    Given the C file "raise.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      <mark> void fail(const char *what);
      _Noreturn void bad_signature(int n) { <raise> }
      int build(int n) { CC_OWNS char *b = malloc(n); if (!b) return -1; if (n > 8) { free(b); bad_signature(n); } if (n > 4) bad_signature(n); free(b); return 0; }
      """
    When I run cchecker in its folder with "--tools rules --json raise.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      may jump in bad_signature (fail), never returns"]
      """
    And the output does not include:
      """
      "CC-OWN-DOUBLE-FREE"
      """

    Examples:
      | case       | mark     | raise              | exit | found            |
      | jumps      | CC_JUMPS | fail("signature"); | 1    | includes         |
      | not marked |          | fail("signature"); | 0    | does not include |
      | exits      | CC_JUMPS | abort();           | 0    | does not include |
      | exits      | CC_JUMPS | exit(1);           | 0    | does not include |

  Scenario Outline: The inference of jumps goes round a cycle of calls, and names at most three of the chain (<case>)
    Given the C file "cycle.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      <mark> void fail(void);
      int b(int n);
      int a(int n) { if (n > 2) return a(n - 1); return b(n); }
      int b(int n) { if (0 > n) fail(); return n > 1 ? a(n - 1) : n; }
      int w(int n) { if (0 > n) fail(); return n; }
      int x(int n) { return w(n) + 1; }
      int y(int n) { return x(n) + 1; }
      int z(int n) { return y(n) + 1; }
      int start(int n) { CC_OWNS char *p = malloc(8); if (!p) return -1; p[0] = (char)<call>; free(p); return 0; }
      """
    And the file "cchecker.toml" holds:
      """
      [library]
      may_jump_callers = <infer>
      """
    When I run cchecker in its folder with "--tools rules --json cycle.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      <step>"],"source":"may_jump_callers"
      """

    Examples:
      | case                | mark     | call | infer | exit | found            | step                          |
      | cycle               | CC_JUMPS | a(n) | true  | 1    | includes         | may jump in a (b, fail)       |
      | long chain          | CC_JUMPS | z(n) | true  | 1    | includes         | may jump in z (y, x, w, ...)  |
      | not marked          |          | a(n) | true  | 0    | does not include | may jump in a                 |
      | inference turned off | CC_JUMPS | a(n) | false | 0    | does not include | may jump in a                 |

  Scenario: A chain through a static function that another file has too names it by its file
    Given the C file "a.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      CC_JUMPS void fail(void);
      static int helper(int v) { if (v < 0) fail(); return v; }
      int outer_a(int v) { return helper(v) + 1; }
      int run_a(int v) { CC_OWNS char *p = malloc(8); if (!p) return -1; p[0] = (char)outer_a(v); free(p); return 0; }
      """
    And the C file "b.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      static int helper(int v) { return v; }
      int outer_b(int v) { return helper(v) + 1; }
      int run_b(int v) { CC_OWNS char *p = malloc(8); if (!p) return -1; p[0] = (char)outer_b(v); free(p); return 0; }
      """
    When I run cchecker in its folder with "--tools rules --json a.c b.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      may jump in outer_a (helper@a.c, fail)"]
      """
    And the output does not include:
      """
      run_b
      """

  Scenario Outline: No path goes on after a call that jumps out and never returns (<case>)
    Given the C file "jump.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      <mark> void bad_signature(const char *what);
      int build(int n) { CC_OWNS char *b = malloc(n); if (!b) return -1; if (n > 8) { free(b); bad_signature("size"); } free(b); return 0; }
      """
    And the file "cchecker.toml" holds:
      """
      [assume]
      <list>
      """
    When I run cchecker in its folder with "--tools rules --json jump.c -- -I../../../include"
    Then the exit code is <exit>
    And the output <found>:
      """
      "CC-OWN-DOUBLE-FREE"
      """

    Examples:
      | case              | mark        | list                        | exit | found            |
      | jumps             | CC_JUMPS    |                             | 0    | does not include |
      | listed as jumping |             | jumps = ["bad_signature"]   | 0    | does not include |
      | may jump          | CC_MAY_JUMP |                             | 1    | includes         |

  Scenario: A pointer that leaks on a jump and on a return is one finding
    Given the C file "jump.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"
      CC_MAY_JUMP int as_mode(const char *text);
      int start(const char *mode) { CC_OWNS char *c = malloc(8); if (!c) return -1; c[0] = (char)as_mode(mode); return 0; }
      """
    When I run cchecker with "--tools rules --json $DIR/jump.c -- -I../include"
    Then the exit code is 1
    And the output includes once:
      """
      "code":"CC-OWN-LEAK"
      """

  Scenario Outline: The path of a leak on a jump ends at the call that jumps (<mark>)
    Given the C file "jump.c" holds:
      """
      #include "stdlib.h"
      #include "string.h"
      #include "cchecker.h"

      struct conf { CC_OWNS char *path; int mode; };
      <mark> int as_mode(const char *text);
      void keep(CC_OWNS struct conf *c);

      int start(const char *path, const char *mode) {
        CC_OWNS struct conf *c = malloc(sizeof *c);
        if (!c)
          return -1;
        c->path = strdup(path);
        c->mode = as_mode(mode);
        keep(c);
        return 0;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/jump.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-OWN-LEAK","tool":"rules","file":"$DIR/jump.c","line":9,"column":5,
      """
    And the output includes:
      """
      "path":["10:28 c = malloc","11:8 true","14:13 <step> as_mode"]
      """

    Examples:
      | mark        | step        |
      | CC_MAY_JUMP | may jump in |
      | CC_JUMPS    | jumps in    |
