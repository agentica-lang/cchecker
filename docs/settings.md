# Settings

cchecker reads its settings from the first of these that it finds:

1. The file of `-c FILE` (`--config FILE`). When it has a `[tool.cchecker]`
   table (an `agentica.toml` or another manifest), that table; else the whole
   file. A file that is not there or cannot be read is an error (exit 2).
2. `cchecker.toml` in the working directory, the project folder.
3. The `[tool.cchecker]` table of `agentica.toml` in the project folder. An
   `agentica.toml` without it is skipped.
4. The defaults: every `[library]` flag on, no `[roots]`, `follow_cold = false`,
   no `[assume]`.

The first one wins, and the others are not read. `--json` says which in `config`
(`"cchecker.toml"`, the path given to `-c`, or `"defaults"`), and a run without
`--json` says it in one line on standard error. A key that is not one of those
below, or a value of the wrong type, is an error (exit 2), so a typo cannot turn
a check off.

```toml
[library]
libc_blocking = true
pthread_blocking = true
libuv_blocking = true
libgc_blocking = true
libuv_callbacks_short = true
libgc_alloc = true
libc_nonblocking_flags = true

[roots]
short = ["io_poll", "on_timer"]
hot = ["dispatch"]

[effects]
follow_cold = false

[assume]
short = ["run_or_queue"]
stop = ["trace_emit"]
short_locks = ["queue.mu"]
```

`[library]` turns each family of library knowledge on or off. All are on by
default. A finding of the rules says in `source` of `--json` the flags that made
it, so a project knows which one to turn off: the family of the blocking call it
reaches (`libc_blocking`), and for an inferred root the inference before it
(`libuv_callbacks_short+libc_blocking`). `source` is not part of the baseline
key. The full lists, with the argument places of the libuv callbacks, are in
`src/known.agc`.

