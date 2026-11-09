Feature: C that must stay clean
  A corpus of common C idioms that the rules must give no finding on. Each row is one small function. A false finding
  that a review or a user finds becomes a row here, and a new rule gets rows for the idioms near it. A row that does
  not pass yet stays, in an `Examples` block tagged `@pending` and with its issue (`@issue-N`): `make test` leaves
  those out, and the PR that closes the issue moves its rows up.

  Scenario Outline: A common idiom gives no finding (<case>)
    Given the C file "clean.c" holds:
      """
      #include <stdlib.h>
      #include <string.h>
      #include "cchecker.h"
      struct pair { CC_OWNS char *left; CC_OWNS char *right; };
      struct conf { const char *name; int n; };
      CC_OWNS char *make(int n); int work(char *p); void use(const struct conf *c); void keep(struct pair *p);
      void adopt(CC_OWNS char *p); void zap(CC_FREES char **p); char *stpcpy(char *dest, const char *src);
      static inline void freep(void *p) { free(*(void **)p); }
      static inline void pair_done(struct pair *p) { free(p->left); free(p->right); }
      #define TAKE_PTR(p) ({ __typeof__(p) t_ = (p); (p) = NULL; t_; })
      #define TAKE(n) ({ CC_OWNS char *t_ = make(n); t_; })
      #define XMAKE(n) ({ CC_OWNS char *x_ = malloc(n); x_; })

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/clean.c -- -I../include"
    Then the exit code is 0

    Examples:
      | case                                         | code                                                                                                                                                                                                      |
      | cleanup on a pointer                         | void f(int n) { __attribute__((cleanup(freep))) char *b = malloc(n); work(b); }                                                                                                                           |
      | cleanup on a struct                          | void f(int n) { __attribute__((cleanup(pair_done))) struct pair p = {0}; p.left = make(n); work(p.left); }                                                                                                |
      | TAKE_PTR by hand of a field                  | CC_OWNS char *f(int n) { struct pair p = {0}; p.left = make(n); char *out = p.left; p.left = NULL; return out; }                                                                                          |
      | designated initializer of a plain struct     | void f(int n) { struct conf c = { .name = "x", .n = n }; use(&c); }                                                                                                                                       |
      | goto cleanup                                 | int f(int n) { int rc = -1; CC_OWNS char *a = NULL; CC_OWNS char *b = NULL; a = malloc(n); if (!a) goto out; b = malloc(n); if (!b) goto out; rc = work(a) + work(b); out: free(a); free(b); return rc; } |
      | goto cleanup of struct fields                | int f(int n) { int rc = -1; struct pair p = {0}; p.left = make(n); if (!p.left) goto out; p.right = make(n); if (!p.right) goto out; rc = 0; out: free(p.left); free(p.right); return rc; }               |
      | two names for a statement expression         | CC_OWNS char *f(int n, const char *a) { char *out = XMAKE(n), *cur = out; cur = stpcpy(cur, a); return out; }                                                                                             |
      | statement expression freed                   | void f(int n) { free(TAKE(n)); }                                                                                                                                                                          |
      | statement expression taken                   | void f(int n) { adopt(TAKE(n)); }                                                                                                                                                                         |
      | one side of ?: returned                      | CC_OWNS char *f(int n) { return n ? TAKE(n) : NULL; }                                                                                                                                                     |
      | pointer or NULL returned                     | CC_OWNS char *f(int n) { CC_OWNS char *p = malloc(n); return p ? p : NULL; }                                                                                                                              |
      | label on the value of a statement expression | void f(int n) { CC_OWNS char *u = make(n); free(({ if (work(u)) goto done; work(u); done: u; })); }                                                                                                       |
      | address in a statement expression            | void f(int n) { CC_OWNS char *b = malloc(n); zap(({ &b; })); free(b); }                                                                                                                                   |
      | realloc into a temporary                     | int f(int n) { CC_OWNS char *b = malloc(n); if (!b) return -1; char *t = realloc(b, 2 * n); if (!t) { free(b); return -1; } b = t; free(b); return 0; }                                                   |
      | realloc in place                             | void f(int n) { CC_OWNS char *b = malloc(n); b = realloc(b, 2 * n); free(b); }                                                                                                                            |
      | realloc in a loop                            | CC_OWNS char *f(int n) { CC_OWNS char *b = NULL; for (int i = 1; i <= n; i++) { char *t = realloc(b, i); if (!t) { free(b); return NULL; } b = t; } return b; }                                           |
      | field freed through a local                  | void f(int n) { struct pair p = {0}; p.left = make(n); char *q = p.left; free(q); }                                                                                                                       |
      | struct filled, then passed by pointer        | void f(int n) { struct pair p = {0}; p.left = make(n); keep(&p); }                                                                                                                                        |
      | plain struct filled, then passed by pointer  | void f(int n) { struct conf c; c.name = "x"; c.n = n; use(&c); }                                                                                                                                          |

    # Ownership of the CC_OWNS fields of a local struct (#90).
    @pending @issue-90
    Examples:
      | case                   | code                                                                                             |
      | TAKE_PTR of a local    | CC_OWNS char *f(int n) { CC_OWNS char *b = malloc(n); if (!b) return NULL; return TAKE_PTR(b); } |
      | designated initializer | void f(int n) { struct pair p = { .left = make(n) }; work(p.left); free(p.left); }               |

    # The state of a closing block's pointer goes to the alias that holds it (#107).
    @pending @issue-107
    Examples:
      | case                          | code                                                                                                                                  |
      | last round kept in a variable | void f(int n) { char *prev = NULL; for (int i = 0; i < n; i++) { CC_OWNS char *cur = make(i); free(prev); prev = cur; } free(prev); } |
