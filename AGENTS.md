# cchecker

Checks C code for project rules on clang's JSON AST, and runs `gcc -fanalyzer` and `clang-tidy` in the same command
with one output format. Written in Agentica; the plan and the phases are in issue 1 (`gh issue view 1 -R
agentica-lang/cchecker`). No C code of ours except the annotation header and the C fixtures of the tests.

## Map

```text
agentica.toml     the package (name, [style], the native module, [dependencies]: prop for the property tests)
agentica.lock     the locked commit and hash of prop; `make deps` installs it into deps/ (gitignored)
native/           scan.c: the native module that scans clang's AST dump (src/scan.agc)
cchecker.agc      main: the options, the run, the exit code
src/              one module per topic (`ls src/`): the compile database, running the tools, parsing their
                  output, the findings, the baseline, the report; for the rules: scan (the project's declarations
                  out of the AST dump), ast (reading its nodes), unit (functions, calls, pointer stores), effects
                  (the call graph and its rules), known (the blocking, allocating, system and lock calls by family,
                  the libuv callbacks that are roots), flow (the control flow graph of a function), locking (the
                  lock and CC_PAIR rules on its paths), held (what runs while a lock is held), ownership (the CC_OWNS
                  rules on its paths), collector (values of the collector out of malloc memory and statics); config
                  (the settings: -c, cchecker.toml, [tool.cchecker] of agentica.toml); suppressions
                  (`cchecker: ignore`, CC_IGNORE)
include/          cchecker.h: the annotation macros that the rules read (CC_SHORT, ...)
docs/             the reference by topic (usage, suppressions, settings, rules, ownership); README.md: the short guide
specs/            .feature files (BDD through the CLI) and steps.agc; props.agc (tables of function pointers),
                  lock_props.agc (the lock walk against an oracle of all paths) and suppression_props.agc (ignore
                  comments and CC_IGNORE against the rule), the generators and laws of the property tests;
                  specs/fixtures/ holds the small C files and a compile_commands.json for them
test/             unit tests of the pure helpers (the parsers, the scan of the AST dump)
.github/          CI
```

## Commands

- Binary: the Agentica release pinned in `.github/workflows/ci.yml` (the `version` and `sha256` inputs of
  `agentica-lang/setup-agentica`, in both jobs). Download it
  under `.tools/` (gitignored), never `/tmp`. Changing the pin changes both values from the release's SHA256SUMS.
- `make check`: `agentica check`, then `make lint` (`agentica lint --strict`: a style suggestion fails it).
  `make fmt-check`: `agentica fmt --check` (`agentica fmt` fixes it). `make test`: `agentica test --jobs 4` (the
  features and the unit tests) without the scenarios tagged `@slow`; `make test-slow` runs those, in a CI job of
  their own (on a shared machine, run at most one, with `--only`). Both first run `make deps` (`agentica install`:
  prop into `deps/`, with the network only when the download cache lacks the locked commit) and `make native`, which
  builds the native module once. `make check` runs `make deps` too.
  `agentica test --only TEXT` runs the scenarios whose name contains `TEXT`.
- The tests need `gcc`, `clang`, `clang-tidy`, `sh` and `timeout` (coreutils) on PATH. CI installs them and fails if
  one is missing; a local run without one fails the scenarios too.
- `agentica cchecker.agc [options] FILE... -- FLAGS...` runs the tool; `agentica compile cchecker.agc -o cchecker.agcb`
  builds it.

## Rules

- Search with `rg`.
- Tests are written first: the scenario that fails, then the code. All tests are Agentica and run with `agentica test`
  (BDD features in `specs/` first, `*_test.agc` unit tests in `test/` only for a pure helper such as a parser). No
  Python (no pytest, no helper scripts) in the tests or in CI.
- A scenario on a large generated input (a limit of the rules, a bound on time or memory) is tagged `@slow` and goes
  in `specs/limits.feature`, with its bounds in the step (`in at most N MiB and S seconds`); each scenario has 30 s.
  The memory bound is `ulimit -v`: virtual size, not peak RSS, and the tests run on Linux only.
- Property tests use the `prop` package (`agentica.lock`, `make deps`): a law in `specs/*props.agc` generates small C
  files, runs the compiled cchecker on each and returns the C file of a failing case in its message (`Prop.check`
  shrinks it, in at most 30 runs). A scenario of `specs/properties.feature` runs a few cases; its `@slow` twin runs
  many, in rows of about 100 so that each fits the 30 s of a scenario. A failure gives its seed:
  `CCHECKER_PROP_SEED=SEED agentica test --only "NAME" specs/properties.feature` runs the same cases.
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
- A change that a user sees adds a line under `## [Unreleased]` in `CHANGELOG.md`. Update the README, or the file of
  docs/ for its topic, with it.
- A PR is about 2k lines at most and holds its own tests and docs; do not leave validation or conventions to the next
  PR.
- Commits carry no attribution lines.
