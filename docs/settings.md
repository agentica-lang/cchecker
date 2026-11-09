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
may_jump_callers = true

[roots]
short = ["io_poll", "on_timer"]
hot = ["dispatch"]

[effects]
follow_cold = false

[assume]
short = ["run_or_queue"]
stop = ["trace_emit"]
short_locks = ["queue.mu"]
stop_fields = ["request.call"]
stop_calls = ["on_exit>close_handles"]
may_jump = ["raise_type_error"]
jumps = ["raise_error"]
catches = ["run_protected"]
jump_releases = ["take_recorded"]
```

`[library]` turns each family of library knowledge on or off. All are on by
default. A finding of the rules says in `source` of `--json` the flags that made
it, so a project knows which one to turn off: the family of the blocking call it
reaches (`libc_blocking`), and for an inferred root the inference before it
(`libuv_callbacks_short+libc_blocking`). `source` is not part of the baseline
key. The full lists are the sets `LIBC_BLOCKING`, `PTHREAD_BLOCKING`,
`LIBUV_BLOCKING` and `LIBUV_SYSTEM` in [src/known.agc](../src/known.agc).
The libuv lists (`libuv_blocking`, `libuv_callbacks_short`) match libuv 1.50; a
call that a later libuv adds is not known until the lists are updated.

| Flag | What it adds |
|---|---|
| `libc_blocking` | the calls of libc and POSIX that wait, to the blocking calls of `CC_SHORT`: files and streams (`read`, `write`, `open`, `fopen`, `fread`, `printf`, `fflush`, `fsync`, ...), sockets (`accept`, `connect`, `recv`, `send`, `getaddrinfo`, ...), waiting (`poll`, `select`, `epoll_wait`, `sleep`, `nanosleep`, `wait`, `waitpid`, `sigwait`, ...), processes (`system`, `popen`), `dlopen`, `dlsym`, POSIX semaphores and message queues, and the C11 threads (`thrd_join`, `mtx_lock`, `cnd_wait`, `call_once`, ...) |
| `pthread_blocking` | `pthread_join`, `pthread_timedjoin_np`, the locks of `pthread_mutex_`, `pthread_rwlock_` and `pthread_spin_lock`, the waits of `pthread_cond_`, `pthread_barrier_wait` and `pthread_once` |
| `libuv_blocking` | `uv_run`, `uv_sleep`, `uv_thread_join`, the locks and waits of `uv_mutex_`, `uv_rwlock_`, `uv_cond_`, `uv_sem_`, `uv_barrier_wait`, `uv_once`, and the `uv_fs_*` calls whose libc call blocks (`uv_fs_open`, `uv_fs_read`, `uv_fs_write`, `uv_fs_fsync`, `uv_fs_fdatasync`, `uv_fs_copyfile`, `uv_fs_sendfile`, `uv_fs_mkstemp`, `uv_fs_realpath`) when their callback, the last argument, is `NULL` or 0; `uv_run` with a constant `UV_RUN_NOWAIT` is the exception for `CC_SHORT` (see `libc_nonblocking_flags`), and still a system call for `CC_HOT` |
| `libgc_blocking` | `GC_gcollect` of the Boehm collector, which stops the world |
| `libuv_callbacks_short` | a `CC_SHORT` root for each function passed as a callback that libuv runs on the loop thread: the `cb` of `uv_timer_start` (argument 1, from 0), `uv_poll_start` (2), `uv_async_init` (2), `uv_close` (1) and `uv_walk` (1), the `alloc_cb` and `read_cb` of `uv_read_start` (1 and 2), the callback of `uv_write` (4), `uv_write2` (5), `uv_shutdown` (2), `uv_tcp_connect` (3), `uv_pipe_connect` (3), `uv_pipe_connect2` (5), `uv_listen` (2), `uv_idle_start`, `uv_prepare_start`, `uv_check_start`, `uv_signal_start`, `uv_signal_start_oneshot` and `uv_tcp_close_reset` (1), the `alloc_cb` and `recv_cb` of `uv_udp_recv_start` (1 and 2), the callback of `uv_udp_send` (5), `uv_getaddrinfo` and `uv_getnameinfo` (2), `uv_random` (5), `uv_fs_event_start` and `uv_fs_poll_start` (1), the callback, the last argument, of the `uv_fs_*` requests: `uv_fs_close`, `uv_fs_closedir`, `uv_fs_fdatasync`, `uv_fs_fstat`, `uv_fs_fsync`, `uv_fs_lstat`, `uv_fs_mkdtemp`, `uv_fs_mkstemp`, `uv_fs_opendir`, `uv_fs_readdir`, `uv_fs_readlink`, `uv_fs_realpath`, `uv_fs_rmdir`, `uv_fs_stat`, `uv_fs_statfs` and `uv_fs_unlink` (3), `uv_fs_access`, `uv_fs_chmod`, `uv_fs_fchmod`, `uv_fs_ftruncate`, `uv_fs_link`, `uv_fs_mkdir`, `uv_fs_rename` and `uv_fs_scandir` (4), `uv_fs_chown`, `uv_fs_copyfile`, `uv_fs_fchown`, `uv_fs_futime`, `uv_fs_lchown`, `uv_fs_lutime`, `uv_fs_open`, `uv_fs_symlink` and `uv_fs_utime` (5), `uv_fs_read`, `uv_fs_sendfile` and `uv_fs_write` (6), the `after_work_cb` of `uv_queue_work` (3), never its `work_cb`, which runs on the pool, and a function stored in the `exit_cb` field of `uv_process_options_t` (by an assignment or an initializer; the root names `uv_process_options_t.exit_cb`) (see [Roots](#roots)) |
| `libgc_alloc` | the allocators of the Boehm collector (`GC_malloc`, `GC_malloc_atomic`, `GC_realloc`, `GC_strdup`, their `GC_debug_` forms, ...) to the allocators of `CC_GC_ALLOC`, in the rule on values of the collector (`source` `libgc_alloc`) |
| `libc_nonblocking_flags` | the flags that make a blocking call return at once: `open` and `openat` with `O_NONBLOCK`, `recv`, `send`, `recvfrom` and `sendto` with `MSG_DONTWAIT`, and `uv_run` with the mode `UV_RUN_NOWAIT` alone (not `UV_RUN_ONCE`, `UV_RUN_DEFAULT` or a mix of them; its value is the same on every target, so the target does not matter for it), when the flag argument is a constant (a flag or mode in a variable leaves the call blocking); such a call is not blocking for `CC_SHORT`. `open` with `O_NONBLOCK` is meant for FIFOs and devices: on a regular file it can still wait for the disk, and the rules do not tell the two apart. The values are those of the target clang builds for (Linux, but on MIPS, SPARC, Alpha and PA-RISC, and macOS); on another target only a flag that the C library defines as a constant of an enum (glibc's `MSG_DONTWAIT`) counts, and the run says on standard error that it does not know the values |
| `may_jump_callers` | a function that calls a function that may jump out (`CC_MAY_JUMP`, `CC_JUMPS`, `[assume] may_jump` or `jumps`, or one found so in turn) may jump out too, unless it catches the jump ([Locks](rules.md#locks-on-every-path)); a finding at such a call has this flag in `source`. It is not library knowledge, but it is turned off the same way |

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

A name shared by static functions of several files marks all of them. To mark
one, write `name@path`: the function of that name whose file ends with `path`,
by whole parts of the path (`put@src/files.c`, or `put@files.c` when no other
`files.c` has a `put`), as `short_locks` does for a static lock. The path is
the end of the path of the file as it is, with no `..`; a leading `./` is
ignored. In `[assume]` it may be the file of the definition or of any
declaration of the function (`slow@slow.h` for a prototype in a header); in
`[roots]` it is the file of the definition. It works in every list of `[roots]`
and in `short`, `stop`, `may_jump`, `jumps`, `catches` and `jump_releases` of
`[assume]`, and on each side of a `stop_calls` pair (`stop_fields` and
`short_locks` name fields and locks), and a `name@path` that matches no function
is an error (exit 2) like a bare name that does.

`[assume]` says what the project knows of its own functions and cchecker cannot
see in the C, as `CC_ASSUME_SHORT` and `CC_STOP` do on a declaration. `short`
names the functions that count as fine for `CC_SHORT`: the short rule does not
walk into them (a helper that runs a request inline only on the loop thread and
queues it otherwise, a read of a descriptor that never blocks); the other rules
still do. `stop` names the functions that no rule walks into, and whose calls
count for none of them (a trace call behind a runtime flag): the effect rules,
the system calls under a `CC_NO_SYSCALL_UNDER` lock, the lock levels, and the
inference of jumps through the calls. Either holds for every root, inferred
roots included, and for every path of `--all-paths`; the ownership rules and the
rule on values of the collector, which read one function at a time, do not
change.

An assumption cuts the walk into the function, not the function itself: a root
that is assumed short or stopped still has its own body checked, as a caller
does not walk into it. What the function calls is not walked either, a callback
passed to it as a function pointer included. A function that blocks itself
(`CC_BLOCKING`) cannot be assumed short: its mark wins. `CC_STOP` wins over
every other mark, `CC_BLOCKING` included. A name is that of the function (a
static function of that name in any file, as in `[roots]`), and a name that no
function of the compile database declares is an error (exit 2) that names its
key (`trace (assume.stop)`), checked as those of `[roots]` are.

`may_jump` names the functions that may jump out of their caller (they return,
or call `longjmp` on an error), as `CC_MAY_JUMP` does on a declaration: a call
of one is a way out of the caller, where the ownership rules and the lock rules
check what the path still owns or holds ([Ownership](ownership.md),
[Locks](rules.md#locks-on-every-path)). The other rules do not change. Only a
direct call can jump: a call through a function pointer never does, whatever
function it reaches. A function that is both `stop` and `may_jump` is both: no
walk goes into it, and a call of it is still a way out of its caller, as `stop`
is about what the function calls and `may_jump` about the path of the caller. A
name that no function of the compile database declares is an error (exit 2), as
for `short` and `stop` (`raise_type_error (assume.may_jump)`). A function that
calls one may jump out too, and its callers in turn, unless it catches the jump
(`catches` below, `may_jump_callers` above), where a call cut by `stop_calls` is
no call.

`jumps` names the functions that always jump out of their caller and never
return (an interpreter's raise, which calls `longjmp`), as `CC_JUMPS` does on a
declaration: a call of one is a way out of the caller, as for `may_jump`, and
the path ends there, as at a call that never returns. Such a function is an
error exit for the walk of the effect rules, as a `_Noreturn` one is. A function
that calls one may jump out too, as for `may_jump`. A name that no function of
the compile database declares is an error (exit 2) (`raise_error
(assume.jumps)`).

`catches` names the functions that catch the jumps of the functions they call,
as `CC_CATCHES` does on a declaration: a function that calls one that may jump
out may jump out too, and the inference stops at a function that catches
([Locks](rules.md#locks-on-every-path)). A function that calls `setjmp` or
`sigsetjmp` catches without a mark. A name that no function of the compile
database declares is an error (exit 2) (`run_protected (assume.catches)`).

`jump_releases` names the lock helpers (`CC_ACQUIRES`, `CC_RELEASES`) that
record their lock for the code that catches a jump, which gives it back, as
`CC_JUMP_RELEASES` does on a declaration: a lock that a function takes and
releases only through such helpers is no lock finding at a jump, and is still
checked on every return ([Locks](rules.md#locks-on-every-path)). A function
that takes or releases no lock for its caller is accepted and changes nothing. A
name that no function of the compile database declares is an error (exit 2)
(`take_recorded (assume.jump_releases)`).

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

`stop_fields` names the function-pointer fields that no walk follows, by struct
and field (`request.call` for the field `call` of `struct request`, also when
the code names it by a typedef such as `request_t`; for an anonymous struct, the
name of its typedef, or of the record it is declared in): a call through the
field reaches none of the functions stored in it, for every rule and every root,
`--all-paths` included. Use it for a field that holds many kinds of work (one
`call` slot of every request), whose functions every root would otherwise reach.
Only a call through the field itself is cut: one through a local that got its
value (`fn f = r->call; f(x)`) is still followed, and a store into the field
still counts when cchecker infers the roots. A field that the compile database
neither stores a function in nor calls through is an error (exit 2).

`stop_calls` cuts the calls between two functions: each entry is
`caller>callee`, and no walk follows a direct call of `callee` in `caller` (all
of its call sites there), while the other callers of `callee` still reach it
(`stop` removes the function for all of them). Either side may be a `name@path`
(`on_exit@proc.c>close_handles`). Use it for an edge that cannot happen at run
time, such as the branch of a macro that the queue it tests never takes. The
call is out of the call graph, so the cut holds for every rule that walks it:
the effect rules (`CC_SHORT` and `CC_HOT`), the lock rules (the path to a system
call under a held lock, the lock levels and the order check), and the inference of `may_jump_callers` (a
function that calls a function that may jump out, and the chains in `path`).
The ownership rules read the body of each function, so the cut changes them
only through that inference. A call that a lock or ownership rule reads in the
body it checks (the call made under the lock, a call that may jump) is not
cut itself: cut the edge below it. If `callee` is still reachable from `caller`
through another function, that path is followed. A pair that matches no call of
the compile database is an error (exit 2), like an unknown name; a value that
is not `caller>callee` (`a->b`, `a>b>c`, `a > b`) is an error at load.

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
each with `call`, `argument` (its place, from 0; -1 for a function stored in
`exit_cb`, where `call` is `uv_process_options_t.exit_cb`), `file` and `line`
(absolute for a call outside the working directory, such as a body that
includes a file from outside), and a run without `--json` says how many in one
line on standard error, so a root is never lost without a word.

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
