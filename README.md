# cchecker

Checks C code for the rules of a project and runs the usual analyzers in one command. It runs `gcc -fanalyzer`,
`clang-tidy` and its own rules on each file, in parallel, and prints what they find in one format with stable codes. A
baseline file accepts the findings a project has today, so CI fails only on new ones. It is written in
[Agentica](https://github.com/agentica-lang/agentica).

The rules read clang's JSON AST and the annotations of `include/cchecker.h`. This version checks effects on the call
graph: a `CC_SHORT` function never reaches a blocking call, and a `CC_HOT` function never allocates or makes a system
call. Locks and paired state on every path, and ownership, come in later phases; the plan is in [issue
1](https://github.com/agentica-lang/cchecker/issues/1).

## Install

cchecker needs Agentica 0.26.1 or later, and `gcc` 10 or later, `clang` and `clang-tidy` on PATH, and `sh`. Clone the
repository and run it with `agentica`, or compile it to bytecode:

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
file that was read or `"defaults"` (Settings), and `unresolved_callbacks` (Roots).

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
rules have `CC-EFFECT-` codes (below).

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
the database has a file that was skipped (outside the working directory), or with `--checks` (a baseline made with
other checks would lose the findings of the default ones). The exit code is `2` in each case.

### Suppressions

A finding that is a false positive, where the check cannot be made smarter, is suppressed next to the code, with the
reason. A comment that trails code holds for the findings of its line; a comment alone on its line holds for its line
and the line below it. Only a comment that starts with `cchecker: ignore` counts (not a string or a comment that
mentions it). It takes one or more codes, each of a tool (`CC-GCC-`, `CC-TIDY-` or `CC-EFFECT-`), and a code that ends
with `*` is a prefix:

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
| `-j, --jobs N` | tool runs at once (default 4) |
| `--timeout SECONDS` | for one tool on one file (default 300); a timeout is a tool error |
| `-b, --baseline FILE`, `--update-baseline` | see above |
| `--exclude LIST` | files or folders to skip, comma separated (`src/vendor`, `./gen/a.c`): whole path parts |
| `--gcc PROGRAM`, `--clang-tidy PROGRAM` | the programs to run, for a versioned name such as `gcc-14` |
| `--clang PROGRAM` | the clang that dumps the AST for the rules |
| `--json` | one JSON object |
| `-c, --config FILE` | the settings file (Settings) |
| `--no-infer` | no roots inferred from the callbacks of libuv (Roots) |

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

`include/cchecker.h` defines the macros that the rules read: `CC_SHORT`, `CC_BLOCKING`, `CC_HOT`, `CC_OWNS`,
`CC_PAIR(set, restore)`, `CC_NO_SYSCALL_UNDER(lock)` (these three for later phases) and `CC_IGNORE("CODE",
"reason")` (a suppression). With clang each is
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
4. The defaults: every `[library]` flag on, no `[roots]`.

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

[roots]
short = ["io_poll", "on_timer"]
hot = ["dispatch"]
```

`[library]` turns each family of library knowledge on or off. All are on by default. A finding of the rules says in
`source` of `--json` the flag that made it: that of the inferred root it starts from, else the family of the blocking
call it reaches, so a project knows which one to turn off. The lists are in `src/known.agc`.

| Flag | What it adds |
|---|---|
| `libc_blocking` | the calls of libc and POSIX that wait, to the blocking calls of `CC_SHORT`: files and streams (`read`, `write`, `open`, `fopen`, `fread`, `printf`, `fflush`, `fsync`, ...), sockets (`accept`, `connect`, `recv`, `send`, `getaddrinfo`, ...), waiting (`poll`, `select`, `epoll_wait`, `sleep`, `nanosleep`, `wait`, `waitpid`, `sigwait`, ...), processes (`system`, `popen`), `dlopen`, `dlsym`, POSIX semaphores and message queues, and the C11 threads (`thrd_join`, `mtx_lock`, `cnd_wait`, `call_once`, ...) |
| `pthread_blocking` | `pthread_join`, `pthread_timedjoin_np`, the locks of `pthread_mutex_`, `pthread_rwlock_` and `pthread_spin_lock`, the waits of `pthread_cond_`, `pthread_barrier_wait` and `pthread_once` |
| `libuv_blocking` | `uv_run`, `uv_sleep`, `uv_thread_join`, the locks and waits of `uv_mutex_`, `uv_rwlock_`, `uv_cond_`, `uv_sem_`, `uv_barrier_wait`, `uv_once`, and every `uv_fs_*` call whose callback, its last argument, is `NULL` or 0 |
| `libgc_blocking` | `GC_gcollect` of the Boehm collector, which stops the world |
| `libuv_callbacks_short` | a `CC_SHORT` root for each function passed as a callback that libuv runs on the loop thread: the `cb` of `uv_timer_start` (argument 1, from 0), `uv_poll_start` (2), `uv_async_init` (2) and `uv_close` (1), the `alloc_cb` and `read_cb` of `uv_read_start` (1 and 2), the callback of `uv_write` (4), `uv_write2` (5), `uv_shutdown` (2), `uv_tcp_connect` (3), `uv_pipe_connect` (3) and `uv_pipe_connect2` (5), and the `after_work_cb` of `uv_queue_work` (3), never its `work_cb`, which runs on the pool (Roots) |

A flag changes only the blocking calls of `CC_SHORT`: the rules of `CC_HOT` count every known blocking call as a
system call whatever the flags.

`[roots]` names the functions that are `CC_SHORT` (`short`) or `CC_HOT` (`hot`) without a mark in the C, by their name
(a static function of that name in any file). A finding of a root of `[roots]` is the same as that of the mark, and a
function both marked and listed is one root. A name that no function of the compile database defines is an error
(exit 2), so a rename cannot leave a rule that checks nothing. Only a full run of a compile database can tell (a run of
some files does not see the others), so only it checks the names.

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
`call`, `argument` (its place, from 0), `file` and `line`, and a run without `--json` says how many in one line on
standard error, so a root is never lost without a word.

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

| Code | |
|---|---|
| `CC-EFFECT-SHORT-BLOCKS` | a `CC_SHORT` function reaches a `CC_BLOCKING` function or a known blocking call |
| `CC-EFFECT-HOT-ALLOCATES` | a `CC_HOT` function reaches a call that allocates or frees heap memory |
| `CC-EFFECT-HOT-SYSCALL` | a `CC_HOT` function reaches a system call; a blocking call is one too |

The known calls are those of libc, pthread, libuv, OpenSSL and the Boehm collector that block (`read`, `sleep`,
`pthread_mutex_lock`, `uv_run`, a `uv_fs_*` call whose last argument, the callback, is `NULL` or 0, as it then runs
at once), allocate (`malloc`, `free`, `strdup`, `GC_malloc`, `SSL_new`) or enter the kernel (`write`, `mmap`,
`close`); an unlock or the signal of a condition counts as a system call, as it wakes a waiter with a futex call. The
lists are in `src/known.agc`. A function the project defines is judged by its body; a library function that is not
listed has no effect. A known name is known by name alone: a project function named `remove`, `rewind`, `ftell` or
`dlsym` counts as the libc one in a run that does not read its body.

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
make test        # agentica test --jobs 4, from the root of the repository
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
