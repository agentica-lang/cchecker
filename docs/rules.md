# Rules

The `rules` tool checks the effects of functions, locks and pairs of calls here,
and the ownership of pointers and the values of the collector in
[ownership.md](ownership.md). Each rule has its codes in a table below.

## Annotations

`include/cchecker.h` defines the macros that the rules read: `CC_SHORT`,
`CC_BLOCKING`, `CC_HOT`, `CC_ACQUIRES(lock)`, `CC_RELEASES(lock)`,
`CC_ACQUIRES_IF(lock, *flag)`, `CC_RELEASES_IF(lock, flag)`, `CC_TRIES(lock)`,
`CC_NORETURN`, `CC_MAY_JUMP`, `CC_JUMPS`, `CC_CATCHES`, `CC_JUMP_RELEASES`,
`CC_NO_SYSCALL_UNDER(lock)`, `CC_LOCK_LEVEL(n)`, `CC_PAIR(set, restore)`,
`CC_OWNS`, `CC_FREES`, `CC_OWNS_OUT`, `CC_GC`, `CC_GC_ALLOC`, `CC_ASSUME_SHORT`
(the function counts as fine for `CC_SHORT`), `CC_STOP` (no rule walks into the
function; both are assumptions, see [Settings](settings.md)) and
`CC_IGNORE("CODE", "reason")` (a suppression).

They are empty in every build and with every compiler, except while cchecker
dumps the AST (`CCHECKER_AST`, where clang gets
`__attribute__((deprecated("cchecker:...")))`, with no warning as the dump runs
with `-w`). A project that wants an attribute for another tool defines them
itself. An annotation may be on any declaration of the function: a prototype in
a header holds for the definition.

```c
#include "cchecker.h"

CC_SHORT int next_id(void);
void adopt(CC_OWNS char *name);
CC_PAIR(mask_signals, restore_signals) int guarded(void);
```

## Effects

The rules run `clang -Xclang -ast-dump=json -fsyntax-only` on each file with its
flags, keep the declarations written in the files under the working directory
(for one that a macro writes, where the macro is used), and build one call graph
from all the files of the run (a static function is another function in each
file). A rule walks the graph from each annotated function that the project
defines, and its finding is at that function. The message names the call that
breaks the rule; the printed line and `path` add the shortest call path to it.
The baseline matches the message without the path:

```text
src/ids.c:7:14 CC-EFFECT-SHORT-BLOCKS short function next_id reaches the blocking call read: next_id -> helper -> read
```

| Code | |
|---|---|
| `CC-EFFECT-SHORT-BLOCKS` | a `CC_SHORT` function reaches a `CC_BLOCKING` function or a known blocking call |
| `CC-EFFECT-HOT-ALLOCATES` | a `CC_HOT` function reaches a call that allocates or frees heap memory |
| `CC-EFFECT-HOT-SYSCALL` | a `CC_HOT` function reaches a system call; a blocking call is one too |

A root gives one finding per code, at the nearest bad call; a bad call is
reached once, by its shortest path, and the walk does not go past it. With
`--all-paths` it gives one for each distinct bad call, so the baseline key
(code, file, message naming the call) differs per call. A baseline written with
`--all-paths` holds the others too, so run CI the same way: a run without it
counts them fixed.

The walk does not go into a function that never returns or is cold: `_Noreturn`,
`[[noreturn]]`, `CC_NORETURN`, `CC_JUMPS`, `__attribute__((noreturn))` (in its
type too, behind a typedef) or `__attribute__((cold))` on any declaration, and a
library call that never returns (`abort`, `exit`, `longjmp`, `pthread_exit`,
...). Such a call is an error exit, not the path the rules are about; `[effects]
follow_cold = true` follows it. A `CC_BLOCKING` mark on such a function wins.
The lock rules follow every call whatever it says.

