# cchecker

Checks C code for the rules of a project and runs the usual analyzers in one
command. It runs `gcc -fanalyzer`, `clang-tidy` and its own rules on each file,
in parallel, and prints what they find in one format with stable codes. A
baseline file accepts the findings a project has today, so CI fails only on new
ones. It is written in [Agentica](https://github.com/agentica-lang/agentica).

The rules read clang's JSON AST and the annotations of `include/cchecker.h`:
effects on the call graph (`CC_SHORT` never reaches a blocking call, `CC_HOT`
never allocates or makes a system call), locks and pairs of calls (`CC_PAIR`) on
every path of a function, ownership on every path (`CC_OWNS`), and values of the
collector (`CC_GC`) kept out of `malloc` memory and statics.

## Install

cchecker needs Agentica 0.31.0 or later, and `gcc` 10 or later, `clang` and
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
-MJ`), run it from the root of the project, or name the files and give the flags
after `--`:

```sh
agentica cchecker.agc -p build --baseline cchecker-baseline.json   # -p: a file or the folder that holds compile_commands.json
agentica cchecker.agc src/a.c src/b.c -- -Iinclude -DNDEBUG
```

A finding is one line, `file:line:column CODE message`, and the last line is a
summary. Exit codes: `0` no new findings, `1` new findings, `2` a usage error or
a tool error.

```text
src/a.c:9:12 CC-GCC-ANALYZER-MALLOC-LEAK leak of 'buf'
cchecker: 1 new finding in 1 file
```

Write a baseline with `--update-baseline`. Hide a false positive with `//
cchecker: ignore CODE: reason`. Mark functions with the macros of
`include/cchecker.h`, which are empty in a normal build.

## Documentation

- [Output, options and exit codes](docs/usage.md): `--json`, every option,
  timeouts.
- [Baseline and suppressions](docs/suppressions.md): `--update-baseline`,
  `cchecker: ignore`, `CC_IGNORE`.
- [Settings](docs/settings.md): `cchecker.toml`, `[library]`, `[roots]`,
  `[assume]`.
- [Rules](docs/rules.md): the annotations, effects, locks and pairs of calls,
  with their codes.
- [Ownership and the collector](docs/ownership.md): `CC_OWNS`, `CC_FREES`,
  `CC_OWNS_OUT`, `CC_GC`, `CC_GC_ALLOC`.

## Development

The tests are Agentica too: BDD features in `specs/` that run cchecker on the C
files of `specs/fixtures/`, and unit tests in `test/`. `AGENTS.md` has the
commands (`make check`, `make test`, ...) and the rules for a change.

## License

Apache License 2.0. See [LICENSE](LICENSE).
