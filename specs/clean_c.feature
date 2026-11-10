Feature: C that must stay clean
  A corpus of common C idioms that the rules must give no finding on. Each row is one small function. A false finding
  that a review or a user finds becomes a row here, and a new rule gets rows for the idioms near it. A row is worth
  keeping when one change to it gives a finding: the second outline holds that change for the rows that have one
  (its `case` is the name of the clean row), so a clean row cannot pass because the rules do not look, the C does not
  compile (exit 2) or the lines above the function are broken. A row named `... parses` only says that the rules read
  the C. A row that does not pass yet stays, in an `Examples` block with the tags pending and issue-N: `make test`
  leaves those out, `make test-pending` fails when one of them passes, and the PR that closes the issue moves its
  rows up.

  Scenario Outline: A common idiom gives no finding (<case>)
    Given the C file "clean.c" holds:
      """
      #include <stdlib.h>
      #include <string.h>
      #include "cchecker.h"
      struct pair { CC_OWNS char *left; CC_OWNS char *right; };
      struct box { CC_OWNS char *held; char *loose; };
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
      | one macro into one variable                     | void f(int n) { char *s; s = TAKE(n); if (s) free(s); s = TAKE(n); if (s) free(s); s = TAKE(n); if (s) free(s); }                                                                                              |
      | designated initializer of a plain struct parses | void f(int n) { struct conf c = { .name = "x", .n = n }; use(&c); }                                                                                                                                            |

    # Initializers that the rules read by the name of a top-level struct (#111): a struct of a function body, an
    # anonymous member, a union, and a key on the stack whose field takes the pointer while the function frees it.
    @pending @issue-111
    Examples:
      | case                            | code                                                                                                                                                                                    |
      | struct declared in the function | void submit(void *j); void f(int n) { struct job { CC_OWNS char *buf; }; CC_OWNS char *b = make(n); struct job j = { b }; submit(&j); }                                                 |
      | anonymous struct member         | struct conn { int fd; struct { CC_OWNS char *buf; }; }; void sink(struct conn *c); void f(int n) { CC_OWNS char *b = make(n); struct conn c = { n, { b } }; sink(&c); }                 |
      | union initializer               | union u { CC_OWNS char *p; long l; }; void sink(union u *v); void f(int n) { CC_OWNS char *b = make(n); union u v = { .p = b }; sink(&v); }                                             |
      | lookup key on the stack         | struct entry { CC_OWNS char *name; }; struct entry *find(struct entry *k); void f(int n) { CC_OWNS char *name = make(n); struct entry key = { .name = name }; find(&key); free(name); } |

    # The CC_OWNS fields of a local struct (#110), and a local that keeps the old value of a pointer that gets a new
    # one (the last round of a loop, TAKE_PTR of a CC_OWNS local: #107, #115).
    Examples:
      | case                                                             | code                                                                                                                                                                                                |
      | cleanup on a struct                                              | void f(int n) { __attribute__((cleanup(pair_done))) struct pair p = {0}; p.left = make(n); work(p.left); }                                                                                          |
      | TAKE_PTR by hand of a field                                      | CC_OWNS char *f(int n) { struct pair p = {0}; p.left = make(n); char *out = p.left; p.left = NULL; return out; }                                                                                    |
      | goto cleanup of struct fields                                    | int f(int n) { int rc = -1; struct pair p = {0}; p.left = make(n); if (!p.left) goto out; p.right = make(n); if (!p.right) goto out; rc = 0; out: free(p.left); free(p.right); return rc; }         |
      | field freed through a local                                      | void f(int n) { struct pair p = {0}; p.left = make(n); char *q = p.left; free(q); }                                                                                                                 |
      | struct filled, then passed by pointer                            | void f(int n) { struct pair p = {0}; p.left = make(n); keep(&p); }                                                                                                                                  |
      | struct lent, then its fields freed                               | void f(int n) { struct pair p = {0}; keep(&p); free(p.left); free(p.right); }                                                                                                                       |
      | struct returned by value                                         | struct pair f(int n) { struct pair p = {0}; p.left = make(n); return p; }                                                                                                                           |
      | struct copied, then passed                                       | void f(int n) { struct pair p = {0}; p.left = make(n); struct pair q = p; keep(&q); }                                                                                                               |
      | store after the struct was lent                                  | void f(int n) { struct pair p = {0}; keep(&p); p.left = make(n); }                                                                                                                                  |
      | store after a null test of a lent struct                         | void f(int n) { struct pair p = {0}; keep(&p); if (!p.left) p.left = make(n); }                                                                                                                     |
      | struct moved out, then reset                                     | void f(int n) { struct pair p = {0}, q = {0}; p.left = make(n); q = p; p = (struct pair){0}; keep(&q); }                                                                                            |
      | structs swapped                                                  | void f(int n) { struct pair p = {0}, q = {0}, t; p.left = make(n); q.left = make(n); t = p; p = q; q = t; keep(&p); keep(&q); }                                                                     |
      | struct in an asm operand                                         | void f(int n) { struct pair p = {0}; p.left = make(n); __asm__ volatile("" : : "r"(&p) : "memory"); }                                                                                               |
      | block tag that shadows a struct with CC_OWNS fields              | void g(void *p); void f(int n) { struct pair { int k; } p = { n }; if (n < 0) return; g(&p); }                                                                                                      |
      | typedef named like the tag of another struct                     | typedef struct pair other; struct other { int k; }; void g(void *p); void f(int n) { struct other o = { n }; if (n < 0) return; g(&o); }                                                            |
      | memset of a struct, then filled and lent (escapes at the memset) | void f(int n) { struct pair p; memset(&p, 0, sizeof p); p.left = make(n); keep(&p); }                                                                                                               |
      | a cast to void of a struct is an escape (it hides this leak)     | void f(int n) { struct pair p = {0}; p.left = make(n); (void)p; }                                                                                                                                   |
      | last round kept in a variable                                    | void f(int n) { char *prev = NULL; for (int i = 0; i < n; i++) { CC_OWNS char *cur = make(i); free(prev); prev = cur; } free(prev); }                                                               |
      | last round filled into a variable                                | int take(CC_OWNS_OUT char **out); void f(int n) { char *prev = NULL; for (int i = 0; i < n; i++) { CC_OWNS char *cur; if (take(&cur) < 0) break; work(cur); free(prev); prev = cur; } free(prev); } |
      | TAKE_PTR returned                                                | CC_OWNS char *f(int n) { CC_OWNS char *b = malloc(n); if (!b) return NULL; return TAKE_PTR(b); }                                                                                                    |
      | TAKE_PTR stored in a field                                       | void f(struct box *x, int n) { CC_OWNS char *b = malloc(n); if (!b) return; x->held = TAKE_PTR(b); }                                                                                                |
      | TAKE_PTR handed out                                              | int f(CC_OWNS_OUT char **out, int n) { CC_OWNS char *b = malloc(n); if (!b) return -1; *out = TAKE_PTR(b); return 0; }                                                                              |
      | old value kept in a local                                        | void f(int n) { CC_OWNS char *b = malloc(n); char *old = b; b = malloc(n); free(b); free(old); }                                                                                                    |


  Scenario Outline: The same idiom with one change gives a finding (<case>: <change>)
    Given the C file "clean.c" holds:
      """
      #include <stdlib.h>
      #include <string.h>
      #include "cchecker.h"
      struct pair { CC_OWNS char *left; CC_OWNS char *right; };
      struct box { CC_OWNS char *held; char *loose; };
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
      | case                                                | change                               | code                                                                                                                                                                                                  |
      | cleanup on a pointer                                | no cleanup                           | void f(int n) { CC_OWNS char *b = malloc(n); work(b); }                                                                                                                                               |
      | goto cleanup                                        | one free missing at the label        | int f(int n) { int rc = -1; CC_OWNS char *a = NULL; CC_OWNS char *b = NULL; a = malloc(n); if (!a) goto out; b = malloc(n); if (!b) goto out; rc = work(a) + work(b); out: free(a); return rc; }      |
      | two names for a statement expression                | the moved name returned              | CC_OWNS char *f(int n, const char *a) { char *out = XMAKE(n), *cur = out; cur = stpcpy(cur, a); return cur; }                                                                                         |
      | statement expression freed                          | lent, not freed                      | void f(int n) { work(TAKE(n)); }                                                                                                                                                                      |
      | pointer or NULL returned                            | the test is not on p                 | CC_OWNS char *f(int n) { CC_OWNS char *p = malloc(n); return n ? p : NULL; }                                                                                                                          |
      | label on the value of a statement expression        | lent, not freed                      | void f(int n) { CC_OWNS char *u = make(n); work(({ if (work(u)) goto done; work(u); done: u; })); }                                                                                                   |
      | address in a statement expression                   | the address of another pointer       | void f(int n) { CC_OWNS char *b = malloc(n); char *c = NULL; zap(({ &c; })); }                                                                                                                        |
      | realloc in a loop                                   | no free when realloc fails           | CC_OWNS char *f(int n) { CC_OWNS char *b = NULL; for (int i = 1; i <= n; i++) { char *t = realloc(b, i); if (!t) { return NULL; } b = t; } return b; }                                                |
      | free in a loop with switch and continue             | no free in case 0                    | void f(int n) { for (int i = 0; i < n; i++) { CC_OWNS char *b = malloc(n); if (!b) continue; switch (work(b)) { case 0: continue; case 1: free(b); break; default: free(b); return; } work(NULL); } } |
      | strdup                                              | no free when work fails              | CC_OWNS char *f(const char *s) { CC_OWNS char *c = strdup(s); if (!c) return NULL; if (work(c)) { return NULL; } return c; }                                                                          |
      | cleanup on a struct                                 | no cleanup                           | void f(int n) { struct pair p = {0}; p.left = make(n); work(p.left); }                                                                                                                                |
      | TAKE_PTR by hand of a field                         | the taken value dropped              | CC_OWNS char *f(int n) { struct pair p = {0}; p.left = make(n); char *out = p.left; p.left = NULL; work(out); return NULL; }                                                                          |
      | goto cleanup of struct fields                       | one free missing at the label        | int f(int n) { int rc = -1; struct pair p = {0}; p.left = make(n); if (!p.left) goto out; p.right = make(n); if (!p.right) goto out; rc = 0; out: free(p.left); return rc; }                          |
      | struct filled, then passed by pointer               | a return before the struct is passed | void f(int n) { struct pair p = {0}; p.left = make(n); if (n) return; keep(&p); }                                                                                                                     |
      | struct lent, then its fields freed                  | a field set before an early return   | void f(int n) { struct pair p = {0}; p.left = make(n); if (n) return; keep(&p); free(p.left); free(p.right); }                                                                                        |
      | struct returned by value                            | another struct returned first        | struct pair f(int n) { struct pair p = {0}, q = {0}; p.left = make(n); if (n > 1) return q; return p; }                                                                                               |
      | struct copied, then passed                          | a return before the copy             | void f(int n) { struct pair p = {0}; p.left = make(n); if (n) return; struct pair q = p; keep(&q); }                                                                                                  |
      | store after the struct was lent                     | not lent                             | void f(int n) { struct pair p = {0}; p.left = make(n); }                                                                                                                                              |
      | store after a null test of a lent struct            | not lent                             | void f(int n) { struct pair p = {0}; if (!p.left) p.left = make(n); }                                                                                                                                 |
      | struct moved out, then reset                        | reset without the move               | void f(int n) { struct pair p = {0}, q = {0}; p.left = make(n); p = (struct pair){0}; keep(&q); }                                                                                                     |
      | structs swapped                                     | no temporary                         | void f(int n) { struct pair p = {0}, q = {0}, t = {0}; p.left = make(n); q.left = make(n); p = q; q = t; keep(&p); keep(&q); }                                                                        |
      | struct in an asm operand                            | no asm                               | void f(int n) { struct pair p = {0}; p.left = make(n); }                                                                                                                                              |
      | block tag that shadows a struct with CC_OWNS fields | the outer struct                     | void g(void *p); void f(int n) { struct pair p = { make(n) }; if (n < 0) return; g(&p); }                                                                                                             |
      | typedef named like the tag of another struct        | the typedef used                     | typedef struct pair other; void g(void *p); void f(int n) { other o = { make(n) }; if (n < 0) return; g(&o); }                                                                                        |
      | field freed through a local                         | lent, not freed                      | void f(int n) { struct pair p = {0}; p.left = make(n); char *q = p.left; work(q); }                                                                                                                   |
      | last round kept in a variable                       | the last round not freed             | void f(int n) { char *prev = NULL; for (int i = 0; i < n; i++) { CC_OWNS char *cur = make(i); free(prev); prev = cur; } }                                                                             |
      | last round filled into a variable                   | the last round not freed             | int take(CC_OWNS_OUT char **out); void f(int n) { char *prev = NULL; for (int i = 0; i < n; i++) { CC_OWNS char *cur; if (take(&cur) < 0) break; work(cur); free(prev); prev = cur; } }               |
      | one macro into one variable                         | the first use not freed              | void f(int n) { char *s; s = TAKE(n); s = TAKE(n); if (s) free(s); s = TAKE(n); if (s) free(s); }                                                                                                     |
      | TAKE_PTR returned                                   | the taken value lent                 | CC_OWNS char *f(int n) { CC_OWNS char *b = malloc(n); if (!b) return NULL; work(TAKE_PTR(b)); return NULL; }                                                                                          |
      | TAKE_PTR handed out                                 | the taken value not handed out       | int f(CC_OWNS_OUT char **out, int n) { CC_OWNS char *b = malloc(n); if (!b) return -1; char *t = TAKE_PTR(b); work(t); *out = NULL; return 0; }                                                       |
      | TAKE_PTR stored in a field                          | the taken value not stored           | void f(struct box *x, int n) { CC_OWNS char *b = malloc(n); if (!b) return; char *t = TAKE_PTR(b); work(t); x->held = NULL; }                                                                         |
      | TAKE_PTR stored in a field                          | a field that does not own            | void f(struct box *x, int n) { CC_OWNS char *b = malloc(n); if (!b) return; x->loose = TAKE_PTR(b); }                                                                                                 |
      | TAKE_PTR handed out                                 | no CC_OWNS_OUT on the parameter      | int f(char **out, int n) { CC_OWNS char *b = malloc(n); if (!b) return -1; *out = TAKE_PTR(b); return 0; }                                                                                            |
      | old value kept in a local                           | no free of the local                 | void f(int n) { CC_OWNS char *b = malloc(n); char *old = b; b = malloc(n); free(b); }                                                                                                                 |