The known calls are those of libc, pthread, libuv, OpenSSL and the Boehm
collector that block, allocate or enter the kernel; the lists are in
`src/known.agc` (the blocking families in [Settings](settings.md#library)). An
unlock or the signal of a condition is a system call (it wakes a waiter with a
futex call). A `uv_fs_*` call whose callback, the last argument, is `NULL` or 0
runs at once: it blocks when its libc call does (`uv_fs_read`) and is a system
call when it does not (`uv_fs_stat`). `uv_run` blocks unless its mode is a
constant `UV_RUN_NOWAIT`, which is still a system call for `CC_HOT`. A function
the project defines is judged by its body; a library function that is not listed
has no effect. A known name is known by name alone: a project function named
`remove`, `link` or `dlsym` counts as the libc one in a run that sees only its
declaration.

A call through a function pointer reaches every function the project stores in
the same place: a field of a struct or a union (by record and field name, in an
initializer or an assignment), a variable, or a parameter (from the direct calls
that pass a function), and every function of a place copied into it. A cast is
seen through (`void *`, `uintptr_t`), but a table whose first item is a literal
number is a table of numbers (see [The AST dump](#the-ast-dump)). A variable
with `__attribute__((cleanup(f)))` calls `f`. A pointer that comes from anywhere
else reaches nothing: one that no checked file stores a function in, a return
value, the arguments of a variadic function, and a function handed to a library
that calls it back (`qsort`; a libuv callback is a root of its own, see
[Roots](settings.md#roots)). Two calls through pointers that start at the same
place (`x->f(1)->g(2)`) are one call to the walk: more findings, never fewer.

A walk goes only through what the run read: run it on all the files of the
project, as a call into a file that was not run reaches nothing. For the
baseline, only a full run of a compile database covers the findings of the
rules.

## Locks on every path

The rules follow every path through the control flow graph of each function that
takes or releases a lock: `if`, `switch` (fallthrough, no `default`), loops with
`break` and `continue`, `goto` (a computed one may go to any label), `return`,
`&&`, `||`, `?:`, `x ?: y` and statement expressions. A path ends at a `return`,
the end of the body, or a call that never comes back (`abort`, a `_Noreturn` or
`noreturn` function, also through a typedef or a pointer, or `CC_NORETURN`); a
lock held there is not a finding. The cleanup function of a
`__attribute__((cleanup(f)))` variable runs on every way out of its block.

| Code | |
|---|---|
| `CC-PATH-LOCK-NOT-RELEASED` | a path returns, or jumps out at a `CC_MAY_JUMP` or `CC_JUMPS` call, with a lock that the function took |
| `CC-PATH-LOCK-NOT-HELD` | a path releases a lock that the function did not take |

The finding is at the function, once for each code and lock; `path` is a
shortest path that breaks the rule, from the last call that took the lock (or
released it, for `NOT-HELD`) to the end (`7:7 true` is the condition at line 7,
column 7, taken as true):

```text
src/queue.c:5:5 CC-PATH-LOCK-NOT-RELEASED pop does not release q->mu on every path: 6:3 takes q->mu -> 7:7 true -> 8:5 returns
```

### What is a lock

A lock is the expression the call names, by its field path: `&q->mu`, `q->mu`
and `(&q->mu)` are one lock, `&a->mu` and `&b->mu` are two. A local set once,
where it is declared, stands for its value (`pthread_mutex_t *m = &q->mu`). The
same lock written two ways (`&q->mu` and `m` set later to it) is two locks. The
known calls take or release the lock of their first argument: the mutexes, spin
locks and read-write locks of pthread, C11 and libuv, and the critical sections
and SRW locks of Windows. A wait on a condition gives the lock back before it
returns, so it changes nothing. A call through a function pointer does nothing
to the locks.

A function that takes a lock for its caller, or releases the caller's lock, says
so on its prototype: `CC_ACQUIRES(lock)` or `CC_RELEASES(lock)`, with the lock
written in the names of its parameters (or a global). A call takes or releases
that lock in the words of the call: `queue_lock(vm->q)` takes `vm->q->mu` for
`CC_ACQUIRES(q->mu) void queue_lock(struct queue *q)`. Such a lock helper has
its body trusted and its callers checked. Without an annotation, a function that
takes a lock and returns with it is a finding, so a forgotten unlock never
passes for a helper. Put the annotation on the prototype the callers include (a
caller sees the declarations of its own file). A function that takes or releases
a lock only on some of its returns, other than by the marks below, is beyond
these rules: suppress it with `CC_IGNORE`.

A helper that takes or releases the lock on one side only says which, and is a
lock helper too:

- `CC_ACQUIRES_IF(lock, *flag)`: returns with the lock held only when it set
  `*flag`, a parameter, to a value other than 0 (`CC_ACQUIRES_IF(q->mu, *locked)
  char *at(struct queue *q, int k, bool *locked)`).
- `CC_RELEASES_IF(lock, flag)`: releases it only when `flag`, a parameter, is
  not 0.
- `CC_TRIES(lock)`: takes it where it returns 0, as `pthread_mutex_trylock` does
  (`[assume] tries` names such a function that the project cannot mark).

A call of a `CC_ACQUIRES_IF` takes the lock on one side (`9:3 takes q->mu`) and
not on the other (`9:3 does not take q->mu`). The flag is a local whose address
the call gets (`at(q, k, &locked)`): it gets the value of that side, which a
later test reads, until a new value (a flag of another kind, such as
`&b->locked`, splits the path with no value a test can read). The flag of a
`CC_RELEASES_IF` is read as the test of an `if`; a constant takes one side. On
the side where the helper does nothing to a lock, the rules on what runs under a
lock read its body without its releases of that lock (and its takes, when it
takes by a flag): a system call, or a lock taken before the flag is tested or
after a write to it, is still found. A wait there is no finding only when the
call passes the lock held for the parameter it waits on (`w(&o->mu, 0)` for
`pthread_cond_wait(&cv, m)`) and the body does not change that parameter. A
`CC_TRIES` goes as a trylock does and never waits. A mark whose flag is no
parameter of its declaration, or a `CC_TRIES` with two locks, is an error of the
tool (exit 2).

### Trylock and conditions

A call that may fail to take its lock (`pthread_mutex_trylock`;
`pthread_mutex_lock` returns an error code too) takes it where it gave 0: `if
(pthread_mutex_trylock(&q->mu) != 0) return;`. Its result kept in a local or a
parameter (`int r = ...;`, `bool ok = ... == 0;`, `if ((r = ...) != 0)`) takes
the lock on the paths where the call gave 0, and a later test of the variable
goes the same way (`if (r != 0)`, `if (!r)`, `if (r == EBUSY)`, `switch (r)`, a
copy set once). A new value of the variable forgets the result. A path that
releases the lock where the call failed starts at the call (`6:11 fails`). The
failure of a call that waits (`pthread_mutex_lock`) is reached only when a test
of the variable can follow the call before a new value. A `static` or `volatile`
local, or one whose address is taken, is not followed.

A path does not go where a condition that the function tests twice would be true
and false, so `if (locked) lock(); ...; if (locked) unlock();` passes. A test
against 0 is a test of what it compares, and a whole number written to a local
or a parameter is a value the path knows (`taken = true;`), when a test of the
variable guards a lock call or a way out (`return`, `goto`, `break`,
`continue`): other flags cost no states. A local whose address is taken, a
`volatile` one and a `static` one never have a known value. A write to a
variable of the condition, a write through a pointer, or a call given its
address (`f(&locked)`) forgets its value. A call given the address of a field
(`atomic_store(&q->ready, 0)`) does not change `q`: conditions are kept by
variable, not by field, so copy the field to a local and test the local when a
call may change it.

A function whose paths would take more than 200 000 states is walked again
without these conditions (which may follow paths that cannot happen); when that
is not enough either, its findings are those of the paths followed. Either way
it is listed in `incomplete_functions` of `--json` (`file`, `line` and
`function`) and on standard error, and the exit code does not change. A function
whose AST has more than 20 000 nodes gets no graph: an error of the `rules` tool
on its file (exit 2), and the rest of the run is checked.

Limits: a lock is counted by its text, so a lock taken in a loop over several
objects (`lock(&a[i]->mu)`), hand over hand, or through a pointer set again
between the lock and the unlock (`q = q->next`) can give false findings; the
result of a trylock kept in a field or a global takes nothing; a global that a
called function changes keeps the value the path knew; more than two takes (or
releases) on a path with no release (or take) between count as two.

### Jumps

A call of a function that may jump out (it returns, or calls `longjmp` on an
error, as an interpreter raises one), marked `CC_MAY_JUMP` or named in `[assume]
may_jump`, is a way out too: the path goes on after the call, and it also leaves
the function there. A lock held before the call is `CC-PATH-LOCK-NOT-RELEASED`
on that way out (a `CC_PAIR` set and not restored is
`CC-PATH-PAIR-NOT-RESTORED`), with the call as the last step of `path` (`7:72
may jump in check_size`): the code that catches the jump does not know the lock.
Release it before the call, or check what may fail first. A jump does not run
`cleanup(f)` functions. Only a direct call can jump, never one through a
function pointer.

A call of a function that always jumps out and never returns, marked `CC_JUMPS`
or named in `[assume] jumps`, is that way out alone: the path ends there (`jumps
in check_size`). `CC_MAY_JUMP` on a function that never returns is the same.

A function that directly calls one that may jump or jumps (marked, listed, or
found so in turn) may jump out too, unless it catches the jump: it calls
`setjmp` or `sigsetjmp`, is marked `CC_CATCHES`, or is named in `[assume]
catches`. So only the functions that raise need a mark. A `setjmp` anywhere in a
function counts as catching every jump of its calls (a jump before it, to
another `jmp_buf` or in the handling branch counts as caught too). A function
that no rule walks into (`CC_STOP`, `[assume] stop`) does not jump either. The
last step of `path` names a shortest chain of calls to the marked function, at
most three (`7:72 may jump in sized (check_size)`, `may jump in z (y, x, w,
...)`; `helper@src/a.c` when static functions of two files share a name); a
function that never returns says so (`may jump in bad_signature (fail), never
returns`). The jump of a function that catches still counts at its own calls. A
finding at an inferred jump has `may_jump_callers` in `source` of `--json`;
`[library] may_jump_callers = false` turns the inference off.

A lock helper that writes down the lock it takes, so that the code that catches
a jump can release it, is marked `CC_JUMP_RELEASES` on a `CC_ACQUIRES` or
`CC_RELEASES` helper (or one below), or named in `[assume] jump_releases`; for a
helper of two locks the mark holds for both. A lock taken and released only
through such helpers is no finding at a jump, and is still checked on every
return. A lock that the function also takes or releases another way
(`pthread_mutex_lock`, a helper without the mark) is checked at the jumps as
before. The mark is on the helper, not on the class of the lock, and it is about
locks: a `CC_PAIR` set is still `CC-PATH-PAIR-NOT-RESTORED` at a jump. A
suppression of the code on the function hides the findings of its jumps and of
its returns.

## What runs while a lock is held

A lock held for short sections only, which other threads spin for, is marked on
its field (or on a global lock): `CC_NO_SYSCALL_UNDER()`. While a path holds it,
no call is a system call or a blocking call (a lock or an unlock of another lock
and a `CC_BLOCKING` function included) or reaches one through the functions of
the project (a call through a function pointer included), except the release of
the lock itself and a wait on a condition with it. `CC_NO_SYSCALL_UNDER(lock)`
on a function says the same of one lock of that function, in the names of its
parameters.

`CC_LOCK_LEVEL(n)` on the field of a lock (or a global lock) orders the locks: a
path takes a lock with a level only while every lock it holds with a level has a
lower one, and calls a function that takes one (in its body, in the functions it
reaches, or those stored in a pointer it calls) only then. Two locks of the same
level are never held together. A trylock never waits, so it is never out of
order. A called function that takes the class of a lock held again is not out of
order (for a lock that counts its takes by the same thread): the rules cannot
tell it from another lock of the class.

```c
struct runtime { CC_LOCK_LEVEL(1) pthread_mutex_t sync; ... };
struct runq { CC_NO_SYSCALL_UNDER() CC_LOCK_LEVEL(3) pthread_mutex_t lock; ... };
```

| Code | |
|---|---|
| `CC-PATH-SYSCALL-UNDER-LOCK` | a call under a `CC_NO_SYSCALL_UNDER` lock is or reaches a system call |
| `CC-PATH-LOCK-ORDER` | a lock with a level is taken (or a function that takes one is called) under one of the same or a higher level |

- A lock taken under the quiet lock by a system call is one finding, at its
  take; its release is none (by a library call or a `CC_RELEASES` helper). The
  release of a lock taken by a trylock, which is no system call, is the finding.
- A `CC_RELEASES` helper that releases the quiet lock is held to the system
  calls it may make before that release, on any path of its body (a `write`, the
  signal of a condition, a wait with the lock, as the lock is held again after
  it); what it does after is no finding. A helper that releases a lock taken
  under the quiet lock, or the restore of a `CC_PAIR` whose set ran under it, is
  held to all its system calls. An unlock or a wait in a helper is a release,
  never its system call.
- Limits: a lock taken under the quiet lock is told by the order of the takes on
  the path, so the release of a quiet lock taken again (a recursive mutex)
  counts as the release of the quiet lock, a lock taken both before and after it
  counts as taken after it, and a helper that takes two locks in one call has
  them both taken at that call.
- A field is known by its struct and name (`runq.lock`; the name of a typedef
  for an anonymous struct; an item of an array of locks is its field), a global
  by its name (`name@file` for a static one). The marks are
  `CC_NO_SYSCALL_UNDER()` with nothing in it and `CC_LOCK_LEVEL(n)` with a
  decimal number; another form, or a mark on a field of a struct with no name,
  is an error of the `rules` tool (exit 2). A lock of a `CC_ACQUIRES` is
  followed to its field through the types of the parameters
  (`CC_ACQUIRES(s->pool->mu)` on `void pool_lock(struct server *s)` takes
  `pool.mu`).
- The path of a finding goes from the take of the lock held to the call, then
  the call path to the system call: `13:3 calls bump: bump ->
  pthread_mutex_lock`.

## Pairs of calls

`CC_PAIR(set, restore)` on a function says that in its body a call of `set` is
followed by a call of `restore` on every path that returns, as a lock is by its
unlock (the same graph and walk). On a declaration of `set` itself it says so in
every function that calls `set`. The two are functions, by name, whatever their
arguments; a cleanup function counts as a call. A pair of one function (`umask`)
never gives a finding; a `set` twice needs two restores. When the restore
happens in a function that the code calls, name that function:
`CC_PAIR(mask_signals, finish)`.

```c
CC_PAIR(mask_signals, restore_signals) void mask_signals(sigset_t *old);   /* in every caller */
CC_PAIR(gc_pause, gc_resume) int copy_out(struct heap *h);                  /* in copy_out */
```

| Code | |
|---|---|
| `CC-PATH-PAIR-NOT-RESTORED` | a path returns after a call of `set` and no call of `restore` after it |
| `CC-PATH-PAIR-NOT-SET` | a path calls `restore` with no call of `set` before it, in a function that calls `set` |

The path goes from the call of `set` to the return (`7:3 calls mask_signals ->
8:7 true -> 9:5 returns`).

- A restore that a path reaches around the set (`if (bad) goto out; gc_pause();
  ... out: gc_resume();`) is a finding. A restore of two pairs is a finding only
  when it restores neither. A set made more than twice on a path counts as
  twice.
- The walk does not tie a variable to the set it records, so `if (paused)
  gc_resume();` after a conditional `gc_pause()`, and a toggle (`if (on) set();
  else restore();`), give findings, even when the restore is harmless to repeat:
  `CC_PAIR` is opt-in, so leave it off such a pair.
- The body of a `set` that carries its own `CC_PAIR` (a wrapper of `GC_disable`)
  may leave another pair set for its caller, but not on a return of an error
  value, after which the caller does not call `restore`: a negative constant
  (`return -1`, `-EINVAL`), a null pointer (`NULL`, `nullptr`) or a false bool,
  read through typedefs. Any other value, `0` of an `int` included, is a
  success, and a returned variable is not followed. A `set` whose `NULL`,
  `false` or negative return means success gets a finding on that return.
- Two pairs on one `set` are two pairs (both restores are needed); one `restore`
  of two sets restores both; the same pair written twice counts once. A pair
  holds in the files that see its declaration, and one that names a function the
  file does not declare does nothing. A `set` that can fail (and needs no
  `restore` then) is beyond the rule: suppress the finding with `CC_IGNORE`.

## The AST dump

The rules read the dump of clang through a private folder under `$TMPDIR` (the
dump is tens of MiB, more than a process output holds), keeping only the
declarations of the project. A table of numbers is not kept (an array of a
number or character type, or whose first item is a number: `const uint8_t
ROM[]`; a number cast to a pointer is not a number). A declaration of more than
a million lines is left out: when it names a function it is a tool error,
otherwise it is counted in `skipped_declarations` of `--json` and on standard
error, and the rest of the file is checked. A dump that ends early is a tool
error. A run removes its folder, and the folders that killed runs left (a
private folder of the same user whose process is gone); runs in different PID
namespaces that share `$TMPDIR` can remove each other's folders.
