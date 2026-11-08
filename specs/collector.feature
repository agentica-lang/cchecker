Feature: Values of the collector kept where it sees them
  CC_GC on a struct, a union or a typedef says that the collector manages its values: a value of the type, a pointer
  to it, or a struct that holds one. CC_GC_ALLOC on a function says that it returns memory of the collector, and so do
  the allocators of the Boehm collector (`GC_malloc`). Such a value is never stored in memory from `malloc` (a pointer
  that got it from `malloc`, `calloc`, `realloc` or a CC_OWNS function, or a pointer marked CC_OWNS) or in a variable
  of static storage, where the collector does not look for the pointers to what it manages.

  Scenario Outline: A value of the collector stored in memory from malloc is a finding at the function (<case>)
    Given the C file "gc.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"

      struct CC_GC obj { int n; }; CC_GC typedef struct { struct obj *o; } value_t; struct holder { value_t v; }; typedef struct obj obj_t;
      CC_GC_ALLOC void *gc_alloc(size_t n); void *GC_malloc(size_t n); struct queue { CC_OWNS value_t *owned; void *any; };
      typedef struct { int n; } cell_t CC_GC; typedef struct obj *obj_ref; struct ref_holder { obj_ref r; };
      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/gc.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-OWN-GC-IN-MALLOC","tool":"rules","file":"$DIR/gc.c","line":7,"column":6,
      """

    Examples:
      | case                        | code                                                                                    |
      | an array of values          | void f(value_t v, int n) { value_t *a = malloc(n * sizeof *a); a[0] = v; free(a); }     |
      | a pointer to a marked type  | void f(struct obj *o) { struct obj **a = malloc(8); a[1] = o; free(a); }                |
      | a struct that holds one     | void f(struct holder h) { struct holder *a = calloc(1, sizeof *a); *a = h; free(a); }   |
      | from the allocator          | void f(int n) { void **a = malloc(8); a[0] = gc_alloc(n); free(a); }                    |
      | through a local             | void f(int n) { void **a = malloc(8); void *p = gc_alloc(n); a[0] = p; free(a); }       |
      | from Boehm                  | void f(int n) { void **a = malloc(8); a[0] = GC_malloc(n); free(a); }                   |
      | in a field                  | void f(int n) { struct queue *q = malloc(sizeof *q); q->any = gc_alloc(n); free(q); }   |
      | behind a CC_OWNS field      | void f(struct queue *q, value_t v) { q->owned[2] = v; }                                 |
      | behind a CC_OWNS parameter  | void f(CC_OWNS value_t *a, value_t v) { a[1] = v; free(a); }                            |
      | through a cast              | void f(struct obj *o) { void **a = malloc(8); a[0] = (void *)o; free(a); }              |
      | from realloc                | void f(value_t v) { value_t *a = realloc(NULL, 8 * sizeof *a); a[0] = v; free(a); }     |
      | at an offset                | void f(value_t v) { value_t *a = malloc(8 * sizeof *a); *(a + 1) = v; free(a); }        |
      | either side of ?:           | void f(int n) { void **a = malloc(8); a[0] = n ? gc_alloc(n) : NULL; free(a); }         |
      | a typedef of a marked type  | void f(obj_t *o) { obj_t **a = malloc(8); a[0] = o; free(a); }                          |
      | a marked typedef            | void f(cell_t *c) { cell_t **a = malloc(8); a[0] = c; free(a); }                        |
      | a typedef of a pointer      | void f(obj_ref o) { obj_ref *a = malloc(8); a[0] = o; free(a); }                        |
      | a holder of a typedef       | void f(struct ref_holder h) { struct ref_holder *a = malloc(sizeof *a); *a = h; free(a); } |

  Scenario Outline: A value of the collector stored in a static is a finding at the function (<case>)
    Given the C file "gc.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"

      struct CC_GC obj { int n; }; CC_GC typedef struct { struct obj *o; } value_t; typedef struct obj *obj_ref;
      CC_GC_ALLOC void *gc_alloc(size_t n);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/gc.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-OWN-GC-IN-STATIC","tool":"rules","file":"$DIR/gc.c","line":7,"column":<column>,
      """

    Examples:
      | case                 | column | code                                                                   |
      | a global             | 26     | static void *cache; void f(int n) { cache = gc_alloc(n); }             |
      | a static local       | 6      | void f(value_t v) { static value_t last; last = v; }                   |
      | a static pointer     | 6      | void f(int n) { static void *p; p = gc_alloc(n); }                     |
      | an item of a static  | 34     | static struct obj *seen[4]; void f(struct obj *o) { seen[1] = o; }     |
      | a field of a static  | 40     | static struct { value_t v; } box; void f(value_t v) { box.v = v; }     |
      | a static local alone | 14     | struct obj **f(void) { static struct obj *last; return &last; }        |
      | a typedef static     | 10     | obj_ref *f(void) { static obj_ref last; return &last; }                |
      | a typedef global     | 16     | static obj_ref last;                                                   |

  Scenario Outline: A value of the collector kept where the collector sees it passes (<case>)
    Given the C file "gc.c" holds:
      """
      #include "stdlib.h"
      #include "cchecker.h"

      struct CC_GC obj { int n; }; CC_GC typedef struct { struct obj *o; } value_t; struct holder { value_t v; };
      CC_GC_ALLOC void *gc_alloc(size_t n);

      <code>
      """
    When I run cchecker with "--tools rules --json $DIR/gc.c -- -I../include"
    Then the exit code is 0

    Examples:
      | case                     | code                                                                            |
      | memory of the collector  | void f(value_t v, int n) { value_t *a = gc_alloc(n); a[0] = v; }                |
      | a local array            | void f(value_t v) { value_t a[2]; a[0] = v; }                                   |
      | memory of the caller     | void f(value_t *a, value_t v) { a[0] = v; }                                     |
      | numbers in malloc memory | void f(int n) { int *a = malloc(n); a[0] = n; free(a); }                        |
      | a pointer to a holder    | void f(struct holder *h) { struct holder **a = malloc(8); a[0] = h; free(a); }  |
      | a static of numbers      | static int count; void f(int n) { count = n; }                                  |
      | a function pointer       | typedef value_t (*make_fn)(int); static make_fn maker; void f(make_fn m) { maker = m; } |
      | a constant static        | static const value_t none; void f(value_t *v) { *v = none; }                    |
      | a pointer to pointers    | void f(struct obj **list) { struct obj ***a = malloc(8); a[0] = list; free(a); } |
      | NULL in malloc memory    | void f(void) { struct obj **a = malloc(8); a[0] = NULL; free(a); }              |
      | 0 in a field             | struct box { struct obj *o; }; void f(void) { struct box *h = malloc(sizeof *h); h->o = 0; free(h); } |

  Scenario: A variable of static storage of a collector type is a finding at the variable
    Given the C file "gc.c" holds:
      """
      #include "cchecker.h"

      struct CC_GC obj { int n; };
      typedef struct { struct obj *o; } value_t CC_GC;
      struct holder { value_t v; };

      static struct obj *last;
      struct holder roots[4];
      extern value_t shared;
      int count;
      """
    When I run cchecker with "--tools rules --json $DIR/gc.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      {"code":"CC-OWN-GC-IN-STATIC","tool":"rules","file":"$DIR/gc.c","line":7,"column":20,
      """
    And the output includes:
      """
      {"code":"CC-OWN-GC-IN-STATIC","tool":"rules","file":"$DIR/gc.c","line":8,"column":15,
      """
    And the output does not include:
      """
      "line":9,
      """
    And the output does not include:
      """
      "line":10,
      """

  Scenario: The path of a finding names the store
    Given the C file "gc.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"

      CC_GC_ALLOC void *gc_alloc(size_t n);

      void **table(int n) {
        void **items = malloc(n * sizeof *items);
        for (int i = 0; i < n; i++)
          items[i] = gc_alloc(16);
        return items;
      }
      """
    When I run cchecker with "--tools rules --json $DIR/gc.c -- -I../include"
    Then the exit code is 1
    And the output includes:
      """
      "line":6,"column":8,"message":"table stores a value of the collector in memory from malloc: items[i]","path":["9:5 stores gc_alloc in items[i]"]
      """

  Scenario: The allocators of the Boehm collector are the family libgc_alloc of [library], which can be turned off
    Given the C file "boehm.c" holds:
      """
      #include <stdlib.h>
      #include "cchecker.h"

      void *GC_malloc(size_t n);
      CC_GC_ALLOC void *gc_alloc(size_t n);

      void f(int n) { void **a = malloc(8); a[0] = GC_malloc(n); a[1] = gc_alloc(n); free(a); }
      void g(int n) { void **b = malloc(8); b[0] = GC_malloc(n); b[0] = gc_alloc(n); free(b); }
      """
    When I run cchecker in its folder with "--tools rules --json boehm.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      in memory from malloc: a[0]","path":["7:39 stores GC_malloc in a[0]"],"source":"libgc_alloc"
      """
    And the output includes:
      """
      in memory from malloc: a[1]","path":["7:60 stores gc_alloc in a[1]"],"source":""
      """
    Given the file "cchecker.toml" holds:
      """
      [library]
      libgc_alloc = false
      """
    When I run cchecker in its folder with "--tools rules --json boehm.c -- -I../../../include"
    Then the exit code is 1
    And the output includes:
      """
      in memory from malloc: a[1]"
      """
    And the output includes:
      """
      in memory from malloc: b[0]"
      """
    And the output does not include:
      """
      a[0]
      """
