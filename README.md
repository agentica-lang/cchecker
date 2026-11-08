# cchecker

Checks C code for the rules of a project and runs the usual analyzers in one command. It runs `gcc -fanalyzer`,
`clang-tidy` and its own rules on each file, in parallel, and prints what they find in one format with stable codes. A
baseline file accepts the findings a project has today, so CI fails only on new ones. It is written in
[Agentica](https://github.com/agentica-lang/agentica).

The rules read clang's JSON AST and the annotations of `include/cchecker.h`. This version checks effects on the call
graph (a `CC_SHORT` function never reaches a blocking call, and a `CC_HOT` function never allocates or makes a system
call) and locks on every path of a function: a lock taken is released, a lock released is held, no system call runs
under a lock marked `CC_NO_SYSCALL_UNDER`, locks are taken in the order of their `CC_LOCK_LEVEL`, and the set of a
`CC_PAIR` is restored. It also checks ownership on every path: a pointer marked `CC_OWNS` is freed or handed on, not
freed twice and not used after; and a value of the collector (`CC_GC`, `CC_GC_ALLOC`) is never stored in memory from
`malloc` or in a static. The plan is in [issue 1](https://github.com/agentica-lang/cchecker/issues/1).

## Install

cchecker needs Agentica 0.26.1 or later, and `gcc` 10 or later, `clang` and `clang-tidy` on PATH, and `sh`. The scan
of clang's AST is a small native module in C (`native/`), which the first run (or `agentica compile`) builds with the
system C compiler (`cc`); a module that cannot be built or loaded is a tool error. Clone the repository and run it with
`agentica`, or compile it to bytecode:

```sh
agentica cchecker.agc [options] FILE... -- COMPILER-FLAGS...
agentica compile cchecker.agc -o cchecker.agcb      # then: agentica run -- cchecker.agcb [options]
```

## Use

With a compile database (`compile_commands.json`, from CMake, `bear` or `clang -MJ`), run it from the root of the
project:

```sh
agentica cchecker.agc -p build                     # a file or the folder that holds compile_commands.json
agentica cchecker.agc -p build --baseline cchecker-baseline.json
```

Or name the files and give the flags after `--`:

```sh
agentica cchecker.agc src/a.c src/b.c -- -Iinclude -DNDEBUG
```

A finding is one line, `file:line:column CODE message`, and the last line is a summary:

```text
src/a.c:9:12 CC-GCC-ANALYZER-MALLOC-LEAK leak of 'buf'
src/a.c:9:12 CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC Potential leak of memory pointed to by 'buf'
cchecker: 2 new findings in 1 file
```

`--json` prints one object for tools and agents: `clean`, `findings` (each has `code`, `tool`, `file`, `line`,
`column`, `message`, `path`, the call path of a finding of the rules, `source`, the `[library]` flag that made it or
`""`, and `root`, where an inferred root comes from or `""`), `baselined`, `fixed`, `errors` (a tool that did not run
or could not compile a file: `tool`, `file` and `message`), `skipped`, `suppressed` (below), `config`, the settings
file that was read or `"defaults"` (Settings), `unresolved_callbacks` (Roots), and `unchecked_files`: the files that
were not checked because a header they include is not found (`file` and `missing`, the header as the `#include` wrote
it). Such a file is skipped with a warning on standard error and does not change the exit code.

Exit codes: `0` no new findings, `1` new findings, `2` a usage error or a tool error. A tool error is a tool that
is missing, ends in a timeout or exits with a non-zero code, except for the `1` of a compiler that found errors in the
file (a file that does not compile is an error, never a finding: gcc 14 refuses an implicit function declaration, for
example). gcc reports its analyzer only (`CC-GCC-ANALYZER-...`); the other warnings of the build flags (`-Wall`) are
not findings, as they are not for clang-tidy.

`-Werror` in the flags of a database does not turn the other warnings of gcc into tool errors: cchecker adds
`-Wno-error` after the flags, and `-Werror=analyzer-...` stays an error, which is a finding. A gcc that exits with `1`
after analyzer errors counts as a finding only when it ends with `cc1: some warnings being treated as errors`; a `cc1`
killed halfway prints `gcc: fatal error: Killed signal terminated program cc1`, and that is a tool error.

Only the C files of a database are run (a `.cc` or `.S` entry is ignored, and a run that ignored one is not a full run:
it keeps the baseline entries of everything it did not name). The paths are relative to the working directory: a file
outside it is skipped (a line on standard error and `skipped` in `--json`), and a finding in a header outside it (a
system or third-party header) is dropped.

### Codes

A code is stable: a baseline holds it. `CC-GCC-` is followed by the gcc warning option in capitals
(`-Wanalyzer-malloc-leak` is `CC-GCC-ANALYZER-MALLOC-LEAK`, also when `-Werror` made it
`-Werror=analyzer-malloc-leak`), and `CC-TIDY-` by the clang-tidy check (`clang-analyzer-unix.Malloc` is
`CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC`). A diagnostic without a name is `CC-GCC-WARNING` or `CC-TIDY-WARNING`. The
rules have `CC-EFFECT-`, `CC-PATH-` and `CC-OWN-` codes (below).

### Baseline

```sh
agentica cchecker.agc -p build --baseline cchecker-baseline.json --update-baseline   # writes the file, exit 0
agentica cchecker.agc -p build --baseline cchecker-baseline.json                     # fails on new findings only
```

A finding matches the baseline by its code, its file and its message, never its line, so edits above it do not break
the baseline. The file holds a count for each kind, so a second finding of a kind the baseline holds once is new. The
file is read before any tool runs, and written in one rename.

A run covers the tools and the files whose job ended well. Only a full run, which is every file of a database with no
`--exclude`, no FILE subset, no skipped file and no failed job, covers the headers and the files that left the
database. `fixed` counts the accepted findings of that scope that no tool found this time, and `--update-baseline`
replaces the entries of that scope and keeps the others, so `--tools gcc` or a subset of FILEs updates only what it
ran. A header that the run did not name keeps the larger count of its entry, as other flags can show other findings in
it (`#ifdef`); only a full run lowers it. It refuses to write, and leaves the file as it was, when a tool failed, when
the database has a file that was skipped (outside the working directory), with `--checks` (a baseline made with
other checks would lose the findings of the default ones), and, when the rules run, with `--no-infer` or a `[library]`
flag set to false (Settings), for the same reason. The exit code is `2` in each case.

### Suppressions

A finding that is a false positive, where the check cannot be made smarter, is suppressed next to the code, with the
reason. A comment that trails code holds for the findings of its line; a comment alone on its line holds for its line
and the line below it. Only a comment that starts with `cchecker: ignore` counts (not a string or a comment that
mentions it). It takes one or more codes, each of a tool (`CC-GCC-`, `CC-TIDY-`, `CC-EFFECT-`, `CC-PATH-` or
`CC-OWN-`), and a code that ends with `*` is a prefix:

```c
/* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: conn_free frees it through the struct */
p = malloc(n);
q = malloc(n); // cchecker: ignore CC-GCC-ANALYZER-*, CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC: same as above
```

A finding of the rules belongs to a function: `CC_IGNORE("CC-EFFECT-SHORT-BLOCKS", "reason")` on any declaration of
the function suppresses it (see Annotations). A suppression without a code or a reason, or with a code of no tool, is
a usage error (exit 2). When two suppressions hold for a finding, the reason of the nearer one is shown, and both count
as used.
`--json` lists the suppressed findings under `suppressed`, each with its `reason`, and the summary line counts them. A
suppression that matches no finding is a finding, `CC-UNUSED-IGNORE`, at the comment or the function, once the run
covered every tool of its codes on that file, as the baseline does (for the rules, a full run of a compile database):
a stale one shows when the code changes or a check gets better. Suppressions apply before the baseline, so a
suppressed finding never goes into it, and neither does a `CC-UNUSED-IGNORE`: the fix is to edit or remove the comment.

### Options

| Option | |
|---|---|
| `-p, --compile-commands PATH` | the compile database: a file or its folder (default: `compile_commands.json` here) |
| `-t, --tools LIST` | `gcc`, `clang-tidy` and `rules`, comma separated (default all three) |
| `--checks LIST` | the clang-tidy checks, after those of a `.clang-tidy` file; default below |
| `-j, --jobs N` | tool runs at once (default: the number of cores) |
| `--timeout SECONDS` | for one tool on one file (default 300); a timeout is a tool error |
| `-b, --baseline FILE`, `--update-baseline` | see above |
| `--exclude LIST` | files or folders to skip, comma separated (`src/vendor`, `./gen/a.c`): whole path parts |
| `--gcc PROGRAM`, `--clang-tidy PROGRAM` | the programs to run, for a versioned name such as `gcc-14` |
| `--clang PROGRAM` | the clang that dumps the AST for the rules |
| `--json` | one JSON object |
| `-c, --config FILE` | the settings file (Settings) |
| `--no-infer` | no roots inferred from the callbacks of libuv (Roots) |
| `--all-paths` | a finding of the rules for each bad call that a root reaches, not only the nearest (Rules) |

The default checks are `-*`, `clang-analyzer-core.*`, `clang-analyzer-unix.*` and `clang-analyzer-security.*` (without
`insecureAPI`), and the bugprone checks `sizeof-expression`, `integer-division`, `suspicious-memory-comparison`,
`signed-char-misuse`, `misplaced-widening-cast` and `unused-return-value`. The tools run with `LC_ALL=C`, so the
messages are in English on any machine.

A timeout stops the tool and everything it started (gcc runs `cc1` as a child) when `timeout` of coreutils is
installed, and kills what ignores the signal two seconds later. Without it (macOS has none) only the tool itself is
stopped. The limit: Agentica cannot yet start a child in its own process group, so Ctrl-C on cchecker does not stop the
tools that are running (they end by themselves or at the timeout); see
[agentica#1204](https://github.com/agentica-lang/agentica/issues/1204).

## Annotations

`include/cchecker.h` defines the macros that the rules read: `CC_SHORT`, `CC_BLOCKING`, `CC_HOT`, `CC_ACQUIRES(lock)`,
`CC_RELEASES(lock)`, `CC_NORETURN`, `CC_NO_SYSCALL_UNDER(lock)`, `CC_LOCK_LEVEL(n)`, `CC_PAIR(set, restore)`,
`CC_OWNS`, `CC_FREES`, `CC_GC`, `CC_GC_ALLOC` and `CC_IGNORE("CODE", "reason")` (a suppression). With clang each is
`__attribute__((annotate("cchecker:...")))`; with any other compiler it is empty. When cchecker dumps the AST it
defines `CCHECKER_AST`, and the macros become `deprecated("cchecker:...")`: the JSON AST of clang 19 drops the text of
`annotate` and keeps the message of `deprecated`. The dump runs with `-w`, so this gives no warning.

```c
#include "cchecker.h"

CC_SHORT int next_id(void);
void adopt(CC_OWNS char *name);
CC_PAIR(mask_signals, restore_signals) int guarded(void);
```

An annotation may be on any declaration of the function: a prototype in a header holds for the definition.

## Settings

cchecker reads its settings from the first of these that it finds:

1. The file of `-c FILE` (`--config FILE`). When it has a `[tool.cchecker]` table (an `agentica.toml` or another
   manifest), that table; else the whole file. A file that is not there or cannot be read is an error (exit 2).
2. `cchecker.toml` in the working directory, the project folder.
3. The `[tool.cchecker]` table of `agentica.toml` in the project folder. An `agentica.toml` without it is skipped.
4. The defaults: every `[library]` flag on, no `[roots]`, `follow_cold = false`.

The first one wins, and the others are not read. `--json` says which in `config` (`"cchecker.toml"`, the path given to
`-c`, or `"defaults"`), and a run without `--json` says it in one line on standard error. A key that is not one of
those below, or a value of the wrong type, is an error (exit 2), so a typo cannot turn a check off.

```toml
[library]
libc_blocking = true
pthread_blocking = true
libuv_blocking = true
libgc_blocking = true
libuv_callbacks_short = true
libgc_alloc = true

[roots]
short = ["io_poll", "on_timer"]
hot = ["dispatch"]

[effects]
follow_cold = false
```

`[library]` turns each family of library knowledge on or off. All are on by default. A finding of the rules says in
`source` of `--json` the flags that made it, so a project knows which one to turn off: the family of the blocking call
it reaches (`libc_blocking`), and for an inferred root the inference before it (`libuv_callbacks_short+libc_blocking`).
`source` is not part of the baseline key. The lists are in `src/known.agc`.

| Flag | What it adds |
|---|---|
| `libc_blocking` | the calls of libc and POSIX that wait, to the blocking calls of `CC_SHORT`: files and streams (`read`, `write`, `open`, `fopen`, `fread`, `printf`, `fflush`, `fsync`, ...), sockets (`accept`, `connect`, `recv`, `send`, `getaddrinfo`, ...), waiting (`poll`, `select`, `epoll_wait`, `sleep`, `nanosleep`, `wait`, `waitpid`, `sigwait`, ...), processes (`system`, `popen`), `dlopen`, `dlsym`, POSIX semaphores and message queues, and the C11 threads (`thrd_join`, `mtx_lock`, `cnd_wait`, `call_once`, ...) |
| `pthread_blocking` | `pthread_join`, `pthread_timedjoin_np`, the locks of `pthread_mutex_`, `pthread_rwlock_` and `pthread_spin_lock`, the waits of `pthread_cond_`, `pthread_barrier_wait` and `pthread_once` |
| `libuv_blocking` | `uv_run`, `uv_sleep`, `uv_thread_join`, the locks and waits of `uv_mutex_`, `uv_rwlock_`, `uv_cond_`, `uv_sem_`, `uv_barrier_wait`, `uv_once`, and the `uv_fs_*` calls whose libc call blocks (`uv_fs_open`, `uv_fs_read`, `uv_fs_write`, `uv_fs_fsync`, `uv_fs_fdatasync`, `uv_fs_copyfile`, `uv_fs_sendfile`, `uv_fs_mkstemp`, `uv_fs_realpath`) when their callback, the last argument, is `NULL` or 0 |
| `libgc_blocking` | `GC_gcollect` of the Boehm collector, which stops the world |
| `libuv_callbacks_short` | a `CC_SHORT` root for each function passed as a callback that libuv runs on the loop thread: the `cb` of `uv_timer_start` (argument 1, from 0), `uv_poll_start` (2), `uv_async_init` (2) and `uv_close` (1), the `alloc_cb` and `read_cb` of `uv_read_start` (1 and 2), the callback of `uv_write` (4), `uv_write2` (5), `uv_shutdown` (2), `uv_tcp_connect` (3), `uv_pipe_connect` (3) and `uv_pipe_connect2` (5), and the `after_work_cb` of `uv_queue_work` (3), never its `work_cb`, which runs on the pool (Roots) |
| `libgc_alloc` | the allocators of the Boehm collector (`GC_malloc`, `GC_malloc_atomic`, `GC_realloc`, `GC_strdup`, their `GC_debug_` forms, ...) to the allocators of `CC_GC_ALLOC`, in the rule on values of the collector (`source` `libgc_alloc`) |

A blocking flag changes only the blocking calls of `CC_SHORT`: the rules of `CC_HOT` and of `CC_NO_SYSCALL_UNDER`
count every known blocking call as a system call whatever the flags.

`[effects]` holds how the effect rules walk the project's own functions, so it is not a `[library]` flag, which is a
fact of a library. `follow_cold = true` makes the walk go into a function that never returns or is cold (below in
Rules); by default it does not.

`[roots]` names the functions that are `CC_SHORT` (`short`) or `CC_HOT` (`hot`) without a mark in the C, by their name
(a static function of that name in any file). A finding of a root of `[roots]` is the same as that of the mark, and a
function both marked and listed is one root. A name that no function of the compile database defines is an error
(exit 2), so a rename cannot leave a rule that checks nothing. Only a full run of a compile database can tell (a run of
some files does not see the others), so only it checks the names; another run says on standard error that it did not.

### Roots

A rule starts from its roots, which come from three places. A project leans on them in this order, and adds the next
one only for what the one before does not cover:

1. Inferred roots: a function passed as a callback to a libuv call that runs it on the loop thread is a `CC_SHORT`
   root (`libuv_callbacks_short` above), as it runs on the event loop. `--no-infer` or the flag set to false turns it
   off.
2. `[roots]` in the settings, which keeps the C as it is.
3. The marks of `cchecker.h` in the C (Annotations), for what neither covers.

A function that is a root in more than one way is one root. The callback of an inferred root is a function named in
the call, or a pointer that the rules follow to the functions stored in it (see Rules), such as a parameter that
callers pass a function to. `NULL` or 0 is no callback. A callback that leads to no function (the return value of a
call, a parameter that no caller passes a function to) is listed in `unresolved_callbacks` of `--json`, each with
`call`, `argument` (its place, from 0), `file` and `line` (absolute for a call outside the working directory, such as
a body that includes a file from outside), and a run without `--json` says how many in one line on standard error, so
a root is never lost without a word.

A finding of an inferred root has its place in `root` of `--json` (`callback of uv_read_start at src/net.c:41`), and
the printed line ends with it:

```text
src/net.c:12:13 CC-EFFECT-SHORT-BLOCKS short function on_read reaches the blocking call write: on_read -> write (root: callback of uv_read_start at src/net.c:41)
```

The root is not part of the message, as the path is not: the baseline matches the message, and a root that named the
line of its call would make a finding new each time the code above that call moves. A finding of a marked or listed
root has no `root` and does not name `libuv_callbacks_short`, as the flag would not turn it off.

## Rules

The `rules` tool runs `clang -Xclang -ast-dump=json -fsyntax-only` on each file with its flags, keeps the declarations
written in the files under the working directory (for a declaration that a macro writes, where the macro is used), and
builds one call graph from all the files of the run. A static function is another function in each file. A rule walks
the graph from each annotated function that the project defines, and its finding is at that function. The message
names the call that breaks the rule; the printed line and `path` add the shortest call path to it:

```text
src/ids.c:7:14 CC-EFFECT-SHORT-BLOCKS short function next_id reaches the blocking call read: next_id -> helper -> read
```

The baseline matches the message, without the path, so a finding stays accepted when its path changes.

A root gives one finding per code, at the nearest bad call. With `--all-paths` it gives one for each distinct bad call
it reaches, each with its shortest path, so a project sees them all in one run. The message names the bad call by its
name, so each finding is keyed in the baseline by the name of its call (code, file and message: `short function serve
reaches the blocking call sleep`; two static functions of one name in two files share that key, and the baseline
counts them), and the nearest one is the finding a run without `--all-paths` gives, with the same key. A baseline
written with `--all-paths` holds the others too, so run CI the same way: a run without it counts them fixed. A bad
call is reached once, by its shortest path, and the walk does not go past it.

The walk does not go into a function that never returns or is cold: one declared `_Noreturn`, `[[noreturn]]`,
`CC_NORETURN` or `__attribute__((noreturn))` (in its type too, behind a typedef: `typedef void fatal_fn(const char *)
__attribute__((noreturn)); fatal_fn die;`), or `__attribute__((cold))`, on any of its declarations. Such a call is an
error exit (`out_of_memory`, `die`), not the path the rules are about. `[effects] follow_cold = true` follows it. A
`CC_BLOCKING` mark on such a function wins: it is a blocking call. The lock rules (`CC_NO_SYSCALL_UNDER`) follow every
call whatever it says.

| Code | |
|---|---|
| `CC-EFFECT-SHORT-BLOCKS` | a `CC_SHORT` function reaches a `CC_BLOCKING` function or a known blocking call |
| `CC-EFFECT-HOT-ALLOCATES` | a `CC_HOT` function reaches a call that allocates or frees heap memory |
| `CC-EFFECT-HOT-SYSCALL` | a `CC_HOT` function reaches a system call; a blocking call is one too |

The known calls are those of libc, pthread, libuv, OpenSSL and the Boehm collector that block (`read`, `sleep`,
`pthread_mutex_lock`, `uv_run`, a `uv_fs_*` call such as `uv_fs_read` whose last argument, the callback, is `NULL` or
0, as it then runs at once), allocate (`malloc`, `free`, `strdup`, `GC_malloc`, `SSL_new`) or enter the kernel
(`write`, `mmap`, `close`); an unlock or the signal of a condition counts as a system call, as it wakes a waiter with a
futex call. A `uv_fs_*` call run at once whose libc call does not block (`uv_fs_close`, `uv_fs_stat`, `uv_fs_unlink`,
`uv_fs_mkdir`, ...) is a system call and not a blocking one, as `close` is. The lists are in `src/known.agc`. A
function the project defines is judged by its body; a library function that is not listed has no effect. A known name
is known by name alone: a project function named `remove`, `rewind`, `ftell` or `dlsym` counts as the libc one in a run
that does not read its body.

A call through a function pointer reaches every function the project stores in the same place: a field of a struct or a
union (by record and field name, in an initializer or an assignment), a variable, or a parameter of a function (from
the direct calls that pass a function), and every function of a place copied into it (`box.handle = handle`). An item
of an initializer of a struct or an array counts designated or not (`{[3] = f}`). A cast is seen through, so a function
kept in a `void *` or an `uintptr_t` is reached by a call through it, but not one kept in a table whose first item is a
literal number (`uintptr_t t[] = {0, (uintptr_t)f}`): that is a table of numbers (below). A variable with
`__attribute__((cleanup(f)))` calls `f`. A pointer that comes from anywhere else reaches nothing: a return value, the
arguments of a variadic function, and a function handed to a library that calls it back (`qsort`; a libuv callback is a
root of its own, see Roots). A walk goes only through what the run read, so run it on all the files of the project:
with a subset of the files, a call into a file that was not run reaches nothing. For the baseline, only a full run of a
compile database covers the findings of the rules: a run of some files never counts them fixed and never drops them on
`--update-baseline`.

### Locks on every path

The rules build a control flow graph of each function that takes or releases a lock, and follow every path through
it: `if`, `switch` with its fallthrough and without a `default`, loops with `break` and `continue`, `goto` (a computed
one may go to any label), `return`, `&&`, `||`, `?:`, `x ?: y` and statement expressions. A path ends at a `return`,
at the end of the body, or at a call that never comes back (`abort`, a `_Noreturn` or `noreturn` function, through a
typedef or a function pointer too, or one marked `CC_NORETURN`, such as a function that jumps out with `longjmp`); a
lock held there is not a finding. The cleanup
function of a variable with `__attribute__((cleanup(f)))` runs on every way out of its block.

| Code | |
|---|---|
| `CC-PATH-LOCK-NOT-RELEASED` | a path returns with a lock that the function took |
| `CC-PATH-LOCK-NOT-HELD` | a path releases a lock that the function did not take |

The finding is at the function, once for each code and lock, and `path` is a shortest path that breaks the rule, from
the last call that took the lock (or released it, for `NOT-HELD`) to the end: `7:7 true` is the condition at line 7,
column 7, taken as true.

```text
src/queue.c:5:5 CC-PATH-LOCK-NOT-RELEASED pop does not release q->mu on every path: 6:3 takes q->mu -> 7:7 true -> 8:5 returns
```

A lock is the expression the call names, by its field path: `&q->mu`, `q->mu` and `(&q->mu)` are one lock, and `&a->mu`
and `&b->mu` are two. A local variable that is set once, where it is declared, stands for its value (`pthread_mutex_t
*m = &q->mu`). The known calls take or release the lock of their first argument: the mutexes, spin locks and read-write
locks of pthread, C11 and libuv, and the critical sections and SRW locks of Windows (`src/known.agc`). A call that may
fail to take its lock (`pthread_mutex_trylock`, and `pthread_mutex_lock`, which returns an error code) takes it when it
is a condition compared with 0, on the side where it gave 0: `if (pthread_mutex_trylock(&q->mu) != 0) return;`. A wait
on a condition (`pthread_cond_wait(&cv, &q->mu)`) gives the lock back before it returns, so it changes nothing.

A path does not go where a condition that the function tests twice would have to be true and false, so `if (locked)
lock(); ...; if (locked) unlock();` passes; a write to a variable of the condition, or a call given its address
(`f(&locked)`), forgets its value; a call given `&q->mu` does not change `q`. A function whose paths would take more
than 200 000 states to follow is walked again without these conditions; when that is not enough either, its findings
are those of the paths followed, and the run counts it in `incomplete_functions` of `--json` and says so on standard
error (the exit code does not change). A function whose AST has more than 20 000 nodes (about four times the largest
of the Agentica VM) gets no graph: that is an error of the `rules` tool on its file, so the exit code is 2, and the
rest of the run is checked.

A function that takes a lock for its caller, or releases the caller's lock, says so on its prototype:
`CC_ACQUIRES(lock)` or `CC_RELEASES(lock)`, with the lock written in the names of its parameters (or a global). A call
then takes or releases that lock in the words of the call: for `CC_ACQUIRES(q->mu) void queue_lock(struct queue *q)`,
`queue_lock(vm->q)` takes `vm->q->mu`. Such a function is a lock helper: its own body is trusted (a count of nested
takes, a spin before the wait), and its callers are checked. Without an annotation, a function that takes a lock and
returns with it is a finding, so a forgotten unlock never passes for a helper. Put the annotation on the prototype that
the callers include: a caller sees the declarations of its own file. A function that takes or releases a lock only on
some of its returns (`false` when it dropped the lock) is beyond these rules: suppress its findings with `CC_IGNORE`,
with the reason. A call through a function pointer does nothing to the locks.

Limits: a lock is counted by its text, so a lock taken in a loop over several objects (`lock(&a[i]->mu)`), locks
taken hand over hand, or a pointer that is set again between the lock and the unlock (`q = q->next`) can give false
findings; the result of a lock stored before the test (`r = trylock(&q->mu); if (r == 0)`) takes nothing; a global
that a called function changes keeps the value the path knew.

### What runs while a lock is held

A lock held for short sections only, which other threads spin for, is marked on its field (or on a global lock):
`CC_NO_SYSCALL_UNDER()`. While a path holds it, no call is a system call or a blocking call (the lists of the effects,
a lock or an unlock of another lock included, and a `CC_BLOCKING` function) or reaches one through the functions of
the project, a call through a function pointer included (the functions stored in it), except the release of the lock
itself and a wait on a condition with it. `CC_NO_SYSCALL_UNDER(lock)` on a function says the same
of one lock of that function, in the names of its parameters.

`CC_LOCK_LEVEL(n)` on the field of a lock (or a global lock) orders the locks: a path takes a lock with a level only
while every lock it holds with a level has a lower one, and it calls a function that takes one (in its body or in the
functions it reaches, or those stored in a pointer it calls) only then. Two locks of the same level are never held
together. A trylock (`pthread_mutex_trylock`) never waits, so it is never out of order. One exception: a called
function that takes the class of a lock held again is not out of order, for a lock that counts its takes by the same
thread; the rules cannot tell it from another lock of the same class.

```c
struct runtime { CC_LOCK_LEVEL(1) pthread_mutex_t sync; ... };
struct runq { CC_NO_SYSCALL_UNDER() CC_LOCK_LEVEL(3) pthread_mutex_t lock; ... };
```

| Code | |
|---|---|
| `CC-PATH-SYSCALL-UNDER-LOCK` | a call under a `CC_NO_SYSCALL_UNDER` lock is or reaches a system call |
| `CC-PATH-LOCK-ORDER` | a lock with a level is taken (or a function that takes one is called) under one of the same or a higher level |

A field is known by its struct and its name (`runq.lock`, the name of a typedef for an anonymous struct; an item of
an array of locks is its field), and a global by its name (`name@file` for a static one; a parameter or a local of the
same name is not it). The marks are `CC_NO_SYSCALL_UNDER()` with nothing in it and `CC_LOCK_LEVEL(n)` with a decimal
number; another form, or a mark on a field of a struct with no name, is an error of the `rules` tool (exit code 2). A
lock is known by its text in a function, so the same lock written two ways (`&q->mu` and `m` set later to it) is two
locks. A lock of a `CC_ACQUIRES` is followed to its field through the types of the parameters
(`CC_ACQUIRES(s->pool->mu)` on `void pool_lock(struct server *s)` takes `pool.mu`). The path of a finding goes from
the take of the lock held to the call, and the call path to the system call when there is one: `13:3 calls bump: bump
-> pthread_mutex_lock`.

### Pairs of calls

`CC_PAIR(set, restore)` on a function says that in its body, a call of `set` is followed by a call of `restore` on
every path that returns, as a lock is by its unlock (the same graph and the same walk). On a declaration of `set`
itself it says so in every function that calls `set`. The two are functions, by name, whatever their arguments: a
cleanup function counts as a call. A `restore` with no `set` before it on the path does nothing, so restoring twice is
no finding; a `set` twice needs two restores. `set` and `restore` are two functions (a pair of one function, such as
`umask`, never gives a finding). The body of a `set` that carries its own `CC_PAIR` is how the pair works (a
wrapper of `GC_disable`), so it may leave another pair set for its caller.

```c
CC_PAIR(mask_signals, restore_signals) void mask_signals(sigset_t *old);   /* in every caller */
CC_PAIR(gc_pause, gc_resume) int copy_out(struct heap *h);                  /* in copy_out */
```

| Code | |
|---|---|
| `CC-PATH-PAIR-NOT-RESTORED` | a path returns after a call of `set` and no call of `restore` after it |

The path goes from the call of `set` to the return: `7:3 calls mask_signals -> 8:7 true -> 9:5 returns`.

Two pairs on one `set` are two pairs (both restores are needed), and one `restore` of two sets restores both; the
same pair written twice counts once. A pair holds in the files that see its declaration, as the lock annotations do.
A `CC_PAIR` that names a function the file does not declare does nothing. A `set` that can fail (and so needs no
`restore` when it failed) is beyond the rule, as a trylock helper is: suppress the finding with `CC_IGNORE`. When the
restore happens in a function that the code calls (`finish(ctx)` calls `restore_signals`), name that function:
`CC_PAIR(mask_signals, finish)`.

### Ownership on every path

`CC_OWNS` says that a place owns the memory its pointer points to, which is freed once, with `free` or with a
function of the project marked `CC_FREES`:

```c
CC_OWNS char *read_name(int fd);            /* returns a pointer that the caller owns */
void adopt(CC_OWNS char *name);             /* takes what the caller passes */
void conn_free(CC_FREES struct conn *c);    /* frees what the caller passes */
struct conn { CC_OWNS char *buf; };         /* a store into the field hands the pointer on */

int load(int n) {
  CC_OWNS char *buf = malloc(n);            /* the local owns its value */
```

The rules follow every path of a function that has a pointer that owns, with the graph and the walk of the locks and
their limits (a function with too many paths counts in `incomplete_functions`, once for each walk). A parameter marked
`CC_OWNS` or `CC_FREES` owns from the entry, a local marked `CC_OWNS` owns the value it gets (other than `NULL`), and a
local that gets the value of a `CC_OWNS` function owns it without a mark. On every path that returns, each one is freed
or handed on: returned, stored in a `CC_OWNS` field (or an item of one, `q->items[i] = p`, or a `CC_OWNS` global), or
passed to a `CC_OWNS` parameter. Stored anywhere else or passed to another parameter, it is lent and still owns. A
condition that tells that a pointer is null (`if (!p)`, `if ((p = malloc(n)) == NULL)`) leaves it owning nothing on
that side.

A local without a mark that gets a pointer that owns (`char *c = p`) stands for it: freeing `c` frees `p`; a `malloc`
into it later owns nothing, as in any local without a mark. A local marked `CC_OWNS` that gets one takes it over, and
`p` owns no more. Each side of `?:` gives its own value (`p = n ? make(n) : NULL` owns where `n` is true, `p = q ?:
make(n)` where `q` is null), and a statement expression gives the value of its last expression (`({ char *q = make(n);
...; q; })`). In a `CC_FREES` parameter that points to the pointer (`release(CC_FREES char **p)`, a cleanup function),
`*p` is the pointer: `free(*p)` frees it, `if (*p)` tests it, `*p = NULL` sets it to null, and `*p = v` gives the
caller a value that the function does not own: a pointer that owns is handed on there, and a local that stood for the
old value (`old = *p`) owns it. `t = realloc(p, n)` moves `p` to `t`, and `p` owns again where `t` is null; `p =
realloc(p, n)` keeps `p` owning. A pointer lent to be set (`fill(&p)`) owns what the call left in it, which the rules
do not know: no finding says it leaks. The marks of the parameters of a prototype hold in the definition and in every
caller that includes it.

| Code | |
|---|---|
| `CC-OWN-LEAK` | a path returns, or gives a pointer a new value, while it still owns; or drops the value of a `CC_OWNS` function (kept nowhere: not in a local, a `CC_OWNS` place, a return or a parameter that takes it) |
| `CC-OWN-DOUBLE-FREE` | a path frees a pointer that it already freed or handed on |
| `CC-OWN-USE-AFTER-FREE` | a path reads, returns or hands on a pointer after it freed it or handed it on |

The finding is at the function, once for each code and pointer, and `path` goes from where the pointer got its value
(or from the free) to the step that breaks the rule:

```text
src/load.c:6:5 CC-OWN-LEAK load does not free or hand on buf on every path: 9:21 buf = malloc -> 10:8 true -> 12:7 true -> 13:5 returns
```

A `malloc` into a local without a mark is not checked: `gcc -fanalyzer` reports those leaks, and the mark makes the
contract part of the code. The rules do not follow a pointer into a struct or an array (a store into a `CC_OWNS` field
is where they stop), through a function pointer, or out through a parameter (`int open_buf(char **out)`: the caller
lends `&p` to be set). Two locals of the same name in one function are one pointer. A local that stands for a pointer
still stands for it after that pointer gets a new value, except through a `CC_FREES` parameter that points to the
pointer: after `old = *p; *p = v;`, `old` holds the old value. `return p` hands `p` on even when the function has no
`CC_OWNS` mark, and `p = realloc(p, n)` is trusted to work. A pointer put in a struct or a compound literal is not
followed, and only one level of pointer is (`*p` of a `char **p`, not `**p`). A pointer freed through its address
(`free_and_null(&p)`, a cleanup function) is freed or null: it may be read and freed again (`free(NULL)`), and where a
condition says it is not null it is freed. The rules assume that a helper that frees through `&p` sets the pointer to
null; one that only frees leaves a later double free or use unreported.

### Values of the collector

A collector frees what no pointer that it sees points to. It scans its own heap and its roots (the stacks, and the
statics for some), never memory from `malloc`: a pointer kept there, or in a static that it does not scan, does not
keep the value alive. The rule keeps them out of both. `CC_GC` on a struct, a union or a typedef says that the
collector manages its values, and `CC_GC_ALLOC` on a function that it returns memory of the collector; the allocators
of the Boehm collector (`GC_malloc`, `GC_malloc_atomic`, `GC_realloc`, ...) are known (`[library]` `libgc_alloc`).

```c
struct CC_GC object { ... };                     /* a struct object, or a pointer to one */
typedef struct { uint64_t bits; } value CC_GC;   /* a value, or a pointer to one */
CC_GC_ALLOC void *gc_alloc(size_t size);         /* the memory it returns */
```

A value of the collector is a value of a marked type, a pointer to one, a struct that holds one (by value or by
pointer), the value of an allocator of the collector, or a local that got one of those; a cast does not hide it. The
rule reads each store of a function (`a[i] = v`, `p->f = v`, `*p = v`, `x = v`):

| Code | |
|---|---|
| `CC-OWN-GC-IN-MALLOC` | a value of the collector is stored in memory from `malloc`: what a pointer points to when it got the value of `malloc`, `calloc`, `realloc`, `strdup` or a `CC_OWNS` function, or is marked `CC_OWNS` (a local, a parameter, a field or a global) |
| `CC-OWN-GC-IN-STATIC` | a value of the collector is stored in a variable of static storage (a global, a static local, or a field or an item of one), or such a variable has a collector type |

The finding of a store is at the function, once for each code and target, with the store as its path:

```text
src/table.c:6:8 CC-OWN-GC-IN-MALLOC table stores a value of the collector in memory from malloc: items[i]: 9:5 stores gc_alloc in items[i]
```

A variable of static storage of a collector type is a finding at the variable (a global or a file static, at its
definition, not at an `extern`), and at the function for a static local. The rule does not follow the paths: a local
that got memory from `malloc` anywhere in the function points to it everywhere in it. Memory it cannot tell (a
parameter that is not marked, a field that is not `CC_OWNS`) is not reported, nor is a copy that is no store
(`memcpy`, a value passed to a function that stores it), a store of `NULL` or `0`, or a constant static (`static const
value none`), which only ever holds its initializer. A typedef of a pointer (`typedef struct object *object_ref`) is
read through to the type it names.

The AST of a file is tens of MiB with its system headers, more than a process output holds in Agentica (1 MiB):
`sh` writes it to a file in a private folder under `$TMPDIR`, and cchecker reads it line by line and keeps
only the declarations of the project. A table of numbers is not kept: an array of a number or character type,
or whose first item is a number (`const uint8_t ROM[]`); a number cast to a pointer (`0`, `NULL`, or `1` under
`-Wno-int-conversion`) is not a number. A declaration of more than a million lines of the dump is left out: when it
names a function, before or past that cap, it is a tool error, and otherwise (a table of enum values or of structs
of numbers) it is counted in `skipped_declarations` of `--json` and in a line on standard error, while the rest
of the file is checked. A dump that ends early is a tool error. The folder is removed at the end of the run, and a
run removes the folders that killed runs left there: a folder of the same user, private, not a link, holding only
dumps, whose process is gone. Runs in different PID namespaces that share `$TMPDIR` can remove each other's folders.

## Development

The tests are Agentica too: BDD features in `specs/` that run cchecker on the C files of `specs/fixtures/`, and unit
tests in `test/`. They need `gcc`, `clang`, `clang-tidy` and `sh`.

```sh
make check       # agentica check
make fmt-check   # agentica fmt --check; `agentica fmt` fixes it
make test        # agentica test --jobs 4 without the @slow scenarios, from the root of the repository
make test-slow   # the @slow scenarios only (the bounds of specs/limits.feature, the property tests on many cases)
make deps        # agentica install: prop into deps/; make check, test and test-slow run it first
make native      # builds the native module once; make test and make test-slow run it first
make bench       # the rules on the C VM of Agentica: wall time and peak RSS (BENCH_JOBS=2 for -j 2)
```

A scenario tagged `@slow` runs a large generated input (`specs/limits.feature`: a chain of 1000 branches, a
declaration of 16 million lines of the dump, a function over the guard of nodes or of states) under a bound on memory
(`ulimit -v`) and on time. `make test` leaves them out; CI runs them in a job of their own on every pull request.

`specs/properties.feature` holds property tests, with the [prop](https://github.com/agentica-lang/packages) package
(`make deps` installs it into `deps/`; cchecker itself needs no package): a law of the rules is checked on generated C
files, and a failure shows the seed and the shrunk C file. `make test` runs a few cases and `make test-slow` many.
`CCHECKER_PROP_SEED=SEED agentica test --only "NAME" specs/properties.feature` runs the cases of a failure again.

`make bench` fetches Agentica at a pinned commit (`AGENTICA_BENCH_COMMIT`) into `.bench/`, with only the submodules
whose headers its VM reads, and runs `--tools rules` on the 84 files of `vm/`; it fails when a file is not checked. It
needs `git`, `make`, GNU time and the headers of libgc, OpenSSL and zlib (Debian: `libgc-dev libssl-dev zlib1g-dev
pkg-config`). On an 8-core machine it takes 10.3 s and 415 MB at -j 8, and 17.9 s and 411 MB at -j 2.

## License

Apache License 2.0. See [LICENSE](LICENSE).
