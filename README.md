# cchecker

Checks C code and runs the usual analyzers in one command. It runs `gcc -fanalyzer` and `clang-tidy` on each file, in
parallel, and prints what they find in one format with stable codes. A baseline file accepts the findings a project has
today, so CI fails only on new ones. It is written in [Agentica](https://github.com/agentica-lang/agentica).

The rules of a project (a call that must never block, a lock held across a system call, a value restored on every path)
come in later phases and read clang's JSON AST; the plan is in [issue 1](https://github.com/agentica-lang/cchecker/issues/1).
This version ships the one command and the annotation header.

## Install

cchecker needs Agentica 0.26.1 or later, and `gcc` 10 or later and `clang-tidy` on PATH. Clone the repository and run it
with `agentica`, or compile it to bytecode:

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

`--json` prints one object for tools and agents: `clean`, `findings` (each has `code`, `tool`, `file`, `line`, `column`
and `message`), `baselined`, `fixed` and `errors` (a tool that did not run or could not compile a file: `tool`, `file`
and `message`).

Exit codes: `0` no new findings, `1` new findings, `2` a usage error or a tool error (a missing tool, a timeout, a file
that does not compile). Only the C files of a database are run; the paths are relative to the working directory, and a
finding in a file outside it (a system or third-party header) is dropped.

### Codes

A code is stable: a baseline holds it. `CC-GCC-` is followed by the gcc warning option in capitals
(`-Wanalyzer-malloc-leak` is `CC-GCC-ANALYZER-MALLOC-LEAK`), and `CC-TIDY-` by the clang-tidy check
(`clang-analyzer-unix.Malloc` is `CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC`). A diagnostic without a name is `CC-GCC-WARNING`
or `CC-TIDY-WARNING`.

### Baseline

```sh
agentica cchecker.agc -p build --baseline cchecker-baseline.json --update-baseline   # writes the file, exit 0
agentica cchecker.agc -p build --baseline cchecker-baseline.json                     # fails on new findings only
```

A finding matches the baseline by its code, its file and its message, never its line, so edits above it do not break
the baseline. The file holds a count for each kind, so a second finding of a kind the baseline holds once is new.
`fixed` in the report counts the accepted findings that no tool found this time: update the baseline to drop them.
`--update-baseline` refuses to write when a tool failed.

### Options

| Option | |
|---|---|
| `-p, --compile-commands PATH` | the compile database: a file or its folder (default: `compile_commands.json` here) |
| `-t, --tools LIST` | `gcc`, `clang-tidy` or both (default both) |
| `--checks LIST` | the clang-tidy checks, after those of a `.clang-tidy` file; default below |
| `-j, --jobs N` | tool runs at once (default 4) |
| `--timeout SECONDS` | for one tool on one file (default 300) |
| `-b, --baseline FILE`, `--update-baseline` | see above |
| `--exclude LIST` | comma separated path prefixes to skip: their files do not run and their findings are dropped |
| `--gcc PROGRAM`, `--clang-tidy PROGRAM` | the programs to run, for a versioned name such as `gcc-14` |
| `--json` | one JSON object |

The default checks are `-*`, `clang-analyzer-core.*`, `-unix.*` and `-security.*` (without `insecureAPI`), and the
bugprone checks `sizeof-expression`, `integer-division`, `suspicious-memory-comparison`, `signed-char-misuse`,
`misplaced-widening-cast` and `unused-return-value`. The tools run with `LC_ALL=C`, so the messages are in English on any machine.

## Annotations

`include/cchecker.h` defines the macros that later phases read: `CC_SHORT`, `CC_BLOCKING`, `CC_HOT`, `CC_OWNS`,
`CC_PAIR(set, restore)` and `CC_NO_SYSCALL_UNDER(lock)`. With clang each is `__attribute__((annotate("cchecker:...")))`;
with any other compiler it is empty.

```c
#include "cchecker.h"

CC_SHORT int next_id(void);
void adopt(CC_OWNS char *name);
CC_PAIR(mask_signals, restore_signals) int guarded(void);
```

## Development

The tests are Agentica too: BDD features in `specs/` that run cchecker on the C files of `specs/fixtures/`, and unit
tests in `test/`. They need `gcc`, `clang` and `clang-tidy`.

```sh
make check       # agentica check
make fmt-check   # agentica fmt --check; `agentica fmt` fixes it
make test        # agentica test --jobs 4, from the root of the repository
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
