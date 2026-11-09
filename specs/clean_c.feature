Feature: C that must stay clean
  A corpus of common C idioms that the rules must give no finding on. Each row is one small function. A false finding
  that a review or a user finds becomes a row here, and a new rule gets rows for the idioms near it. A row is worth
  keeping when a small change to it gives a finding: the second outline holds that change for the rows that have one
  (its `case` is the name of the clean row), so a clean row cannot pass because the rules do not look, the C does not
  compile (exit 2) or the lines above the function are broken. A row named `... parses` only says that the rules read
  the C. A row that does not pass yet stays, in an `Examples` block tagged `@pending` and with its issue (`@issue-N`):
  `make test` leaves those out, `make test-pending` fails when one of them passes, and the PR that closes the issue
  moves its rows up.

  Scenario Outline: A common idiom gives no finding (<case>)
    Given the C file "clean.c" holds:
      """
      #include <stdlib.h>
      #include <string.h>
      #include "cchecker.h"
      struct pair { CC_OWNS char *left; CC_OWNS char *right; };
      struct box { CC_OWNS char *held; };
      struct conf { const char *name; int n; };
      CC_OWNS char *make(int n); int work(char *p); void use(const struct conf *c); void keep(struct pair *p);
      void adopt(CC_OWNS char *p); void zap(CC_FREES char **p); char *stpcpy(char *dest, const char *src);
      static inline void freep(CC_FREES void *p) { free(*(void **)p); }
      static inline void pair_done(struct pair *p) { free(p->left); free(p->right); }
      #define _cleanup_free_ __attribute__((cleanup(freep)))
      #define TAKE_PTR(p) ({ __typeof__(p) t_ = (p); (p) = NULL; t_; })
      #define TAKE(n) ({ CC_OWNS char *t_ = make(n); t_; })
      #define XMAKE(n) ({ CC_OWNS char *x_ = malloc(n); x_; })

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/clean.c -- -I../include"
    Then the exit code is 0

    Examples:
      | case                                            | code                                                                                                                                                                                                           |
      | cleanup on a pointer                            | void f(int n) { CC_OWNS char *b __attribute__((cleanup(freep))) = malloc(n); work(b); }                                                                                                                        |
      | cleanup by a macro                              | void f(int n) { _cleanup_free_ CC_OWNS char *b = malloc(n); work(b); }                                                                                                                                         |
      | goto cleanup                                    | int f(int n) { int rc = -1; CC_OWNS char *a = NULL; CC_OWNS char *b = NULL; a = malloc(n); if (!a) goto out; b = malloc(n); if (!b) goto out; rc = work(a) + work(b); out: free(a); free(b); return rc; }      |
      | two names for a statement expression            | CC_OWNS char *f(int n, const char *a) { char *out = XMAKE(n), *cur = out; cur = stpcpy(cur, a); return out; }                                                                                                  |
      | statement expression freed                      | void f(int n) { free(TAKE(n)); }                                                                                                                                                                               |
      | statement expression taken                      | void f(int n) { adopt(TAKE(n)); }                                                                                                                                                                              |
      | one side of ?: returned                         | CC_OWNS char *f(int n) { return n ? TAKE(n) : NULL; }                                                                                                                                                          |
      | pointer or NULL returned                        | CC_OWNS char *f(int n) { CC_OWNS char *p = malloc(n); return p ? p : NULL; }                                                                                                                                   |
      | label on the value of a statement expression    | void f(int n) { CC_OWNS char *u = make(n); free(({ if (work(u)) goto done; work(u); done: u; })); }                                                                                                            |
      | address in a statement expression               | void f(int n) { CC_OWNS char *b = malloc(n); zap(({ &b; })); }                                                                                                                                                 |
      | realloc in a loop                               | CC_OWNS char *f(int n) { CC_OWNS char *b = NULL; for (int i = 1; i <= n; i++) { char *t = realloc(b, i); if (!t) { free(b); return NULL; } b = t; } return b; }                                                |
      | free in a loop with switch and continue         | void f(int n) { for (int i = 0; i < n; i++) { CC_OWNS char *b = malloc(n); if (!b) continue; switch (work(b)) { case 0: free(b); continue; case 1: free(b); break; default: free(b); return; } work(NULL); } } |
      | strdup                                          | CC_OWNS char *f(const char *s) { CC_OWNS char *c = strdup(s); if (!c) return NULL; if (work(c)) { free(c); return NULL; } return c; }                                                                          |
      | designated initializer of a plain struct parses | void f(int n) { struct conf c = { .name = "x", .n = n }; use(&c); }                                                                                                                                            |

    # The CC_OWNS fields of a local struct. The rules follow them from #110 on: before it these rows pass because
    # a store into such a field hands the pointer on, and their twins that leak come with #110.
    Examples:
      | case                                  | code                                                                                                                                                                                        |
      | cleanup on a struct                   | void f(int n) { __attribute__((cleanup(pair_done))) struct pair p = {0}; p.left = make(n); work(p.left); }                                                                                  |
      | TAKE_PTR by hand of a field           | CC_OWNS char *f(int n) { struct pair p = {0}; p.left = make(n); char *out = p.left; p.left = NULL; return out; }                                                                            |
      | goto cleanup of struct fields         | int f(int n) { int rc = -1; struct pair p = {0}; p.left = make(n); if (!p.left) goto out; p.right = make(n); if (!p.right) goto out; rc = 0; out: free(p.left); free(p.right); return rc; } |
      | field freed through a local           | void f(int n) { struct pair p = {0}; p.left = make(n); char *q = p.left; free(q); }                                                                                                         |
      | struct filled, then passed by pointer | void f(int n) { struct pair p = {0}; p.left = make(n); keep(&p); }                                                                                                                          |

    # TAKE_PTR of a CC_OWNS local: `t_ = b; b = NULL` reads as a lost value (#115).
    @pending @issue-115
    Examples:
      | case                       | code                                                                                                                   |
      | TAKE_PTR returned          | CC_OWNS char *f(int n) { CC_OWNS char *b = malloc(n); if (!b) return NULL; return TAKE_PTR(b); }                       |
      | TAKE_PTR stored in a field | void f(struct box *x, int n) { CC_OWNS char *b = malloc(n); if (!b) return; x->held = TAKE_PTR(b); }                   |
      | TAKE_PTR handed out        | int f(CC_OWNS_OUT char **out, int n) { CC_OWNS char *b = malloc(n); if (!b) return -1; *out = TAKE_PTR(b); return 0; } |

    # The state of a closing block's pointer goes to the alias that holds it (#107).
    @pending @issue-107
    Examples:
      | case                          | code                                                                                                                                  |
      | last round kept in a variable | void f(int n) { char *prev = NULL; for (int i = 0; i < n; i++) { CC_OWNS char *cur = make(i); free(prev); prev = cur; } free(prev); } |

  Scenario Outline: The same idiom with a small change gives a finding (<case>: <change>)
    Given the C file "clean.c" holds:
      """
      #include <stdlib.h>
      #include <string.h>
      #include "cchecker.h"
      struct pair { CC_OWNS char *left; CC_OWNS char *right; };
      struct box { CC_OWNS char *held; };
      struct conf { const char *name; int n; };
      CC_OWNS char *make(int n); int work(char *p); void use(const struct conf *c); void keep(struct pair *p);
      void adopt(CC_OWNS char *p); void zap(CC_FREES char **p); char *stpcpy(char *dest, const char *src);
      static inline void freep(CC_FREES void *p) { free(*(void **)p); }
      static inline void pair_done(struct pair *p) { free(p->left); free(p->right); }
      #define _cleanup_free_ __attribute__((cleanup(freep)))
      #define TAKE_PTR(p) ({ __typeof__(p) t_ = (p); (p) = NULL; t_; })
      #define TAKE(n) ({ CC_OWNS char *t_ = make(n); t_; })
      #define XMAKE(n) ({ CC_OWNS char *x_ = malloc(n); x_; })

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/clean.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-OWN-LEAK","tool":"rules","file":"$DIR/clean.c","line":16,
      """

    Examples:
      | case                                         | change                               | code                                                                                                                                                                                             |
      | cleanup on a pointer                         | no cleanup                           | void f(int n) { CC_OWNS char *b = malloc(n); work(b); }                                                                                                                                          |
      | goto cleanup                                 | one free missing at the label        | int f(int n) { int rc = -1; CC_OWNS char *a = NULL; CC_OWNS char *b = NULL; a = malloc(n); if (!a) goto out; b = malloc(n); if (!b) goto out; rc = work(a) + work(b); out: free(a); return rc; } |
      | two names for a statement expression         | the moved name returned              | char *f(int n, const char *a) { char *out = XMAKE(n), *cur = out; cur = stpcpy(cur, a); return cur; }                                                                                            |
      | statement expression freed                   | lent, not freed                      | void f(int n) { work(TAKE(n)); }                                                                                                                                                                 |
      | one side of ?: returned                      | the other side loses it              | CC_OWNS char *f(int n) { CC_OWNS char *p = make(n); return n ? p : NULL; }                                                                                                                       |
      | label on the value of a statement expression | lent, not freed                      | void f(int n) { CC_OWNS char *u = make(n); work(({ if (work(u)) goto done; work(u); done: u; })); }                                                                                              |
      | address in a statement expression            | the pointer, not its address         | void f(int n) { CC_OWNS char *b = malloc(n); work(({ b; })); }                                                                                                                                   |
      | realloc in a loop                            | no free when realloc fails           | CC_OWNS char *f(int n) { CC_OWNS char *b = NULL; for (int i = 1; i <= n; i++) { char *t = realloc(b, i); if (!t) return NULL; b = t; } return b; }                                               |
      | free in a loop with switch and continue      | a case that continues without a free | void f(int n) { for (int i = 0; i < n; i++) { CC_OWNS char *b = malloc(n); if (!b) continue; switch (work(b)) { case 0: continue; default: free(b); break; } } }                                 |
      | strdup                                       | returned without a free              | int f(const char *s) { CC_OWNS char *c = strdup(s); if (!c) return -1; return work(c); }                                                                                                         |
