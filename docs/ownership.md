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
  ...
}
```

The rules follow every path of a function that has a pointer that owns, with the
graph and the walk of the [locks](rules.md#locks-on-every-path) and their limits
(a function with too many paths is listed once in `incomplete_functions`). A
parameter marked `CC_OWNS` or `CC_FREES` owns from the entry, a local marked
`CC_OWNS` owns the value it gets (other than `NULL`), and a local that gets the
value of a `CC_OWNS` function owns it without a mark. A `malloc` into a local
without a mark is not checked (`gcc -fanalyzer` reports those leaks). On every
path that returns, each pointer that owns is freed or handed on: returned (even
in a function with no `CC_OWNS` mark), stored in a `CC_OWNS` field (or an item
of one, `q->items[i] = p`, or a `CC_OWNS` global), or passed to a `CC_OWNS`
parameter. Stored anywhere else or passed to another parameter, it is lent and
still owns. A condition that tells a pointer is null (`if (!p)`, `if ((p =
malloc(n)) == NULL)`) leaves it owning nothing on that side. The marks of the
parameters of a prototype hold in the definition and in every caller that
includes it.

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

### Jumps and blocks

A call of a function that may jump out (`CC_MAY_JUMP`, `[assume] may_jump`, or a
function that calls one and does not catch the jump, see
[Jumps](rules.md#jumps)) is a way out: each pointer that still owns after the
call is a leak, with the call as the last step of `path`. What the call itself
frees or takes (a `CC_FREES` or `CC_OWNS` parameter) is the callee's from the
call on. A call of a function that always jumps out (`CC_JUMPS`, `[assume]
jumps`) is that way out alone and the path ends, so a pointer freed before the
call is not freed twice by the code after it. A jump runs no `cleanup(f)`
function, and a call through a function pointer never jumps.

A pointer declared in an inner block is checked where a path leaves the block
(its end, `break`, `continue`, `goto` or `return`): one that still owns there
leaks, with that point as the last step of `path`, unless a pointer outside the
block stands for it (`t = s`, `r = realloc(s, n)`). It then leaves the walk once
nothing stands for it and it owns nothing, unless a `goto` of the function goes
into a block, past the declarations before its label: one that still owns leaks
where the path ends, as one finding on the pointer of the block. Known gap: a
`case` label inside a nested block of a `switch` is not a jump into the block
yet, so a pointer declared before it can leave the walk too early
([#111](https://github.com/agentica-lang/cchecker/issues/111)). The pointers of
a statement expression are checked at the end of the statement around it.

### Aliases, reallocation and out parameters

- A local without a mark that gets a pointer that owns (`char *c = p`) stands
  for it: freeing `c` frees `p`, and a `malloc` into it later owns nothing. A
  local marked `CC_OWNS` that gets one takes it over, and `p` owns no more. A
  local that stands for a pointer holds the old value when the pointer gets a
  new one (`old = p; p = make();`), except after `p = realloc(p, n)`, which is
  trusted to work.
- Each side of `?:` gives its own value (`p = n ? make(n) : NULL` owns where `n`
  is true; also in a store or a return that hands a pointer on), and a statement
  expression gives the value of its last expression.
- `t = realloc(p, n)` moves `p` to `t`, and `p` owns again where `t` is null; `p
  = realloc(p, n)` keeps `p` owning.
- In a `CC_FREES` parameter that points to the pointer (`release(CC_FREES char
  **p)`, a cleanup function), `*p` is the pointer: `free(*p)` frees it, `*p =
  NULL` sets it to null, and `*p = v` gives the caller a value the function does
  not own: a pointer that owns is handed on there, and a local that stood for
  the old value (`old = *p`) owns it. A pointer freed through its address
  (`free_and_null(&p)`) is freed or null: it may be read and freed again, and
  where a condition says it is not null it is freed. The rules assume that a
  helper that frees through `&p` sets the pointer to null; one that only frees
  leaves a later double free or use unreported.
- `CC_OWNS_OUT` on a parameter that points to a pointer (`int take(CC_OWNS_OUT
  char **out)`) says that the function may hand an owned pointer out through it;
  the parameter itself owns nothing. `*out = p` hands `p` on. In the caller, a
  local whose address the call gets (`take(&p)`) is filled: a value it still
  owned leaks, and `path` starts at the call (`9:7 take sets p`). A call that
  failed may have left nothing there, so a filled pointer owns from the first
  time the path reads it (passes it, tests it, stores it); before that, no exit
  and no new value leaks it, and a filled pointer that is never read is not
  reported (`take(&b); return 0;`). With `CC_FREES` too (`renew(CC_FREES
  CC_OWNS_OUT char **p)`), the call frees the old value and fills a new one. A
  pointer lent to be set (`fill(&p)`) without `CC_OWNS_OUT` owns what the call
  left in it, which the rules do not know: no finding says it leaks.
- Two variables of the same name (a shadowing local, a parameter or global, the
  same name in two blocks) are two variables. A local that gets a pointer
  already freed or handed on (`free(b); char *c = b;`) is a use after free
  there; a call that clears only the local (`zap(&c)` at a `CC_FREES` parameter)
  frees the pointer it stands for; `c = b; zap(&b);` frees the pointer too, and
  `c` still holds it, so `free(c)` after it is a double free unless `c` got
  another value first. A store of the value a pointer already holds (`p.right =
  p.right`) changes nothing.
- Not followed: a pointer into a struct or an array, except as below (a store
  into a `CC_OWNS` field is where they stop), through a function pointer, or out
  through a parameter without `CC_OWNS_OUT`; a pointer stored in a field without
  `CC_OWNS`; more than one level of pointer (`*p` of a `char **p`, not `**p`);
  the items of an array after the store (an array freed without its items is not
  reported, nor are the items of a local array without a mark that is never
  freed). An initializer or a compound literal that puts a pointer in a
  `CC_OWNS` field hands it on there; in any other field or item it is only read.
  A store through `*argv` is not one into an item (`argv[0]` is). A store into
  an item of an array that owns (`argv[i] = p`, where `argv` is `CC_OWNS`,
  stands for one, or is a local that got `malloc`, `calloc` or `realloc`) hands
  the pointer on to the array.

### Structs in a local

The one struct the rules follow is a local one: its `CC_OWNS` fields are
pointers of their own. After `struct pair p = {0}; p.left = make();` or `struct
pair p = { .left = make() };`, `p.left` owns and is freed or handed on on every
path, as a `CC_OWNS` local, and the findings name it `p.left`. The cases are in
`specs/ownership.feature`.

- Nested: a struct in it by value is followed the same way (`p.inner.left`; a
  field of an unnamed struct member too), up to 8 levels and 16 `CC_OWNS` fields
  in all. Over a bound only the struct's own `CC_OWNS` fields are followed, and
  a store into the fields of a struct in it hands the pointer on (`&p.inner`
  then stops following the whole struct).
- Which struct: the one its type names where the variable is declared, as C
  finds a tag or typedef in the blocks around it (a tag declared in the clauses
  of a `for`, or in the condition of an `if`, `while`, `do` or `switch`, is seen
  only inside that statement); a block that shadows another of the same name, or
  an unnamed struct, is its own struct.
- Not followed: a struct reached through a pointer (`p.ptr->left`), in a union,
  `static`, of an unknown type (an unnamed struct through `__typeof__`, a tag
  defined in a `sizeof`, a cast or a parameter list), or whose fields the
  function uses in a way the struct does not fit. A store into their `CC_OWNS`
  fields hands the pointer on. The address of a field that does not own (`&p.n`)
  stops following the whole struct.
- Escape: the fields are followed up to where the struct escapes, which is any
  read of the whole struct: its address passed or stored (`keep(&p)`), a copy
  (`q = p`), a by-value argument (`take(p)`), `return p`, `(void)p`, an `asm`
  operand that names it, or a new value of the whole struct (`p = q`). There
  every field is handed on: a leak before the escape is found, the escape is
  clean, and nothing more is checked after it. A struct in it escapes alone,
  with the same forms (`keep(&p.inner)`, `q = p.inner`, `p.inner = q`: only the
  fields of `p.inner` are handed on), while `keep(&p.inner.left)` lends one
  pointer. The address of a struct in it (`&p.inner`) is taken to reach only
  that struct: a callee that goes back to the outer struct (`container_of`) is
  not seen. `sizeof p`, a field that does not own and a `CC_OWNS` field as an
  `asm` operand are no escape.
- A field set from a local (`p.left = b`) stands for that local: a free of
  either frees the one pointer (of both, a double free) and a leak names the
  local. When the struct escapes the local is lent with it, so `struct entry key
  = { .name = name }; find(&key); free(name);` is clean.
- Clears: a `cleanup` function on the struct frees every field at the end of its
  block (its body is not read: one that frees only some fields can give a false
  double free after an explicit free of another, and the leak of the fields it
  skips is not found). A call that passes `&p` to a `CC_FREES` parameter
  (`pair_free(&p)`) frees every field and is taken to set them to null (a
  following `free(p.left)`, use of `p.left` or second `pair_free(&p)` is not
  reported, which a helper that only frees would make a double free or a use
  after free), for a helper defined in another unit; in its own function a
  `CC_FREES` parameter that points to a struct is one pointer to free, so a
  helper that frees only the fields is checked as one that leaks the struct
  (leave it unmarked and give it as a `cleanup` function). `memset(&p, 0, sizeof
  p)` (fill `0`, size `sizeof p` or of a type naming the same struct; another
  size is an escape) and a compound literal (`p = (struct pair){0}`) clear the
  struct: each field gets null or its item, so the struct is followed again and
  a field that still owns leaks there. All of these work on a struct in it too
  (`pair_free(&p.inner)`), on its fields only, and a nested initializer (`{
  .inner = { .left = b } }`) gives each nested field its item. `&p.left` of a
  `CC_OWNS` field is the address of that pointer, as `&b` of a local
  (`take(&p.left)` at a `CC_OWNS_OUT` parameter fills it).
- `CC_OWNS` on a struct parameter passed by value (`void f(CC_OWNS struct pair
  p)`): the function owns its `CC_OWNS` fields, each from the entry, and the
  parameter is followed as a local struct. Without the mark it is not followed,
  and the mark on a struct with no `CC_OWNS` field, or an unknown struct, owns
  nothing. A caller that passes a followed struct there (`take_pair(q)`,
  `take_pair(a[0])`) hands its fields on: a later `free(q.left)` is a double
  free and no leak is reported. A struct passed through a function pointer or to
  a `...` is a by-value argument, an escape.
- A local array of structs of a constant size (`struct pair a[2]`) is followed
  item by item (`a[0].left`), within the same bound (the items times the
  `CC_OWNS` fields of each, those of nested structs included, at most 16), when
  the function names its items by constant indexes only (a number or `+`, `-`,
  `*` of numbers, up to 1048576; an enum constant or a `const` variable is not
  one). Any other read of the array (`a[i]`, `keep(a)`, `q = a`, `&a[0]`) leaves
  it unfollowed in the whole function, as it may reach any item (the walk also
  takes the path on which a loop does not run, where a loop that frees every
  item would leak them all), except in a `sizeof`, as the array `memset` gets,
  or as an item at a `CC_FREES` parameter. Not followed either: an array over
  the bound, of a variable length, of two dimensions, in a struct or `static`.
  An item named whole (`take(a[0])`, `pair_free(&a[0])`) works as a struct in a
  struct, but `&a[k]` at a `CC_FREES` parameter may free the items after it
  (`pairs_free(&a[0], n)`): those escape. `memset(a, 0, sizeof a)` clears every
  item, and an initializer or a `cleanup` function on the array covers each
  item.

## Values of the collector

A collector frees what no pointer that it sees points to. It scans its own heap
and its roots (the stacks, and the statics for some), never memory from
`malloc`: a pointer kept there, or in a static that it does not scan, does not
keep the value alive. The rule keeps them out of both. `CC_GC` on a struct, a
union or a typedef says that the collector manages its values, and `CC_GC_ALLOC`
on a function that it returns memory of the collector; the allocators of the
Boehm collector (`GC_malloc`, `GC_malloc_atomic`, `GC_realloc`, ...) are known
(`[library] libgc_alloc`; see [Settings](settings.md#library)).

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
global or file static, at its definition, not at an `extern`), and at the
function for a static local. The rule does not follow the paths: a local that
got memory from `malloc` anywhere in the function points to it everywhere in it.
Memory it cannot tell (a parameter that is not marked, a field that is not
`CC_OWNS`) is not reported, nor is a copy that is no store (`memcpy`, a value
passed to a function that stores it), a store of `NULL` or `0`, or a constant
static (`static const value none`). A typedef of a pointer (`typedef struct
object *object_ref`) is read through to the type it names.
