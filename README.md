# cchecker

Checks C code for the rules of a project and runs the usual analyzers in one command. It runs `gcc -fanalyzer`,
`clang-tidy` and its own rules on each file, in parallel, and prints what they find in one format with stable codes. A
baseline file accepts the findings a project has today, so CI fails only on new ones. It is written in
[Agentica](https://github.com/agentica-lang/agentica).

The rules read clang's JSON AST and the annotations of `include/cchecker.h`. This version checks effects on the call
graph (a `CC_SHORT` function never reaches a blocking call, and a `CC_HOT` function never allocates or makes a system
call) and locks on every path of a function: a lock taken is released, a lock released is held, no system call runs
under a lock marked `CC_NO_SYSCALL_UNDER`, and locks are taken in the order of their `CC_LOCK_LEVEL`. Paired state
and ownership come in later phases; the plan is in [issue 1](https://github.com/agentica-lang/cchecker/issues/1).

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
`column`, `message` and `path`, the call path of a finding of the rules), `baselined`, `fixed`, `errors` (a tool that
did not run or could not compile a file: `tool`, `file` and `message`), `skipped` and `suppressed` (below).

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
rules have `CC-EFFECT-` and `CC-PATH-` codes (below).

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
mentions it). It takes one or more codes, each of a tool (`CC-GCC-`, `CC-TIDY-`, `CC-EFFECT-` or `CC-PATH-`), and a
code that ends with `*` is a prefix:

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
`CC_RELEASES(lock)`, `CC_NORETURN`, `CC_NO_SYSCALL_UNDER(lock)`, `CC_LOCK_LEVEL(n)`, `CC_OWNS`, `CC_PAIR(set,
restore)` (these two for later phases) and `CC_IGNORE("CODE", "reason")` (a suppression). With clang each is
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

A call through a function pointer reaches every function the project stores in the same place: a field of a struct or
a union (by record and field name, in an initializer, designated or not, or an assignment), a variable, or a parameter
of a function (from the direct calls that pass a function), and every function of a place copied into it
(`box.handle = handle`). A cast is seen through, so a function kept in a `void *` or an `uintptr_t` is reached by a
call through it. A variable with `__attribute__((cleanup(f)))` calls `f`. A pointer that comes from anywhere else
reaches nothing: a return value, the arguments of a variadic function, and a function handed to a library that calls
it back (`qsort`, a libuv callback). A walk goes only through what the run read, so run
it on all the files of the project: with a subset of the files, a call into a file that was not run reaches nothing.
For the baseline, only a full run of a compile database covers the findings of the rules: a run of some files never
counts them fixed and never drops them on `--update-baseline`.

### Locks on every path

The rules build a control flow graph of each function that takes or releases a lock, and follow every path through
it: `if`, `switch` with its fallthrough and without a `default`, loops with `break` and `continue`, `goto` (a computed
one may go to any label), `return`, `&&`, `||`, `?:` and statement expressions. A path ends at a `return`, at the end
of the body, or at a call that never comes back (`abort`, a `_Noreturn` or `noreturn` function, or one marked
`CC_NORETURN`, such as a function that jumps out with `longjmp`); a lock held there is not a finding. The cleanup
function of a variable with `__attribute__((cleanup(f)))` runs on every way out of its block.

| Code | |
|---|---|
| `CC-PATH-LOCK-NOT-RELEASED` | a path returns with a lock that the function took |
| `CC-PATH-LOCK-NOT-HELD` | a path releases a lock that the function did not take |

The finding is at the function, once for each code and lock, and `path` is a shortest path that breaks the rule, from
the call that took (or released) the lock to the end: `7:7 true` is the condition at line 7, column 7, taken as true.

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
lock(); ...; if (locked) unlock();` passes; a write to a variable of the condition forgets its value. A function whose
paths would take more than 200 000 states to follow is checked without these conditions.

A function that takes a lock for its caller, or releases the caller's lock, says so on its prototype:
`CC_ACQUIRES(lock)` or `CC_RELEASES(lock)`, with the lock written in the names of its parameters (or a global). A call
then takes or releases that lock in the words of the call: for `CC_ACQUIRES(q->mu) void queue_lock(struct queue *q)`,
`queue_lock(vm->q)` takes `vm->q->mu`. Such a function is a lock helper: its own body is trusted (a count of nested
takes, a spin before the wait), and its callers are checked. Without an annotation, a function that takes a lock and
returns with it is a finding, so a forgotten unlock never passes for a helper. Put the annotation on the prototype that
the callers include: a caller sees the declarations of its own file. A function that takes or releases a lock only on
some of its returns (`false` when it dropped the lock) is beyond these rules: suppress its findings with `CC_IGNORE`,
with the reason. A call through a function pointer does nothing to the locks.

### What runs while a lock is held

A lock held for short sections only, which other threads spin for, is marked on its field (or on a global lock):
`CC_NO_SYSCALL_UNDER()`. While a path holds it, no call is a system call or a blocking call (the lists of the effects,
a lock or an unlock of another lock included) or reaches one through the functions of the project, except the
release of the lock itself and a wait on a condition with it. `CC_NO_SYSCALL_UNDER(lock)` on a function says the same
of one lock of that function, in the names of its parameters.

`CC_LOCK_LEVEL(n)` on the field of a lock (or a global lock) orders the locks: a path takes a lock with a level only
while every lock it holds with a level has a lower one, and it calls a function that takes one (in its body or in the
functions it reaches) only then. Two locks of the same level are never held together; a called function that takes
the class of a lock held again (a counted lock, taken once more by the same thread) is not out of order.

```c
struct runtime { CC_LOCK_LEVEL(1) pthread_mutex_t sync; ... };
struct runq { CC_NO_SYSCALL_UNDER() CC_LOCK_LEVEL(3) pthread_mutex_t lock; ... };
```

| Code | |
|---|---|
| `CC-PATH-SYSCALL-UNDER-LOCK` | a call under a `CC_NO_SYSCALL_UNDER` lock is or reaches a system call |
| `CC-PATH-LOCK-ORDER` | a lock with a level is taken (or a function that takes one is called) under one of the same or a higher level |

A field is known by its struct and its name (`runq.lock`, the name of a typedef for an anonymous struct), and a global
by its name. A lock of a `CC_ACQUIRES` is followed to its field through the types of the parameters
(`CC_ACQUIRES(s->pool->mu)` on `void pool_lock(struct server *s)` takes `pool.mu`). The path of a finding goes from
the take of the lock held to the call, and the call path to the system call when there is one: `13:3 calls bump: bump
-> pthread_mutex_lock`.

The AST of a file is tens of MiB with its system headers, more than a process output holds in Agentica (1 MiB):
`sh` writes it to a file in a private folder under `$TMPDIR`, and cchecker reads it line by line and keeps only the
declarations of the project. A table of numbers is not kept: an array of a number or character type, or whose first
item is a number (`const uint8_t ROM[]`); a null pointer item (`0`, `NULL`) is not a number. A declaration of more
than a million lines of the dump is left out: when it named no function so far (a table of enum values or of structs
of numbers) it is counted in `skipped_declarations` of `--json` and in a line on standard error (a function past the
cap is not read), and otherwise it is a tool error, while the rest of the file is checked. A dump that ends early is
a tool error. The folder is removed at the end of the run, and a run removes the folders that killed runs left there:
a folder of the same user, private, not a link, holding only dumps, whose process is gone. Runs in different PID
namespaces that share `$TMPDIR` can remove each other's folders.

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
