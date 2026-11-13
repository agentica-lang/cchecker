# Settings

cchecker reads its settings from the first of these that it finds, and the
others are not read:

1. The file of `-c FILE` (`--config FILE`). When it has a `[tool.cchecker]`
   table (an `agentica.toml` or another manifest), that table; else the whole
   file. A file that is not there or cannot be read is an error (exit 2).
2. `cchecker.toml` in the working directory, the project folder.
3. The `[tool.cchecker]` table of `agentica.toml` in the project folder. An
   `agentica.toml` without it is skipped.
4. The defaults: every `[library]` flag on except `short_lock_sections`, no
   `[roots]`, `follow_cold = false`, no `[assume]`.

`--json` says which in `config` (`"cchecker.toml"`, the path given to `-c`, or
`"defaults"`), and a run without `--json` says it in one line on standard error.
A key that is not one of those below, or a value of the wrong type, is an error
(exit 2), so a typo cannot turn a check off.

```toml
# An example: every key is optional, and the defaults are in the sections below.
[library]
libuv_blocking = false
short_lock_sections = true

[roots]
short = ["io_poll", "on_timer"]
hot = ["dispatch"]

[effects]
follow_cold = true

[database]
fold_ignoring = ["BUILDING_UV_SHARED"]

[assume]
stop = ["trace_emit"]
stop_calls = ["on_exit>close_handles"]
acquires = ["my_lock(0)"]
```

Every value is a list of strings except the booleans. A name in a list of
`[roots]` or `[assume]` is a function name (a static function of that name in
any file) or `name@path`: the function whose file ends with `path`, by whole
parts, with no `..` and a leading `./` ignored (`put@src/files.c`, or
`put@files.c` when no other `files.c` has a `put`). In `[assume]` the path may
be the file of the definition or of any declaration (`slow@slow.h`); in
`[roots]` it is the file of the definition. It works in every list that names
functions, and on each side of a `stop_calls` pair; the lists of fields and
locks (`stop_fields`, the classes of `short_locks`, `owned_locks`) name classes
instead (below). `acquires`, `releases`, `tries` and the wrappers of
`short_locks` add the place of the parameter: `name@path(0)`.

A name or `name@path` that no function of the compile database declares is an
error (exit 2) that names its key (`trace (assume.stop)`), so a rename cannot
leave a setting that does nothing. Only a full run of a compile database can
tell (a run of some files does not see the others), so only it checks the names;
another run says on standard error that it did not.

## `[library]`

Each flag turns a family of library knowledge on or off; all are on by default
except `short_lock_sections`. A finding of the rules has the flags that made it
in `source` of `--json` (the family of the blocking call, `libc_blocking`; for
an inferred root the inference before it,
`libuv_callbacks_short+libc_blocking`), so a project knows which one to turn
off. `source` is not part of the baseline key. The lists are the sets in
[src/known.agc](../src/known.agc) (`LIBC_BLOCKING`, `PTHREAD_BLOCKING`,
`LIBUV_BLOCKING`, `LIBUV_SYSTEM`, `LOOP_CALLBACKS`) and match libuv 1.50: a call
that a later libuv adds is not known until they are updated.

