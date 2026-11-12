# Rules

The `rules` tool checks the effects of functions, locks, pairs of calls and (in
[ownership.md](ownership.md)) the ownership of pointers and the values of the
collector. The codes are listed in the README and described below and in
[ownership.md](ownership.md).

## Annotations

`include/cchecker.h` defines the macros that the rules read: `CC_SHORT`,
`CC_BLOCKING`, `CC_HOT`, `CC_ACQUIRES(lock)`, `CC_RELEASES(lock)`,
`CC_NORETURN`, `CC_MAY_JUMP`, `CC_JUMPS`, `CC_CATCHES`, `CC_JUMP_RELEASES`,
`CC_NO_SYSCALL_UNDER(lock)`, `CC_LOCK_LEVEL(n)`, `CC_PAIR(set, restore)`,
`CC_OWNS`, `CC_FREES`, `CC_OWNS_OUT`, `CC_GC`, `CC_GC_ALLOC`, `CC_ASSUME_SHORT`
(the function counts as fine for `CC_SHORT`), `CC_STOP` (no rule walks into the
function; both are assumptions, see [Settings](settings.md)) and
`CC_IGNORE("CODE", "reason")` (a suppression). The macros are empty, in every
build and with every compiler, except when cchecker dumps the AST: it defines
`CCHECKER_AST`, and with clang the macros become
`__attribute__((deprecated("cchecker:...")))` (the JSON AST of clang 19 drops
the text of `annotate` and keeps the message of `deprecated`). The dump runs
with `-w`, so this gives no warning. A normal build of your project carries no
annotation; a project that wants an attribute for another tool defines the
macros itself.

```c
#include "cchecker.h"

CC_SHORT int next_id(void);
void adopt(CC_OWNS char *name);
CC_PAIR(mask_signals, restore_signals) int guarded(void);
```

An annotation may be on any declaration of the function: a prototype in a header
holds for the definition.

## Effects

The `rules` tool runs `clang -Xclang -ast-dump=json -fsyntax-only` on each file
with its flags, keeps the declarations written in the files under the working
directory (for a declaration that a macro writes, where the macro is used), and
builds one call graph from all the files of the run. A static function is
another function in each file. A rule walks the graph from each annotated
function that the project defines, and its finding is at that function. The
message names the call that breaks the rule; the printed line and `path` add the
shortest call path to it:

```text
src/ids.c:7:14 CC-EFFECT-SHORT-BLOCKS short function next_id reaches the blocking call read: next_id -> helper -> read
```

The baseline matches the message, without the path, so a finding stays accepted
when its path changes.

A root gives one finding per code, at the nearest bad call. With `--all-paths`
it gives one for each distinct bad call it reaches, each with its shortest path,
so a project sees them all in one run. The message names the bad call by its
name, so each finding is keyed in the baseline by the name of its call (code,
file and message: `short function serve reaches the blocking call sleep`; two
static functions of one name in two files share that key, and the baseline
counts them), and the nearest one is the finding a run without `--all-paths`
gives, with the same key. A baseline written with `--all-paths` holds the others
too, so run CI the same way: a run without it counts them fixed. A bad call is
reached once, by its shortest path, and the walk does not go past it.

The walk does not go into a function that never returns or is cold: one declared
`_Noreturn`, `[[noreturn]]`, `CC_NORETURN`, `CC_JUMPS` or
`__attribute__((noreturn))` (in its type too, behind a typedef: `typedef void
fatal_fn(const char *) __attribute__((noreturn)); fatal_fn die;`), or
`__attribute__((cold))`, on any of its declarations, and a library call that
never returns (`abort`, `exit`, `_exit`, `longjmp`, `pthread_exit`, ...), though
`_exit` enters the kernel. Such a call is an error exit (`out_of_memory`,
`die`), not the path the rules are about. `[effects] follow_cold = true` follows
it. A `CC_BLOCKING` mark on such a function wins: it is a blocking call. The
lock rules (`CC_NO_SYSCALL_UNDER`) follow every call whatever it says.

| Code | |
|---|---|
| `CC-EFFECT-SHORT-BLOCKS` | a `CC_SHORT` function reaches a `CC_BLOCKING` function or a known blocking call |
| `CC-EFFECT-HOT-ALLOCATES` | a `CC_HOT` function reaches a call that allocates or frees heap memory |
| `CC-EFFECT-HOT-SYSCALL` | a `CC_HOT` function reaches a system call; a blocking call is one too |

