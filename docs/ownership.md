# Ownership and the collector

## Ownership on every path

`CC_OWNS` says that a place owns the memory its pointer points to, which is
freed once, with `free` or with a function of the project marked `CC_FREES`:

```c
CC_OWNS char *read_name(int fd);            /* returns a pointer that the caller owns */
void adopt(CC_OWNS char *name);             /* takes what the caller passes */
int take_name(CC_OWNS_OUT char **out);      /* hands an owned pointer out to the caller */
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
value of a `CC_OWNS` function owns it without a mark. On every path that
returns, each one is freed or handed on: returned, stored in a `CC_OWNS` field
(or an item of one, `q->items[i] = p`, or a `CC_OWNS` global), or passed to a
`CC_OWNS` parameter. A call of a function that may jump out (`CC_MAY_JUMP`,
`[assume] may_jump`, or a function that calls one and does not catch the jump,
see [Locks](rules.md#locks-on-every-path)) is a way out too: each one that still
owns after the call is a leak, with the call as the last step of `path`. A call
of a function that always jumps out and never returns (`CC_JUMPS`, `[assume]
jumps`, or `CC_MAY_JUMP` on a function that never returns) is that way out
alone: the leaks are checked there and the path ends, so a pointer freed before
the call is not freed twice by the code after it. What the call itself frees or
takes (a `CC_FREES` or `CC_OWNS` parameter) is the callee's from the call on,
jump or not. A jump does not run the `cleanup(f)` functions of the variables,
and a call through a function pointer never jumps. Stored anywhere else or
passed to another parameter, it is lent and still owns. A condition that tells
that a pointer is null (`if (!p)`, `if ((p = malloc(n)) == NULL)`) leaves it
owning nothing on that side.
A pointer declared in an inner block is checked where a path leaves the block
(its end, a `break`, `continue`, `goto` or `return`): one that still owns there
leaks, with that point as the last step of `path`, unless a pointer outside the
block stands for it (`t = s`, `r = realloc(s, n)`). It then leaves the walk once
nothing stands for it and it owns nothing, unless a `goto` of the function goes
into a block, past the declarations before its label; one that still owns leaks
where the path ends, as one finding on the pointer of the block. A known gap: a
`case` label inside a nested block of a `switch` is not such a jump yet, so a
pointer declared before it can leave the walk too early
([#111](https://github.com/agentica-lang/cchecker/issues/111)). The pointers of
a statement expression (`({ ...; p; })`) are checked so at the end of the
statement around it, and its cleanup functions run at its own end.

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
`p = realloc(p, n)` keeps `p` owning. A pointer lent to be set (`fill(&p)`)
without `CC_OWNS_OUT` (below) owns what the call left in it, which the rules do
not know: no finding says it leaks. The marks of the parameters of a prototype
hold in the definition and in every caller that includes it.

`CC_OWNS_OUT` on a parameter that points to a pointer (`int take(CC_OWNS_OUT
char **out)`) says that the function may hand an owned pointer out to the caller
through it; the parameter itself owns nothing. `*out = p` (or `out[0] = p`)
hands `p` on, and `*out = make(n)` keeps the value. In the caller, a local whose
address the call gets there (`take(&p)`, marked or not) is filled: a value that
it still owned leaks, and `path` starts at the call (`9:7 take sets p`). A call
that failed may have left nothing there, so a filled pointer owns from the first
time the path reads it (passes it, tests it, stores it): from then on a return
or a jump that does not free or hand it on leaks it. Before that, no exit and no
new value (another `take(&p)`, in a retry loop) leaks it. With `CC_FREES` too
(`renew(CC_FREES CC_OWNS_OUT char **p)`), the call frees the old value and fills
a new one.

A store of a pointer that owns, or of the value of a `CC_OWNS` function, into an
item of an array that owns hands it on to the array, as a store into a `CC_OWNS`
field does: `argv[i] = p`, where `argv` owns or stands for a pointer that does,
is marked `CC_OWNS`, or is a local that got `malloc`, `calloc` or `realloc`. In
a store or a return that hands a pointer on, each side of `?:` gives its own
value (`x->held = n ? p : NULL`, `return n ? p : NULL`).

| Code | |
|---|---|
| `CC-OWN-LEAK` | a path returns, jumps out at a `CC_MAY_JUMP` or `CC_JUMPS` call, leaves the block of a local, or gives a pointer a new value, while it still owns; or drops the value of a `CC_OWNS` function (kept nowhere: not in a local, a `CC_OWNS` place, a return or a parameter that takes it) |
| `CC-OWN-DOUBLE-FREE` | a path frees a pointer that it already freed or handed on |
| `CC-OWN-USE-AFTER-FREE` | a path reads, returns or hands on a pointer after it freed it or handed it on |

The finding is at the function, once for each code and pointer, and `path` goes
from where the pointer got its value (or from the free) to the step that breaks
the rule:

```text
src/load.c:6:5 CC-OWN-LEAK load does not free or hand on buf on every path: 9:21 buf = malloc -> 10:8 true -> 12:7 true -> 13:5 returns
src/conf.c:9:5 CC-OWN-LEAK start does not free or hand on c on every path: 10:28 c = malloc -> 11:8 true -> 14:13 may jump in as_mode
```

A `malloc` into a local without a mark is not checked: `gcc -fanalyzer` reports
those leaks, and the mark makes the contract part of the code. The rules do not
follow a pointer into a struct or an array (a store into a `CC_OWNS` field is
where they stop), through a function pointer, or out through a parameter without
`CC_OWNS_OUT` (`int open_buf(char **out)`: the caller lends `&p` to be set). Two
variables of the same name in one function (a local that shadows another, a
parameter or a global, or the same name in two blocks) are two variables: each
pointer has its own state, and a condition on one is not a condition on the
other. A local that stands for a pointer holds the old value when the pointer
gets a new one (`old = p; p = make();`, `take(&p)` at a `CC_OWNS_OUT`
parameter, `old = *p; *p = v;` through a `CC_FREES` parameter), except after
`p = realloc(p, n)`, which is trusted to work. `return p` hands `p` on even when
the function has no `CC_OWNS` mark. A pointer stored
in a field without `CC_OWNS` is not followed, one that an initializer or a
compound literal puts in a `CC_OWNS` field is handed on there (in any other
field or item it is only read), and only one level of pointer is (`*p` of a
`char **p`, not `**p`). A
pointer freed through its address (`free_and_null(&p)`, a cleanup function) is
freed or null: it may be read and freed again (`free(NULL)`), and where a
condition says it is not null it is freed. The rules assume that a helper that
frees through `&p` sets the pointer to null; one that only frees leaves a later
double free or use unreported.

The one struct the rules follow is a local one: its `CC_OWNS` fields are
pointers of their own. After `struct pair p = {0}; p.left = make();` or
`struct pair p = { .left = make() };`, `p.left` owns and is freed or handed on
on every path, as a `CC_OWNS` local, and the findings name it `p.left`. The
fields are followed up to where the struct escapes: its address passed or
stored (`keep(&p)`), a copy (`q = p`, `struct pair q = p`), a by-value argument
(`take(p)`), `return p`, or a new value of the whole struct (`p = q`). There
every field is handed on, so a leak before the escape is found and the escape
is clean. After it the fields belong to whoever got the struct: a free of one
is no finding, and a store into one hands the pointer on. `sizeof p` and a field
that does not own (`p.n`) are no escape. A struct whose field has its address
taken (`&p.left`), or that has a `cleanup` function, is not followed, nor a
static one or a union: a store into their `CC_OWNS` fields hands the pointer
on. A known gap: an
initializer of a union (`union u v = { .p = b };`) does not hand the pointer on
yet, which gives a false leak
([#111](https://github.com/agentica-lang/cchecker/issues/111)).

A filled pointer that the path never reads is not reported (`take(&b); return
0;`): telling it from what a call that failed left would need a mark that says
on which result the pointer is set. The items of an array are not followed one
by one after the store: an array freed without its items is not reported, nor
are the items of an array in a local without a mark (`char **v = calloc(n,
sizeof *v)`) that is never freed, as for any `malloc` into such a local. A store
through `*argv` is not one into an item (`argv[0]` is).

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
