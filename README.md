# cchecker

Checks C code for the rules of a project and runs the usual analyzers in one
command. It runs `gcc -fanalyzer`, `clang-tidy` and its own rules on each file,
in parallel, and prints what they find in one format with stable codes. A
baseline file accepts the findings a project has today, so CI fails only on new
ones. It is written in [Agentica](https://github.com/agentica-lang/agentica).

The rules read clang's JSON AST and the annotations of `include/cchecker.h`.
This version checks effects on the call graph (a `CC_SHORT` function never
reaches a blocking call, and a `CC_HOT` function never allocates or makes a
system call) and locks on every path of a function: a lock taken is released, a
lock released is held, no system call runs under a lock marked
`CC_NO_SYSCALL_UNDER`, locks are taken in the order of their `CC_LOCK_LEVEL`,
and the set of a `CC_PAIR` is restored. It also checks ownership on every path:
a pointer marked `CC_OWNS` is freed or handed on, not freed twice and not used
after; and a value of the collector (`CC_GC`, `CC_GC_ALLOC`) is never stored in
memory from `malloc` or in a static. The plan is in [issue
1](https://github.com/agentica-lang/cchecker/issues/1).

## Install

cchecker needs Agentica 0.26.1 or later, and `gcc` 10 or later, `clang` and
`clang-tidy` on PATH, and `sh`. The scan of clang's AST is a small native module
in C (`native/`), which the first run (or `agentica compile`) builds with the
system C compiler (`cc`); a module that cannot be built or loaded is a tool
error. Clone the repository and run it with `agentica`, or compile it to
bytecode:

```sh
agentica cchecker.agc [options] FILE... -- COMPILER-FLAGS...
agentica compile cchecker.agc -o cchecker.agcb      # then: agentica run -- cchecker.agcb [options]
```

## Quick start

With a compile database (`compile_commands.json`, from CMake, `bear` or `clang
-MJ`), run it from the root of the project:

```sh
agentica cchecker.agc -p build                     # a file or the folder that holds compile_commands.json
agentica cchecker.agc -p build --baseline cchecker-baseline.json
```

Or name the files and give the flags after `--`:

```sh
agentica cchecker.agc src/a.c src/b.c -- -Iinclude -DNDEBUG
```

A finding is one line, `file:line:column CODE message`, and the last line is a
summary:

```text
src/a.c:9:12 CC-GCC-ANALYZER-MALLOC-LEAK leak of 'buf'
src/a.c:9:12 CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC Potential leak of memory pointed to by 'buf'
cchecker: 2 new findings in 1 file
```

`--json` prints one object for tools and agents. Exit codes: `0` no new
findings, `1` new findings, `2` a usage error or a tool error (a missing tool, a
timeout, a file that does not compile).

Mark a function for the rules with the macros of `include/cchecker.h`, which are
empty in a normal build and only mark code while cchecker dumps the AST
(`CCHECKER_AST`; all of them are in [Annotations](docs/rules.md#annotations)):

```c
#include "cchecker.h"

CC_SHORT int next_id(void);
void adopt(CC_OWNS char *name);
CC_PAIR(mask_signals, restore_signals) int guarded(void);
```

To accept today's findings, write a baseline with `--update-baseline`; to hide a
false positive, write `// cchecker: ignore CODE: reason` next to it (see
[Baseline and suppressions](docs/suppressions.md)). Settings (`cchecker.toml`)
turn the library knowledge on or off, name roots and state assumptions (see
[Settings](docs/settings.md)).

## Options

The ones used most: `-p` (the compile database), `-t` (the tools to run: `gcc`,
`clang-tidy`, `rules`), `-b` and `--update-baseline`, `--exclude`, `-j`,
`--timeout`, `--json` and `-c` (the settings file). `--all-paths` and
`--no-infer` tune the rules. Every option, the default clang-tidy checks and the
timeout rules are in [Output, options and exit codes](docs/usage.md).

## Codes

A code is stable: a baseline holds it. The analyzers have `CC-GCC-` (the gcc
warning option in capitals, `CC-GCC-ANALYZER-MALLOC-LEAK`) and `CC-TIDY-` (the
clang-tidy check, `CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC`) codes. The rules have
these:

| Code | A finding when |
|---|---|
| `CC-EFFECT-SHORT-BLOCKS` | a `CC_SHORT` function reaches a blocking call |
| `CC-EFFECT-HOT-ALLOCATES` | a `CC_HOT` function reaches a call that allocates or frees heap memory |
| `CC-EFFECT-HOT-SYSCALL` | a `CC_HOT` function reaches a system call |
| `CC-PATH-LOCK-NOT-RELEASED` | a path returns, or jumps out at a `CC_MAY_JUMP` call, with a lock that the function took |
| `CC-PATH-LOCK-NOT-HELD` | a path releases a lock that the function did not take |
| `CC-PATH-SYSCALL-UNDER-LOCK` | a call under a `CC_NO_SYSCALL_UNDER` lock is or reaches a system call |
| `CC-PATH-LOCK-ORDER` | a lock with a level is taken under one of the same or a higher level |
| `CC-PATH-PAIR-NOT-RESTORED` | a path returns after a call of `set` of a `CC_PAIR` and no call of `restore` |
| `CC-PATH-PAIR-NOT-SET` | a path calls `restore` of a `CC_PAIR` with no call of `set` before it |
| `CC-OWN-LEAK` | a path returns, jumps out at a `CC_MAY_JUMP` call, or gives a pointer a new value, while it still owns |
| `CC-OWN-DOUBLE-FREE` | a path frees a pointer that it already freed or handed on |
| `CC-OWN-USE-AFTER-FREE` | a path uses a pointer after it freed it or handed it on |
| `CC-OWN-GC-IN-MALLOC` | a value of the collector is stored in memory from `malloc` |
| `CC-OWN-GC-IN-STATIC` | a value of the collector is stored in a variable of static storage |
| `CC-UNUSED-IGNORE` | a `cchecker: ignore` or `CC_IGNORE` code matches no finding |

## Documentation

- [Output, options and exit codes](docs/usage.md): the `--json` object, exit
  codes, every option, timeouts.
- [Baseline and suppressions](docs/suppressions.md): `--update-baseline`, what a
  run covers, `cchecker: ignore` and `CC_IGNORE`.
- [Settings](docs/settings.md): `cchecker.toml`, the `[library]` flags,
  `[roots]`, `[assume]` and how the roots of a rule are found.
- [Rules](docs/rules.md): the annotations, the effect rules, the lock rules and
  the pairs of calls.
- [Ownership and the collector](docs/ownership.md): `CC_OWNS`, `CC_FREES`,
  `CC_GC` and `CC_GC_ALLOC`.

## Development

The tests are Agentica too: BDD features in `specs/` that run cchecker on the C
files of `specs/fixtures/`, and unit tests in `test/`. They need `gcc`, `clang`,
`clang-tidy` and `sh`. `AGENTS.md` has the rules for a change.

```sh
make check       # agentica check, then agentica lint --strict (make lint alone)
make fmt-check   # agentica fmt --check; `agentica fmt` fixes it
make test        # agentica test --jobs 4 without the @slow scenarios, from the root of the repository
make test-slow   # the @slow scenarios only (the bounds of specs/limits.feature, the property tests on many cases)
make deps        # agentica install: prop into deps/; make check, test and test-slow run it first
make native      # builds the native module once; make test and make test-slow run it first
make bench       # the rules on the C VM of Agentica: wall time and peak RSS (BENCH_JOBS=2 for -j 2)
```

The property tests of `specs/properties.feature` use the
[prop](https://github.com/agentica-lang/packages) package; a failure shows the
seed to replay (`AGENTS.md`). `bench/run.sh` describes `make bench`.

## License

Apache License 2.0. See [LICENSE](LICENSE).
