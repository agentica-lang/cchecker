# cchecker

Checks C code for project rules on clang's JSON AST, and runs `gcc -fanalyzer` and `clang-tidy` in the same command
with one output format. Written in Agentica; the plan and the phases are in issue 1 (`gh issue view 1 -R
agentica-lang/cchecker`). No C code of ours except the annotation header and the C fixtures of the tests.

## Map

```text
agentica.toml     the package (name, [style])
cchecker.agc      main: the options, the run, the exit code
src/              one module per topic (`ls src/`): the compile database, running the tools, parsing their
                  output, the findings, the baseline, the report; for the rules: scan (the project's declarations
                  out of the AST dump), ast (reading its nodes), unit (functions, calls, pointer stores), effects
                  (the call graph and its rules), known (the blocking, allocating, system and lock calls), flow (the
                  control flow graph of a function), locking (the lock and CC_PAIR rules on its paths), held (what
                  runs while a lock is held), ownership (the CC_OWNS rules on its paths); suppressions
                  (`cchecker: ignore`, CC_IGNORE)
include/          cchecker.h: the annotation macros that the rules read (CC_SHORT, ...)
specs/            .feature files (BDD through the CLI) and steps.agc; specs/fixtures/ holds the small C files and a
                  compile_commands.json for them
test/             unit tests of the pure helpers (the parsers, the scan of the AST dump)
.github/          CI
```

## Commands

- Binary: the Agentica release pinned in `.github/workflows/ci.yml` (the `version` and `sha256` inputs of
  `agentica-lang/setup-agentica`). Download it
  under `.tools/` (gitignored), never `/tmp`. Changing the pin changes both values from the release's SHA256SUMS.
- `make check`: `agentica check`. `make fmt-check`: `agentica fmt --check` (`agentica fmt` fixes it). `make test`:
  `agentica test --jobs 4` (the features and the unit tests). `agentica test --only TEXT` runs the scenarios whose name
  contains `TEXT`.
- The tests need `gcc`, `clang`, `clang-tidy`, `sh` and `timeout` (coreutils) on PATH. CI installs them and fails if
  one is missing; a local run without one fails the scenarios too.
- `agentica cchecker.agc [options] FILE... -- FLAGS...` runs the tool; `agentica compile cchecker.agc -o cchecker.agcb`
  builds it.

## Rules

- Search with `rg`.
- Tests are written first: the scenario that fails, then the code. All tests are Agentica and run with `agentica test`
  (BDD features in `specs/` first, `*_test.agc` unit tests in `test/` only for a pure helper such as a parser). No
  Python (no pytest, no helper scripts) in the tests or in CI, and no property-based tests for now.
- A fake tool for a scenario is a small shell script in `specs/fixtures/` (`fake_gcc_*.sh`, run with `--gcc`).
- A scenario runs `cchecker.agc` on a small C fixture and asserts the exit code, the codes and the `--json` fields,
  never message text (the compilers' texts change between versions). A fixture is one small file per case, with a clean
  twin that does not trigger. Check that a new scenario fails without the code it covers (stub the code, run, restore).
- `agentica test` runs from the root of the repository; the steps start cchecker in `specs/`. A scenario that writes C
  files uses `the C file "x.c" holds:` (a folder under `specs/scratch/`, removed at the end). An exit code 2 alone is a
  weak assertion (a program that does not start gives 2 too): pair it with a case that must pass.
- Codes are stable and start with `CC-`: `CC-GCC-...` and `CC-TIDY-...` for the analyzers, then one prefix per rule of
  a later phase. A finding is `{code, tool, file, line, column, message}`; add a field only with its test. Never rename
  a code: baselines of users hold them.
- Exit codes: 0 no new findings, 1 new findings, 2 usage or tool error (a missing tool, a timeout, a file that does not
  compile).
- No C parser of our own: the rules read clang's AST as JSON. The dump is far larger than 1 MiB: it goes to a file
  and is read line by line (`src/scan.agc`), never through `Process.output`.
- Style: `agentica-code-guidelines` (lines up to 119, `blank_line_after_end`). Public code gets a short `##` doc.
- A change that a user sees adds a line under `## [Unreleased]` in `CHANGELOG.md`. Update the README with it.
- A PR is about 2k lines at most and holds its own tests and docs; do not leave validation or conventions to the next
  PR.
- Commits carry no attribution lines.