The known calls are those of libc, pthread, libuv, OpenSSL and the Boehm
collector that block (`read`, `sleep`, `pthread_mutex_lock`, `uv_run`, a
`uv_fs_*` call such as `uv_fs_read` whose last argument, the callback, is `NULL`
or 0, as it then runs at once; `uv_run` blocks unless its mode is a constant
`UV_RUN_NOWAIT`, which is still a system call for `CC_HOT`), allocate (`malloc`, `free`, `strdup`,
`GC_malloc`, `SSL_new`) or enter the kernel (`write`, `mmap`, `close`); an
unlock or the signal of a condition counts as a system call, as it wakes a
waiter with a futex call. A `uv_fs_*` call run at once whose libc call does not
block (`uv_fs_close`, `uv_fs_stat`, `uv_fs_unlink`, `uv_fs_mkdir`, ...) is a
system call and not a blocking one, as `close` is. The lists are in
`src/known.agc`. A function the project defines is judged by its body; a library
function that is not listed has no effect. A known name is known by name alone:
a project function named `remove`, `rewind`, `ftell`, `dlsym` or `link` counts
as the libc one in a run that does not read its body, as when the run only sees
its declaration and its body is in a file left out.

A call through a function pointer reaches every function the project stores in
the same place: a field of a struct or a union (by record and field name, in an
initializer or an assignment), a variable, or a parameter of a function (from
the direct calls that pass a function), and every function of a place copied
into it (`box.handle = handle`). An item of an initializer of a struct or an
array counts designated or not (`{[3] = f}`). A cast is seen through, so a
function kept in a `void *` or an `uintptr_t` is reached by a call through it,
but not one kept in a table whose first item is a literal number (`uintptr_t t[]
= {0, (uintptr_t)f}`): that is a table of numbers (see [The AST
dump](#the-ast-dump)). A variable with `__attribute__((cleanup(f)))` calls `f`.
A pointer that comes from anywhere else reaches nothing: one that no checked
file stores a function in (set outside the files of the run, or never set), a
return value, the arguments of a variadic function, and a function handed to a
library that calls it back (`qsort`; a libuv callback is a root of its own, see
[Roots](settings.md#roots)). Two calls through pointers that start at the same
place (`x->f(1)->g(2)`) are one call to the walk, and each reaches the functions
of both: more findings, never fewer. A walk goes only through what the run read,
so run it on all the files of the project: with a subset of the files, a call
into a file that was not run reaches nothing. For the baseline, only a full run
of a compile database covers the findings of the rules: a run of some files
never counts them fixed and never drops them on `--update-baseline`.

## Locks on every path

The rules build a control flow graph of each function that takes or releases a
lock, and follow every path through it: `if`, `switch` with its fallthrough and
without a `default`, loops with `break` and `continue`, `goto` (a computed one
may go to any label), `return`, `&&`, `||`, `?:`, `x ?: y` and statement
expressions. A path ends at a `return`, at the end of the body, or at a call
that never comes back (`abort`, a `_Noreturn` or `noreturn` function, through a
typedef or a function pointer too, or one marked `CC_NORETURN`, such as a
function that ends the thread); a lock held there is not a finding. The cleanup
function of a variable with `__attribute__((cleanup(f)))` runs on every way out
of its block.

A call of a function that may jump out (it returns, or calls `longjmp` on an
error, as an interpreter raises one), marked `CC_MAY_JUMP` or named in `[assume]
may_jump` (see [Settings](settings.md)), is a way out too: the path goes on
after the call, and it also leaves the function there. A lock held before the
call is `CC-PATH-LOCK-NOT-RELEASED` on that way out (a `CC_PAIR` set and not
restored is `CC-PATH-PAIR-NOT-RESTORED`), with the call as the last step of
`path` (`7:72 may jump in check_size`): the code that catches the jump does not
know the lock. Release it before the call, or check what may fail first. A jump
does not run the `cleanup(f)` functions of the variables, so a lock that only a
cleanup function releases is held on the jump. Only a direct call can jump: a
call through a function pointer never does. A call of a function that always
jumps out and never returns (an interpreter's raise), marked `CC_JUMPS` or named
in `[assume] jumps`, is that way out alone: the lock rules check it as a jump,
with `jumps in check_size` as the last step, and the path ends there, so what
comes after the call is not on that path. `CC_MAY_JUMP` on a function that never
returns (`_Noreturn`, `CC_NORETURN`) is the same. The jump adds no state to the
walk, so the limits below do not change.

A function that calls a function that may jump out or jumps (marked, listed, or
found so in turn), directly, may jump out too, unless it catches the jump: it
calls `setjmp` or `sigsetjmp`, is marked `CC_CATCHES`, or is named in `[assume]
catches`. A function that no rule walks into (`CC_STOP`, `[assume] stop`) does
not either. So only the functions that raise need a mark, not every helper that
reaches them. A call of `setjmp` anywhere in a function counts as catching every
jump of its calls: an approximation, so a jump from a call before the `setjmp`,
in the branch that handles the jump, or to another `jmp_buf` counts as caught
too. The last step of `path` names the chain of calls down to the marked
function, a shortest one, and at most three of it (`7:72 may jump in sized
(check_size)`, `may jump in z (y, x, w, ...)`); a name that static functions of
two files share has its file (`helper@src/a.c`). A function that never returns
and reaches a jump is a way out where the path ends, as at a `CC_JUMPS` call,
and says so: `may jump in bad_signature (fail), never returns` (it may also
exit). The jump of a function that catches still counts at its own calls:
catching stops only what its callers see. A finding at an inferred jump has
`may_jump_callers` in `source` of `--json`, and `[library] may_jump_callers =
false` turns the inference off (see [Settings](settings.md)).

A lock helper may write down the lock it takes (for example how many times it
took it, or which lock it holds), so that the code that catches a jump can
release it. Mark such a `CC_ACQUIRES` or `CC_RELEASES` helper
`CC_JUMP_RELEASES`, or name it in `[assume] jump_releases`; for a helper that
takes or releases two locks, the mark holds for both. A lock that a function
takes and releases only through such helpers is no finding at a jump, held
(`NOT-RELEASED`) or released before it (`NOT-HELD`), and is still checked on
every return. A lock that the function also takes or releases another way
(`pthread_mutex_lock`, a helper without the mark) is checked at the jumps as
before, since the catcher does not know that take. The mark is on the helper,
not on the class of the lock, as two locks of one class (`lock.mutex`) may be
taken one through a recording helper and the other not. It is about locks: the
set of a `CC_PAIR` with the mark is still `CC-PATH-PAIR-NOT-RESTORED` at a
jump. A suppression of the code on the function (`CC_IGNORE` or `cchecker:
ignore`) hides the findings of a jump too, and those of its returns with them.

| Code | |
|---|---|
| `CC-PATH-LOCK-NOT-RELEASED` | a path returns, or jumps out at a `CC_MAY_JUMP` or `CC_JUMPS` call, with a lock that the function took |
| `CC-PATH-LOCK-NOT-HELD` | a path releases a lock that the function did not take |

The finding is at the function, once for each code and lock, and `path` is a
shortest path that breaks the rule, from the last call that took the lock (or
released it, for `NOT-HELD`) to the end: `7:7 true` is the condition at line 7,
column 7, taken as true.

```text
src/queue.c:5:5 CC-PATH-LOCK-NOT-RELEASED pop does not release q->mu on every path: 6:3 takes q->mu -> 7:7 true -> 8:5 returns
```

A lock is the expression the call names, by its field path: `&q->mu`, `q->mu`
and `(&q->mu)` are one lock, and `&a->mu` and `&b->mu` are two. A local variable
that is set once, where it is declared, stands for its value (`pthread_mutex_t
*m = &q->mu`). The known calls take or release the lock of their first argument:
the mutexes, spin locks and read-write locks of pthread, C11 and libuv, and the
critical sections and SRW locks of Windows (`src/known.agc`). A call that may
fail to take its lock (`pthread_mutex_trylock`, and `pthread_mutex_lock`, which
returns an error code) takes it when it is a condition compared with 0, on the
side where it gave 0: `if (pthread_mutex_trylock(&q->mu) != 0) return;`. Its
result kept in a local variable or a parameter (`int r =
pthread_mutex_trylock(&q->mu);`, `bool ok = pthread_mutex_trylock(&q->mu) ==
0;`, also in a condition: `if ((r = pthread_mutex_trylock(&q->mu)) != 0)`)
takes the lock on the paths where the call gave 0, and a later test of the
variable goes the same way as the call: `if (r != 0) return;`, `if (!r)`, `if
(r == EBUSY)`, `switch (r)` (`case 0` is where it gave 0, another number,
`default` and no case after a `case 0` where it did not), and a test of a copy
set once (`int busy = r; if (!busy)`). A new value of the variable forgets the
result (`r = work(q); if (r == 0) unlock(&q->mu);` is a finding). A path that
releases the lock where the call failed starts at the call (`6:11 fails`). The
failure of a call that waits for its lock (`pthread_mutex_lock`) is an error,
which a path reaches only when a test of the variable can follow the call
before a new value of it (`ret = pthread_mutex_lock(&q->mu); ...; return ret;`
does not, nor does a test of `ret` before the call or after `ret = work();`). A
copy of a `static` or `volatile` local, or of one whose address is taken, is not
followed. A wait on a condition (`pthread_cond_wait(&cv, &q->mu)`) gives the
lock back before it returns, so it changes nothing.

A path does not go where a condition that the function tests twice would have to
be true and false, so `if (locked) lock(); ...; if (locked) unlock();` passes. A
test against 0 is a test of what it compares (`if (n == 0)` and `if (n)` are one
condition, and `n == EBUSY` tells that `n` is not 0 where it holds), and a whole
number written to a local variable or a parameter is a value the path knows
(`bool taken = false; ...; taken = true;`, `int locked = 0;`), as the kept
result of a trylock is, when a test of the variable guards a lock call or a way
out (`return`, `goto`, `break`, `continue`): other flags cost no states. A local
whose address is taken anywhere in the function (`int *p = &locked;`, `struct
waiter w = { &done };`), a `volatile` one and a `static` one never have a known
value written, as a write through a pointer or another call can change them,
and a write through a pointer (`*p = 1`) forgets what their tests told. A write
to a variable of the condition, or a call given its address (`f(&locked)`),
forgets its value; a call given `&q->mu`, or the address of any other field
(`atomic_store(&q->ready, 0)`, `f(&q->count)`), does not change `q`: the values
of the conditions are kept by variable (a local that shadows another is a
variable of its own), not by field, so a condition on `q->ready` keeps its value
after `atomic_store(&q->ready, 0)`; copy the field to a local first and test the
local (`int ready = q->ready; if (ready) ...`) when the call may change it. A
condition leaves the state of a path after its last test before a write to one
of its variables, so a function with many flags, each tested twice around a
lock, stays in a number of states that grows with the flags when their tests do
not overlap, not as a power of two. A function whose paths would take more than
200 000 states to follow is walked again without these conditions, which may
follow paths that cannot happen; when that is not enough either, its findings
are those of the paths followed. Either way the run lists it in
`incomplete_functions` of `--json` (`file`, `line` and `function`) and on
standard error (the exit code does not change). A function whose AST has more
than 20 000 nodes (about four times the largest of the Agentica VM) gets no
graph: that is an error of the `rules` tool on its file, so the exit code is 2,
and the rest of the run is checked.

A function that takes a lock for its caller, or releases the caller's lock, says
so on its prototype: `CC_ACQUIRES(lock)` or `CC_RELEASES(lock)`, with the lock
written in the names of its parameters (or a global). A call then takes or
releases that lock in the words of the call: for `CC_ACQUIRES(q->mu) void
queue_lock(struct queue *q)`, `queue_lock(vm->q)` takes `vm->q->mu`. Such a
function is a lock helper: its own body is trusted (a count of nested takes, a
spin before the wait), and its callers are checked. Without an annotation, a
function that takes a lock and returns with it is a finding, so a forgotten
unlock never passes for a helper. Put the annotation on the prototype that the
callers include: a caller sees the declarations of its own file. A function that
takes or releases a lock only on some of its returns (`false` when it dropped
the lock) is beyond these rules: suppress its findings with `CC_IGNORE`, with
the reason. A call through a function pointer does nothing to the locks.

Limits: a lock is counted by its text, so a lock taken in a loop over several
objects (`lock(&a[i]->mu)`), locks taken hand over hand, or a pointer that is
set again between the lock and the unlock (`q = q->next`) can give false
findings; the result of a trylock kept in a field or a global (`q->r =
trylock(&q->mu)`) takes nothing, and a helper that takes a lock only when it
returns 0 or sets an out-parameter (`bool *locked`) needs `CC_IGNORE` in its
body and its callers; a global that a called function changes keeps the
value the path knew; a lock taken more than twice on a path, with no release
between, counts as taken twice (and one released more than twice as released
twice), so such a path can give a false finding or miss one.

## What runs while a lock is held

A lock held for short sections only, which other threads spin for, is marked on
its field (or on a global lock): `CC_NO_SYSCALL_UNDER()`. While a path holds it,
no call is a system call or a blocking call (the lists of the effects, a lock or
an unlock of another lock included, and a `CC_BLOCKING` function) or reaches one
through the functions of the project, a call through a function pointer included
(the functions stored in it), except the release of the lock itself and a wait
on a condition with it. A lock taken under it by a system call is one finding,
at its take: its release is none, by a library call or a `CC_RELEASES` helper;
the release of a lock taken by a trylock, which is no system call, is the
finding. A `CC_RELEASES` helper that releases the quiet lock is held to the
system calls it may make before that release, on any path of its body (a
`write`, the signal of a condition), a wait with the lock included, as the lock
is held again after it; what it does after the release of the quiet lock is no
finding. A helper that releases a lock taken under the quiet lock, or the
restore of a `CC_PAIR` whose set ran under it, is held to all its system calls.
An unlock or a wait in a helper is a release, never its system call. A call
through a function pointer releases nothing, so it is never such a release.
Limits: a lock taken under the quiet lock is told by the order of the takes on
the path, so the release of a quiet lock taken again (a recursive mutex) counts
as the release of the quiet lock, a lock taken both before and after the quiet
lock counts as taken after it, and a helper that takes two locks in one call has
them both taken at that call, neither under the other.
`CC_NO_SYSCALL_UNDER(lock)` on a function says the same of one lock of that
function, in the names of its parameters.

`CC_LOCK_LEVEL(n)` on the field of a lock (or a global lock) orders the locks: a
path takes a lock with a level only while every lock it holds with a level has a
lower one, and it calls a function that takes one (in its body or in the
functions it reaches, or those stored in a pointer it calls) only then. Two
locks of the same level are never held together. A trylock
(`pthread_mutex_trylock`) never waits, so it is never out of order. One
exception: a called function that takes the class of a lock held again is not
out of order, for a lock that counts its takes by the same thread; the rules
cannot tell it from another lock of the same class.

```c
struct runtime { CC_LOCK_LEVEL(1) pthread_mutex_t sync; ... };
struct runq { CC_NO_SYSCALL_UNDER() CC_LOCK_LEVEL(3) pthread_mutex_t lock; ... };
```

| Code | |
|---|---|
| `CC-PATH-SYSCALL-UNDER-LOCK` | a call under a `CC_NO_SYSCALL_UNDER` lock is or reaches a system call |
| `CC-PATH-LOCK-ORDER` | a lock with a level is taken (or a function that takes one is called) under one of the same or a higher level |

A field is known by its struct and its name (`runq.lock`, the name of a typedef
for an anonymous struct; an item of an array of locks is its field), and a
global by its name (`name@file` for a static one; a parameter or a local of the
same name is not it). The marks are `CC_NO_SYSCALL_UNDER()` with nothing in it
and `CC_LOCK_LEVEL(n)` with a decimal number; another form, or a mark on a field
of a struct with no name, is an error of the `rules` tool (exit code 2) on the
file of the mark, once even when several files include it. A lock is known by
its text in a function, so the same lock written two ways (`&q->mu` and `m` set
later to it) is two locks. A lock of a `CC_ACQUIRES` is followed to its field
through the types of the parameters (`CC_ACQUIRES(s->pool->mu)` on `void
pool_lock(struct server *s)` takes `pool.mu`). The path of a finding goes from
the take of the lock held to the call, and the call path to the system call when
there is one: `13:3 calls bump: bump -> pthread_mutex_lock`.

## Pairs of calls

`CC_PAIR(set, restore)` on a function says that in its body, a call of `set` is
followed by a call of `restore` on every path that returns, as a lock is by its
unlock (the same graph and the same walk). On a declaration of `set` itself it
says so in every function that calls `set`. The two are functions, by name,
whatever their arguments: a cleanup function counts as a call. `set` and
`restore` are two functions (a pair of one function, such as `umask`, never
gives a finding); a `set` twice needs two restores.

A `restore` with no `set` before it on the path is a finding in a function that
calls `set` on some path (`gc_pause(); gc_resume(); gc_resume();`), and does
nothing in one that never calls it. That includes a restore that a path reaches
around the set (`if (bad) goto out; gc_pause(); ... out: gc_resume();`). A
restore of two pairs is a finding only when it restores neither. A set made more
than twice on a path counts as twice, and a restore that then finds the count at
zero is no finding.

The walk does not tie a variable to the set it records, so `if (big) {
gc_pause(); paused = 1; } ... if (paused) gc_resume();` and a toggle (`if (on)
set(); else restore();`) give findings. A restore reached without the set is
reported even when the restore is harmless to repeat: `CC_PAIR` is opt-in, so
leave it off such a pair.

The body of a `set` that carries its own `CC_PAIR` is how the pair works (a
wrapper of `GC_disable`), so it may leave another pair set for its caller, but
not on a return of an error value, after which the caller does not call
`restore`: a negative constant (`return -1`, `return -EINVAL`, a negated enum
constant), a null pointer (`NULL`, `(void *)0`, `nullptr`), or a false bool,
read through typedefs. Any other value, `0` of an `int` included, counts as a
success, and a returned variable is not followed (`rc = -1; goto out; out:
return rc;` is a success). A `set` whose `NULL`, `false` or negative return
means success gets a finding on that return.

```c
CC_PAIR(mask_signals, restore_signals) void mask_signals(sigset_t *old);   /* in every caller */
CC_PAIR(gc_pause, gc_resume) int copy_out(struct heap *h);                  /* in copy_out */
```

| Code | |
|---|---|
| `CC-PATH-PAIR-NOT-RESTORED` | a path returns after a call of `set` and no call of `restore` after it |
| `CC-PATH-PAIR-NOT-SET` | a path calls `restore` with no call of `set` before it, in a function that calls `set` |

The path goes from the call of `set` to the return: `7:3 calls mask_signals ->
8:7 true -> 9:5 returns`.

Two pairs on one `set` are two pairs (both restores are needed), and one
`restore` of two sets restores both; the same pair written twice counts once. A
pair holds in the files that see its declaration, as the lock annotations do. A
`CC_PAIR` that names a function the file does not declare does nothing. A `set`
that can fail (and so needs no `restore` when it failed) is beyond the rule, as
a trylock helper is: suppress the finding with `CC_IGNORE`. When the restore
happens in a function that the code calls (`finish(ctx)` calls
`restore_signals`), name that function: `CC_PAIR(mask_signals, finish)`.

## The AST dump

The AST of a file is tens of MiB with its system headers, more than a process
output holds in Agentica (1 MiB): `sh` writes it into a FIFO in a private folder
under `$TMPDIR`, cchecker copies it to a file there with the indent of each line
cut short (clang indents each level of nesting, so a deeply nested function,
such as a chain of 3000 else-if, gives gigabytes of spaces), and reads that file
line by line, keeping only the declarations of the project. A table of numbers is not kept: an array of a
number or character type, or whose first item is a number (`const uint8_t
ROM[]`); a number cast to a pointer (`0`, `NULL`, or `1` under
`-Wno-int-conversion`) is not a number. A declaration of more than a million
lines of the dump is left out: when it names a function, before or past that
cap, it is a tool error, and otherwise (a table of enum values or of structs of
numbers) it is counted in `skipped_declarations` of `--json` and in a line on
standard error, while the rest of the file is checked. A dump that ends early is
a tool error. The folder is removed at the end of the run, and a run removes the
folders that killed runs left there: a folder of the same user, private, not a
link, holding only dumps and their FIFOs, whose process is gone. Runs in different PID
namespaces that share `$TMPDIR` can remove each other's folders.