| Flag | What it adds |
|---|---|
| `libc_blocking` | the calls of libc and POSIX that wait, to the blocking calls of `CC_SHORT`: files and streams (`read`, `fopen`, `printf`, `fsync`), sockets (`accept`, `recv`, `getaddrinfo`), waiting (`poll`, `sleep`, `waitpid`), processes (`system`, `popen`), `dlopen`, `dlsym`, POSIX semaphores and message queues, and the C11 threads (`thrd_join`, `mtx_lock`) |
| `pthread_blocking` | `pthread_join`, the locks of `pthread_mutex_`, `pthread_rwlock_` and `pthread_spin_lock`, the waits of `pthread_cond_`, `pthread_barrier_wait` and `pthread_once` |
| `libuv_blocking` | `uv_run`, `uv_sleep`, `uv_thread_join`, the locks and waits of `uv_mutex_`, `uv_rwlock_`, `uv_cond_`, `uv_sem_`, `uv_barrier_wait`, `uv_once`, and the `uv_fs_*` calls whose libc call blocks (`uv_fs_open`, `uv_fs_read`, `uv_fs_write`, `uv_fs_fsync`, ...) when their callback, the last argument, is `NULL` or 0 |
| `libgc_blocking` | `GC_gcollect` of the Boehm collector, which stops the world |
| `libuv_callbacks_short` | a `CC_SHORT` root for each function passed as a callback that libuv runs on the loop thread (`uv_timer_start`, `uv_read_start`, `uv_write`, `uv_close`, the callback of a `uv_fs_*` request, the `after_work_cb` of `uv_queue_work` but never its `work_cb`, ...; `LOOP_CALLBACKS` has each call and the place of its callback), and a function stored in the `exit_cb` field of `uv_process_options_t` (by an assignment or an initializer; the root names `uv_process_options_t.exit_cb`). See [Roots](#roots) |
| `libgc_alloc` | the allocators of the Boehm collector (`GC_malloc`, `GC_malloc_atomic`, `GC_realloc`, `GC_strdup`, their `GC_debug_` forms) to the allocators of `CC_GC_ALLOC` (`source` `libgc_alloc`) |
| `libc_nonblocking_flags` | the flags that make a blocking call return at once, so that it is not blocking for `CC_SHORT`: `open` and `openat` with `O_NONBLOCK`, `recv`, `send`, `recvfrom` and `sendto` with `MSG_DONTWAIT`, `waitpid`, `wait3`, `wait4` and `waitid` with `WNOHANG`, and `uv_run` with `UV_RUN_NOWAIT` alone (not `UV_RUN_ONCE`, `UV_RUN_DEFAULT` or a mix) |
| `may_jump_callers` | the inference of jumps through the calls ([Jumps](rules.md#jumps)); a finding at such a call has this flag in `source`. Not library knowledge, but turned off the same way |
| `short_lock_sections` | off by default, experimental: a lock is short when none of its critical sections reaches a blocking call (see [Short locks](#short-locks)). Not library knowledge, and the one flag that is false unless the settings set it true |

A blocking flag changes only the blocking calls of `CC_SHORT`: `CC_HOT` and
`CC_NO_SYSCALL_UNDER` count every known blocking call as a system call whatever
the flags.

`libc_nonblocking_flags` applies when the flag argument is a constant, or a
local that gets only constants (no `&`, `++` or `op=`) and gets one before the
call on every path: a statement before the call in a block that holds it, with
no `case` of an outer switch between them and no `goto` in the function. Another
variable leaves the call blocking. `open` with `O_NONBLOCK` is meant for FIFOs
and devices: on a regular file it can still wait for the disk, and the rules do
not tell the two apart. The values are those of the target clang builds for
(Linux, but on MIPS, SPARC, Alpha and PA-RISC, and macOS); on another target
only a flag that the C library defines as a constant of an enum (glibc's
`MSG_DONTWAIT`) counts, and the run says on standard error that it does not know
the values.

## `[effects]`

`follow_cold = true` makes the walk of the effect rules go into a function that
never returns or is cold (see [Rules](rules.md#effects)); by default it does
not.

## `[database]`

An entry of the compile database that repeats a file (the same folder and the
same flags) is checked once, the first, and `folded` of `--json` counts the
others. The flags that only change the code the compiler makes for a shared
library do not count: `-fPIC`, `-fpic`, `-fPIE`, `-fpie` and CMake's
`-D<target>_EXPORTS`. Any other define or include path can change the findings,
so such entries are each checked.

`fold_ignoring` names more defines that do not count, when a build adds them to
a second library (libuv's `BUILDING_UV_SHARED`): two entries of one file that
differ only in those defines, with any value (`-DNAME`, `-DNAME=1`, `-D NAME`),
are one. A name is C's own (`NAME`, not `-DNAME`, `NAME=1` or `A,B`), and the
list is taken as written (`-UNAME -DNAME` and `-UNAME` fold with `["NAME"]`). A
define in the list hides a different `#ifdef` from the entries left out, so list
only those that do not change the C the rules read; one that adds test-only code
or changes linkage (`UNIT_TESTING`) is a trade-off. Changing the list changes
which entries run, so a finding that only an entry left out had counts as fixed
for a baseline (`--update-baseline` drops it, `--strict-baseline` names it as
stale), and one that was out comes back as new.

## Roots

A rule starts from its roots, which come from three places. A project leans on
them in this order, and adds the next one only for what the one before does not
cover:

1. Inferred roots: a function passed as a callback to a libuv call that runs it
   on the loop thread is a `CC_SHORT` root (`libuv_callbacks_short`).
   `--no-infer` or the flag set to false turns it off.
2. `[roots]`: `short` and `hot` name the functions that are `CC_SHORT` or
   `CC_HOT` without a mark in the C. A finding of such a root is the same as
   that of the mark. A name shared by static functions of several files marks
   all of them; `name@path` marks one.
3. The marks of `cchecker.h` in the C (see [Annotations](rules.md#annotations)).

A function that is a root in more than one way is one root. The callback of an
inferred root is a function named in the call, or a pointer that the rules
follow to the functions stored in it (see [Rules](rules.md#effects)). `NULL` or
0 is no callback. A callback that leads to no function (the return value of a
call, a parameter that no caller passes a function to) is listed in
`unresolved_callbacks` of `--json`, each with `call`, `argument` (its place,
from 0; -1 for a function stored in `exit_cb`, where `call` is
`uv_process_options_t.exit_cb`), `file` and `line` (absolute for a call outside
the working directory), and a run without `--json` says how many in one line on
standard error, so a root is never lost without a word.

A finding of an inferred root has its place in `root` of `--json` (`callback of
uv_read_start at src/net.c:41`), and the printed line ends with it:

```text
src/net.c:12:13 CC-EFFECT-SHORT-BLOCKS short function on_read reaches the blocking call write: on_read -> write (root: callback of uv_read_start at src/net.c:41)
```

The root is not part of the message, as the path is not: the baseline matches
the message, and a root that named the line of its call would make a finding new
each time the code above it moves. A finding of a marked or listed root has no
`root` and does not name `libuv_callbacks_short`.

## `[assume]`

`[assume]` says what the project knows of its own functions and cchecker cannot
see in the C, as the marks do on a declaration. An assumption says something
about a function, once, for every root and every path that reaches it; a
suppression (`cchecker: ignore`, `CC_IGNORE`) says one finding is wrong, at one
place, and shows when the finding goes away (`CC-UNUSED-IGNORE`). Use an
assumption when the same function makes many findings for the same reason.

| Key | Names | Like the mark |
|---|---|---|
| `short` | functions that count as fine for `CC_SHORT`: that rule does not walk into them (a helper that runs a request inline only on the loop thread and queues it otherwise); the other rules still do | `CC_ASSUME_SHORT` |
| `stop` | functions that no rule walks into, and whose calls count for none (a trace call behind a runtime flag): the effect rules, the system calls under a `CC_NO_SYSCALL_UNDER` lock, the lock levels, the inference of jumps | `CC_STOP` |
| `may_jump` | functions that may jump out of their caller; a call of one is a way out for the lock and ownership rules ([Jumps](rules.md#jumps)). Other rules do not change | `CC_MAY_JUMP` |
| `jumps` | functions that always jump out and never return: a way out as for `may_jump`, the path ends there, and the effect walk treats them as an error exit | `CC_JUMPS` |
| `catches` | functions that catch the jumps of the functions they call: the inference of jumps stops there. A function that calls `setjmp` or `sigsetjmp` catches without a mark | `CC_CATCHES` |
| `jump_releases` | lock helpers that record their lock for the code that catches a jump | `CC_JUMP_RELEASES` |
| `acquires`, `releases`, `tries` | lock wrappers in code that cannot be edited, as `name(N)` or `name@path(N)`: see below | `CC_ACQUIRES`, `CC_RELEASES`, `CC_TRIES` |
| `nonblocking` | functions whose descriptors are non-blocking: see below | none |
| `short_locks`, `owned_locks` | lock classes and wrappers: see [Short locks](#short-locks) | `CC_NO_SYSCALL_UNDER` (for `short_locks` classes) |
| `stop_fields`, `stop_calls` | function-pointer fields and calls that no walk follows: see below | none |

An assumption cuts the walk into the function, not the function itself: a root
that is assumed short or stopped still has its own body checked, and what the
function calls is not walked either, a callback passed to it as a function
pointer included. `short` and `stop` hold for every root, inferred roots
included, and for every path of `--all-paths`; the ownership rules and the rule
on values of the collector, which read one function at a time, do not change. A
function that is `CC_BLOCKING` cannot be assumed short: its mark wins. `CC_STOP`
wins over every other mark. A function that is both `stop` and `may_jump` is
both: no walk goes into it, and a call of it is still a way out of its caller. A
function that calls one that may jump out may jump out too, unless it catches
the jump (`may_jump_callers`), where a call cut by `stop_calls` is no call. A
function in `jump_releases` that takes or releases no lock for its caller is
accepted and changes nothing.

### Lock wrappers: `acquires`, `releases`, `tries`

An entry is `name(N)` or `name@path(N)`, `N` the place of the parameter (from 0)
that holds the lock. `my_lock(0)` takes the lock it is given and returns with it
held, `my_unlock(0)` releases it, `my_trylock(0)` takes it only where it returns
0 (for `int my_trylock(pthread_mutex_t *m) { return pthread_mutex_trylock(m);
}`). The body of the wrapper is then no `CC-PATH-LOCK-NOT-RELEASED` or
`CC-PATH-LOCK-NOT-HELD`, and a call of it is a lock for its callers, as the
mark's. A known lock call (`pthread_mutex_lock`, `uv_mutex_unlock`, ...) already
takes or releases its lock, so naming one is an error. The function has one such
lock whatever its declarations call the parameter, and it keeps the one a
`CC_ACQUIRES` already gives it. `N` has to be a named parameter of a declaration
(not past the end or in the `...`), and a function is in only one of the three
lists. A wrapper that no declaration matches, or whose `N` no declaration
reaches, is an error (exit 2) (`my_lock(0) (assume.acquires)`).

The path tells static functions of one name apart (`grab@a.c(0)`, by the file of
the definition); a function with external linkage is one in the whole project,
so its path is only checked against a declaration of it (`slow@slow.h`) and does
not tell two such functions apart: `lock@a.c(0)` in `acquires` and `lock@b.c(0)`
in `releases` name one external `lock` both ways, and `grab@a.c(0)` for a static
`grab` of `a.c` also marks an external `grab` of another file.

### `nonblocking`

Names the functions whose descriptors are non-blocking (libuv sets `O_NONBLOCK`
on every descriptor it polls): their own calls of `read`, `write`, `readv`,
`writev`, `recv`, `send`, `recvfrom`, `sendto`, `recvmsg`, `sendmsg`,
`recvmmsg`, `sendmmsg`, `accept`, `accept4` and `connect` are not blocking for
`CC_SHORT`. It asserts that every descriptor these calls use there is a socket,
a pipe or a terminal: a `read` or `write` of a regular file in a listed function
is hidden too. It holds with `libc_nonblocking_flags = false`, and the inference
of short locks counts these calls as not blocking. The calls of the functions
they call are still blocking, and so are their other blocking calls (`sleep`,
`pread`); `CC_HOT` still counts them as system calls.

### Short locks

A short lock is one held for a few instructions: a lock whose field or global is
marked `CC_NO_SYSCALL_UNDER()`, or whose class `short_locks` names: `queue.mu`
for the field `mu` of `struct queue`, the name of a global, and for a static
global its name (every static global of that name) or `name@path`
(`big_lock@src/queue.c`). Taking it (`pthread_mutex_lock(&q->mu)`) is not
blocking for `CC_SHORT`; the rule on what runs under it still checks that no
system call does, and `CC_HOT` still counts the call. A lock the rules cannot
tell is not short: one named through a parameter, or through a local that points
to it. A lock wrapper is assumed short with `CC_ASSUME_SHORT` or `[assume]
short`. A class of `short_locks` that no lock of the compile database has is an
error.

A lock that reaches a wrapper as a parameter has no class to name. An entry
`name(N)` of `short_locks` (`uv_mutex_lock(0)`, `my_lock(0)`) says that every
lock taken through that wrapper is short: a call of a known take such as
`uv_mutex_lock`, and the takes inside a function of the project of that name,
are not blocking for `CC_SHORT`, whatever the lock, so listing a library take
makes every call of it in the project short. `N` only has to be a number (the
parameter is not checked). A wrapper that no function of the compile database
declares is an error, except a known take such as `uv_mutex_lock`.

Experimental inference, off by default: with `[library] short_lock_sections =
true`, a lock is short without a mark or a setting when no critical section of
its class reaches a blocking call (as the short rule sees it: a take of a lock
that is not short blocks, a call that returns at once does not; a lock helper's
body counts after its take; a class whose sections take another lock becomes
short once that lock is). It may call a lock short wrongly in cases it does not
handle yet.

- Only a full run of a compile database infers (no `FILE`, no `--exclude`, no
  error, no file left unchecked); another run says on standard error that it did
  not. `inferred_short_locks` of `--json` lists the classes (only with the
  inference on).
- It trusts no class whose sections it cannot all see: a lock that a function
  returns or jumps out with, or releases without holding it; a function with
  more paths than the lock walk follows; a lock taken through a parameter or
  reached through a pointer field, global or array of pointers (`c->lk` of
  `pthread_mutex_t *lk`), which may be any class; a take that names no object
  (`&locks[hash(k)]`). A call through a pointer that the run stores no function
  in, or through a `stop_fields` field, counts as blocking in a section. A lock
  taken by a `CC_JUMP_RELEASES` helper gives no finding at a jump.
- `owned_locks` names the pointer fields and globals that point to a mutex of
  their own, which no other field or global points to (`lock.mutex` of `struct
  lock { void *mutex; }`): a lock reached through one has the class of the
  pointer. It matters only with `short_lock_sections` on. cchecker does not
  check the stores into the pointer: one that shares its mutex with another
  class may let the inference call that mutex short while a section of it
  blocks, which hides a `CC-EFFECT-SHORT-BLOCKS`. Names are classes, as in
  `short_locks`; a name in both lists is short by the setting. A name that no
  lock through a pointer has is an error (exit 2).
- An inferred class is matched as it is (inferring the global `lock` does not
  make a static `lock` of another file short) and is short for `CC_SHORT` only,
  not for `CC_NO_SYSCALL_UNDER`.
- It changes findings both ways: a root that only took short locks before its
  blocking call reports that call, not the take (another baseline key), and a
  run that does not infer reports the takes of the inferred locks as new against
  a baseline of a run that did.

### `stop_fields` and `stop_calls`

`stop_fields` names the function-pointer fields that no walk follows, by struct
and field (`request.call`; for an anonymous struct the name of its typedef, or
of the record it is declared in; also when the code names the struct by a
typedef such as `request_t`): a call through the field reaches none of the
functions stored in it, for every rule and every root, `--all-paths` included.
Use it for a field that holds many kinds of work (one `call` slot of every
request). Only a call through the field itself is cut: one through a local that
got its value (`fn f = r->call; f(x)`) is still followed, and a store into the
field still counts when cchecker infers the roots. A field that the compile
database neither stores a function in nor calls through is an error (exit 2).

`stop_calls` cuts the calls between two functions: each entry is
`caller>callee`, and no walk follows a direct call of `callee` in `caller` (all
its call sites there), while the other callers of `callee` still reach it
(`stop` removes the function for all of them). Either side may be a `name@path`
(`on_exit@proc.c>close_handles`). Use it for an edge that cannot happen at run
time. The cut holds for every rule that walks the call graph: the effect rules,
the lock rules, and the inference of `may_jump_callers` (the ownership rules
read one body at a time, so it changes them only through that inference). A call
that a lock or ownership rule reads in the body it checks (the call made under
the lock, a call that may jump) is not cut itself: cut the edge below it. If
`callee` is still reachable from `caller` through another function, that path is
followed. A pair that matches no call of the compile database is an error (exit
2), and so is a value that is not `caller>callee` (`a->b`, `a>b>c`, `a > b`).
