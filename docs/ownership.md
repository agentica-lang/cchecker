# Ownership and the collector

## Ownership on every path

`CC_OWNS` says that a place owns the memory its pointer points to, which is
freed once, with `free` or with a function of the project marked `CC_FREES`:

```c
CC_OWNS char *read_name(int fd);            /* returns a pointer that the caller owns */
void adopt(CC_OWNS char *name);             /* takes what the caller passes */
void conn_free(CC_FREES struct conn *c);    /* frees what the caller passes */
struct conn { CC_OWNS char *buf; };         /* a store into the field hands the pointer on */

int load(int n) {
  CC_OWNS char *buf = malloc(n);            /* the local owns its value */
```

The rules follow every path of a function that has a pointer that owns, with the
graph and the walk of the [locks](rules.md#locks-on-every-path) and their limits
(a function with too many paths is listed once in `incomplete_functions`). A
parameter marked `CC_OWNS` or `CC_FREES` owns from the entry, a local marked
`CC_OWNS` owns the value it gets (other than `NULL`), and a local that gets the
value of a `CC_OWNS` function owns it without a mark. On every path
that returns, each one is freed or handed on: returned, stored in a `CC_OWNS`
field (or an item of one, `q->items[i] = p`, or a `CC_OWNS` global), or passed
to a `CC_OWNS` parameter. Stored anywhere else or passed to another parameter,
it is lent and still owns. A condition that tells that a pointer is null (`if
(!p)`, `if ((p = malloc(n)) == NULL)`) leaves it owning nothing on that side.

A local without a mark that gets a pointer that owns (`char *c = p`) stands for
it: freeing `c` frees `p`; a `malloc` into it later owns nothing, as in any
local without a mark. A local marked `CC_OWNS` that gets one takes it over, and
`p` owns no more. Each side of `?:` gives its own value (`p = n ? make(n) :
NULL` owns where `n` is true, `p = q ?: make(n)` where `q` is null), and a
statement expression gives the value of its last expression (`({ char *q =
make(n); ...; q; })`). In a `CC_FREES` parameter that points to the pointer
(`release(CC_FREES char **p)`, a cleanup function), `*p` is the pointer:
`free(*p)` frees it, `if (*p)` tests it, `*p = NULL` sets it to null, and `*p =
v` gives the caller a value that the function does not own: a pointer that owns
is handed on there, and a local that stood for the old value (`old = *p`) owns
it. `t = realloc(p, n)` moves `p` to `t`, and `p` owns again where `t` is null;
`p = realloc(p, n)` keeps `p` owning. A pointer lent to be set (`fill(&p)`) owns
what the call left in it, which the rules do not know: no finding says it leaks.
The marks of the parameters of a prototype hold in the definition and in every
caller that includes it.

| Code | |
|---|---|
| `CC-OWN-LEAK` | a path returns, or gives a pointer a new value, while it still owns; or drops the value of a `CC_OWNS` function (kept nowhere: not in a local, a `CC_OWNS` place, a return or a parameter that takes it) |
| `CC-OWN-DOUBLE-FREE` | a path frees a pointer that it already freed or handed on |
| `CC-OWN-USE-AFTER-FREE` | a path reads, returns or hands on a pointer after it freed it or handed it on |

The finding is at the function, once for each code and pointer, and `path` goes
from where the pointer got its value (or from the free) to the step that breaks
the rule:

```text
src/load.c:6:5 CC-OWN-LEAK load does not free or hand on buf on every path: 9:21 buf = malloc -> 10:8 true -> 12:7 true -> 13:5 returns
```

A `malloc` into a local without a mark is not checked: `gcc -fanalyzer` reports
those leaks, and the mark makes the contract part of the code. The rules do not
follow a pointer into a struct or an array (a store into a `CC_OWNS` field is
where they stop), through a function pointer, or out through a parameter (`int
open_buf(char **out)`: the caller lends `&p` to be set). Two locals of the same
name in one function are one pointer. A local that stands for a pointer still
stands for it after that pointer gets a new value, except through a `CC_FREES`
parameter that points to the pointer: after `old = *p; *p = v;`, `old` holds the
old value. `return p` hands `p` on even when the function has no `CC_OWNS` mark,
and `p = realloc(p, n)` is trusted to work. A pointer put in a struct or a
compound literal is not followed, and only one level of pointer is (`*p` of a
`char **p`, not `**p`). A pointer freed through its address
(`free_and_null(&p)`, a cleanup function) is freed or null: it may be read and
freed again (`free(NULL)`), and where a condition says it is not null it is
freed. The rules assume that a helper that frees through `&p` sets the pointer
to null; one that only frees leaves a later double free or use unreported.

## Values of the collector

A collector frees what no pointer that it sees points to. It scans its own heap
and its roots (the stacks, and the statics for some), never memory from
`malloc`: a pointer kept there, or in a static that it does not scan, does not
keep the value alive. The rule keeps them out of both. `CC_GC` on a struct, a
union or a typedef says that the collector manages its values, and `CC_GC_ALLOC`
on a function that it returns memory of the collector; the allocators of the
Boehm collector (`GC_malloc`, `GC_malloc_atomic`, `GC_realloc`, ...) are known
(`[library]` `libgc_alloc`; see [Settings](settings.md)).

```c
struct CC_GC object { ... };                     /* a struct object, or a pointer to one */
typedef struct { uint64_t bits; } value CC_GC;   /* a value, or a pointer to one */
CC_GC_ALLOC void *gc_alloc(size_t size);         /* the memory it returns */
```

A value of the collector is a value of a marked type, a pointer to one, a struct
that holds one (by value or by pointer), the value of an allocator of the
collector, or a local that got one of those; a cast does not hide it. The rule
reads each store of a function (`a[i] = v`, `p->f = v`, `*p = v`, `x = v`):

| Code | |
|---|---|
| `CC-OWN-GC-IN-MALLOC` | a value of the collector is stored in memory from `malloc`: what a pointer points to when it got the value of `malloc`, `calloc`, `realloc`, `strdup` or a `CC_OWNS` function, or is marked `CC_OWNS` (a local, a parameter, a field or a global) |
| `CC-OWN-GC-IN-STATIC` | a value of the collector is stored in a variable of static storage (a global, a static local, or a field or an item of one), or such a variable has a collector type |

The finding of a store is at the function, once for each code and target, with
the store as its path:

```text
src/table.c:6:8 CC-OWN-GC-IN-MALLOC table stores a value of the collector in memory from malloc: items[i]: 9:5 stores gc_alloc in items[i]
```

A variable of static storage of a collector type is a finding at the variable (a
global or a file static, at its definition, not at an `extern`), and at the
function for a static local. The rule does not follow the paths: a local that
got memory from `malloc` anywhere in the function points to it everywhere in it.
Memory it cannot tell (a parameter that is not marked, a field that is not
`CC_OWNS`) is not reported, nor is a copy that is no store (`memcpy`, a value
passed to a function that stores it), a store of `NULL` or `0`, or a constant
static (`static const value none`), which only ever holds its initializer. A
typedef of a pointer (`typedef struct object *object_ref`) is read through to
the type it names.