| Flag | What it adds |
|---|---|
| `libc_blocking` | the calls of libc and POSIX that wait, to the blocking calls of `CC_SHORT`: files and streams, sockets, waiting (`poll`, `select`, `sleep`, `wait`, ...), processes (`system`, `popen`), `dlopen`, `dlsym`, POSIX semaphores and message queues, and the C11 threads |
| `pthread_blocking` | `pthread_join`, the locks of `pthread_mutex_`, `pthread_rwlock_` and `pthread_spin_lock`, the waits of `pthread_cond_`, `pthread_barrier_wait` and `pthread_once` |
| `libuv_blocking` | `uv_run`, `uv_sleep`, `uv_thread_join`, the locks and waits of `uv_mutex_`, `uv_rwlock_`, `uv_cond_`, `uv_sem_`, `uv_barrier_wait`, `uv_once`, and the `uv_fs_*` calls whose libc call blocks (`uv_fs_open`, `uv_fs_read`, ...) when their callback, the last argument, is `NULL` or 0 |
| `libgc_blocking` | `GC_gcollect` of the Boehm collector, which stops the world |
| `libuv_callbacks_short` | a `CC_SHORT` root for each function passed as a callback that libuv runs on the loop thread: the callbacks of `uv_timer_start`, `uv_poll_start`, `uv_async_init`, `uv_close`, `uv_read_start`, `uv_write`, `uv_write2`, `uv_shutdown`, `uv_tcp_connect`, `uv_pipe_connect`, `uv_pipe_connect2`, and the `after_work_cb` of `uv_queue_work`, never its `work_cb`, which runs on the pool (see [Roots](#roots)) |
| `libgc_alloc` | the allocators of the Boehm collector (`GC_malloc`, `GC_malloc_atomic`, `GC_realloc`, `GC_strdup`, their `GC_debug_` forms, ...) to the allocators of `CC_GC_ALLOC`, in the rule on values of the collector (`source` `libgc_alloc`) |
| `libc_nonblocking_flags` | the flags that make a blocking call return at once: `open` and `openat` with `O_NONBLOCK`, `recv`, `send`, `recvfrom` and `sendto` with `MSG_DONTWAIT`, when the flag argument is a constant (a flag in a variable leaves the call blocking); such a call is not blocking for `CC_SHORT`. `open` with `O_NONBLOCK` is meant for FIFOs and devices: on a regular file it can still wait for the disk, and the rules do not tell the two apart. The values are those of the target clang builds for (Linux, but on MIPS, SPARC, Alpha and PA-RISC, and macOS); on another target only a flag that the C library defines as a constant of an enum (glibc's `MSG_DONTWAIT`) counts, and the run says on standard error that it does not know the values |

A blocking flag changes only the blocking calls of `CC_SHORT`: the rules of
`CC_HOT` and of `CC_NO_SYSCALL_UNDER` count every known blocking call as a
system call whatever the flags.

`[effects]` holds how the effect rules walk the project's own functions, so it
is not a `[library]` flag, which is a fact of a library. `follow_cold = true`
makes the walk go into a function that never returns or is cold (see
[Rules](rules.md#effects)); by default it does not.

`[roots]` names the functions that are `CC_SHORT` (`short`) or `CC_HOT` (`hot`)
without a mark in the C, by their name (a static function of that name in any
file). A finding of a root of `[roots]` is the same as that of the mark, and a
function both marked and listed is one root. A name that no function of the
compile database defines is an error (exit 2), so a rename cannot leave a rule
that checks nothing. Only a full run of a compile database can tell (a run of
some files does not see the others), so only it checks the names; another run
says on standard error that it did not.

`[assume]` says what the project knows of its own functions and cchecker cannot
see in the C, as `CC_ASSUME_SHORT` and `CC_STOP` do on a declaration. `short`
names the functions that count as fine for `CC_SHORT`: the short rule does not
walk into them (a helper that runs a request inline only on the loop thread and
queues it otherwise, a read of a descriptor that never blocks); the other rules
still do. `stop` names the functions that no rule walks into, and whose calls
count for none of them (a trace call behind a runtime flag): the effect rules,
the system calls under a `CC_NO_SYSCALL_UNDER` lock, and the lock levels. Either
holds for every root, inferred roots included, and for every path of
`--all-paths`; the ownership rules and the rule on values of the collector,
which read one function at a time, do not change.

An assumption cuts the walk into the function, not the function itself: a root
that is assumed short or stopped still has its own body checked, as a caller
does not walk into it. What the function calls is not walked either, a callback
passed to it as a function pointer included. A function that blocks itself
(`CC_BLOCKING`) cannot be assumed short: its mark wins. `CC_STOP` wins over
every other mark, `CC_BLOCKING` included. A name is that of the function (a
static function of that name in any file, as in `[roots]`), and a name that no
function of the compile database declares is an error (exit 2) that names its
key (`trace (assume.stop)`), checked as those of `[roots]` are.

A short lock is one held for a few instructions: a lock whose field or global is
marked `CC_NO_SYSCALL_UNDER()`, or whose class `[assume] short_locks` names:
`queue.mu` for the field `mu` of `struct queue`, the name of a global, and for a
static global its name (every static global of that name, as `[assume] short`
names static functions) or its name and the end of the path of its file
(`big_lock@src/queue.c`). Taking it (`pthread_mutex_lock(&q->mu)`) is not
blocking for `CC_SHORT`; the rule on what runs under it still checks that no
system call does, and `CC_HOT` still counts the call. A lock that the rules
cannot tell is not short, so the call still counts: one named through a
parameter, or through a local that points to it (`pthread_mutex_t *m = &q->mu;
pthread_mutex_lock(m)`). A lock wrapper is assumed short with `CC_ASSUME_SHORT`
or `[assume] short`. A class of `short_locks` that no lock of the compile
database has (none taken, none marked) is an error, as for the names.

A suppression and an assumption answer different questions. A suppression
(`cchecker: ignore`, `CC_IGNORE`) says that one finding is wrong, at one place;
it stays next to that code and shows when the finding goes away
(`CC-UNUSED-IGNORE`). An assumption says something about a function, once, for
every root and every path that reaches it: use it when the same function makes
many findings for the same reason, and a suppression when one finding is wrong.

## Roots

A rule starts from its roots, which come from three places. A project leans on
them in this order, and adds the next one only for what the one before does not
cover:

1. Inferred roots: a function passed as a callback to a libuv call that runs it
   on the loop thread is a `CC_SHORT` root (`libuv_callbacks_short` above), as
   it runs on the event loop. `--no-infer` or the flag set to false turns it
   off.
2. `[roots]` in the settings, which keeps the C as it is.
3. The marks of `cchecker.h` in the C (see [Annotations](rules.md#annotations)),
   for what neither covers.

A function that is a root in more than one way is one root. The callback of an
inferred root is a function named in the call, or a pointer that the rules
follow to the functions stored in it (see [Rules](rules.md#effects)), such as a
parameter that callers pass a function to. `NULL` or 0 is no callback. A
callback that leads to no function (the return value of a call, a parameter that
no caller passes a function to) is listed in `unresolved_callbacks` of `--json`,
each with `call`, `argument` (its place, from 0), `file` and `line` (absolute
for a call outside the working directory, such as a body that includes a file
from outside), and a run without `--json` says how many in one line on standard
error, so a root is never lost without a word.

A finding of an inferred root has its place in `root` of `--json` (`callback of
uv_read_start at src/net.c:41`), and the printed line ends with it:

```text
src/net.c:12:13 CC-EFFECT-SHORT-BLOCKS short function on_read reaches the blocking call write: on_read -> write (root: callback of uv_read_start at src/net.c:41)
```

The root is not part of the message, as the path is not: the baseline matches
the message, and a root that named the line of its call would make a finding new
each time the code above that call moves. A finding of a marked or listed root
has no `root` and does not name `libuv_callbacks_short`, as the flag would not
turn it off.
