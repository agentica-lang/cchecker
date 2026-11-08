# cchecker

Checks C code for project rules on clang's JSON AST, and runs `gcc -fanalyzer` and `clang-tidy` in the same command with
one output format. Written in Agentica; the plan and the phases are in issue 1 (`gh issue view 1 -R
agentica-lang/cchecker`). No C code of ours except the annotation header and the C fixtures of the tests.

## Map

```text
agentica.toml     the package (name, [style])
cchecker.agc      main: the options, the run, the exit code
src/              one module per topic (`ls src/`): the compile database, running the tools, parsing their
                  output, the findings, the baseline, the report
include/          cchecker.h: the annotation macros that the rules of later phases read (CC_SHORT, ...)
specs/            .feature files (BDD through the CLI) and steps.agc; specs/fixtures/ holds the small C files
test/             unit tests of the pure helpers (the parsers)
.github/          CI
```

## Commands

- Binary: the Agentica release pinned in `.github/workflows/ci.yml` (`AGENTICA_VERSION`, with its sha256). Download it
  under `.tools/` (gitignored), never `/tmp`. Changing the pin changes both values from the release's SHA256SUMS.
- `make check`: `agentica check`. `make fmt-check`: `agentica fmt --check` (`agentica fmt` fixes it). `make test`:
  `agentica test --jobs 4` (the features and the unit tests). `agentica test --only TEXT` runs the scenarios whose name
  contains `TEXT`.
- The tests need `gcc`, `clang` and `clang-tidy` on PATH. CI installs them and fails if one is missing; a local run
  without one fails the scenarios too.
- `agentica cchecker.agc [options] FILE... -- FLAGS...` runs the tool; `agentica compile cchecker.agc -o cchecker.agcb`
  builds it.

## Rules

- Search with `rg`.
- Tests go through the CLI: a scenario runs `cchecker.agc` on a small C fixture and asserts the exit code and the codes
  in the output, never message text (the compilers' texts change between versions). A fixture is one small file per rule
  or analyzer case; a clean twin shows what does not trigger. Unit tests are only for pure helpers (parsers).
- Codes are stable and start with `CC-`: `CC-GCC-...` and `CC-TIDY-...` for the analyzers, then one prefix per rule of a
  later phase. A finding is `{code, tool, file, line, column, message}`; add a field only with its test. Never rename a
  code: baselines of users hold them.
- Exit codes: 0 no new findings, 1 new findings, 2 usage or tool error (a missing tool, a timeout, a file that does not
  compile).
- No C parser of our own: the rules read clang's AST as JSON.
- Style: `agentica-code-guidelines` (lines up to 119, `blank_line_after_end`). Public code gets a short `##` doc.
- A change that a user sees adds a line under `## [Unreleased]` in `CHANGELOG.md`. Update the README with it.
- A PR is about 2k lines at most and holds its own tests and docs; do not leave validation or conventions to the next PR.
- Commits carry no attribution lines.
