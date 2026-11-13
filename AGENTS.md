# cchecker

Checks C code for project rules on clang's JSON AST, and runs `gcc -fanalyzer` and `clang-tidy` in the same command
with one output format. Written in Agentica; planned work is in the GitHub issues, one milestone per release. No C
code of ours except the annotation header and the C fixtures of the tests.

## Map

```text
agentica.toml     the package (name, [style], the native module, [dependencies]: prop for the property tests, native-gen)
agentica.lock     the locked commits and hashes of prop and native-gen; `make deps` installs it into deps/ (gitignored)
native/           scan.c: the native module that scans clang's AST dump (src/scan.agc), on cchecker_scan_native.h,
                  made by native-gen from its `extern module` block (`make header`, `make header-check`)
cchecker.agc      main: the options, the run, the exit code
src/              one module per topic (`ls src/`): the tools and their output, the findings, the baseline, the
                  report; for the rules: scan and ast (the AST dump), unit (functions, calls, pointer stores),
                  effects, known (the call tables by family), flow (the control flow graph), locking, held,
                  ownership, collector; config (the settings); suppressions
include/          cchecker.h: the annotation macros that the rules read (CC_SHORT, ...)
docs/             the reference by topic (usage, suppressions, settings, rules, ownership); README.md: the short guide
site/             the docs site: hugo.toml mounts README.md (the home) and docs/, and gives each page its title,
                  order and description; the look comes from themes/docs-theme (the submodule agentica-lang/docs-theme)
specs/            .feature files (BDD through the CLI) and steps.agc; the *props.agc files are the generators and laws
                  of the property tests; specs/fixtures/ holds the small C files and a compile_commands.json
test/             unit tests of the pure helpers (the parsers, the scan of the AST dump)
.github/          CI; pages.yml builds the site and deploys it from main
```

## Commands

- Binary: the Agentica release pinned in `.github/workflows/ci.yml` (the `version` and `sha256` inputs of
  `agentica-lang/setup-agentica`, in both jobs). Download it under `.tools/` (gitignored), never `/tmp`. Changing the
  pin changes both values from the release's SHA256SUMS.
- `make check` (`agentica check`, then `agentica lint --strict`), `make fmt-check` (`agentica fmt` fixes it),
  `make test` (`agentica test --jobs 4`, without `@slow` and `@pending`), `make test-slow` (the `@slow` ones, a CI job
  of their own; on a shared machine run at most one, with `--only`), `make test-pending` (fails when a `@pending` row
  passes). All first run `make deps` (`agentica install`: prop and native-gen into `deps/`) and `make native`; the
  `Makefile` comments say the rest.
  `agentica test --only TEXT` runs the scenarios whose name contains `TEXT`.
- The tests need `gcc`, `clang`, `clang-tidy`, `sh` and `timeout` (coreutils) on PATH. CI installs them and fails if
  one is missing; a local run without one fails the scenarios too.
- `agentica cchecker.agc [options] FILE... -- FLAGS...` runs the tool.
- `make site` builds the docs site (`git submodule update --init`, Hugo and Dart Sass pinned in `pages.yml`); a new
  page of `docs/` needs a `[[cascade]]` in `site/hugo.toml` for its title, order and description. `docs/` is flat
  Markdown: no images and no subfolders.

## Rules

- Search with `rg`.
- Tests are written first: the scenario that fails, then the code. All tests are Agentica and run with `agentica test`
  (BDD features in `specs/` first, `*_test.agc` unit tests in `test/` only for a pure helper such as a parser). No
  Python (no pytest, no helper scripts) in the tests or in CI.
- A scenario on a large generated input (a limit of the rules, a bound on time or memory) is tagged `@slow` and goes
  in `specs/limits.feature`, with its bounds in the step (`in at most N MiB and S seconds`); each scenario has 30 s.
  The memory bound is `ulimit -v`: virtual size, not peak RSS, and the tests run on Linux only.
- Property tests use the `prop` package: a law in `specs/*props.agc` generates small C files, runs the compiled
  cchecker on each and returns the C file of a failing case in its message (`Prop.check` shrinks it, in at most 30
  runs). A scenario of `specs/properties.feature` runs a few cases; its `@slow` twin runs many, in rows of about 100 so
  that each fits the 30 s of a scenario. A failure gives its seed:
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
- `specs/clean_c.feature` is the corpus of common C idioms that must give no finding, one small function per row, with
  the small change that gives a finding in its second outline. A false finding becomes a row there. A row that does
  not pass yet stays, in an `Examples` block tagged `@pending` and `@issue-N`; the PR that closes the issue moves it up
  (`make test-pending` fails until it does).
- A PR is about 2k lines at most and holds its own tests and docs; do not leave validation or conventions to the next
  PR. A change that a user sees adds a line under `## [Unreleased]` in `CHANGELOG.md` (the file keeps the last three
  versions; older ones live in the release notes, which a release PR trims) and updates the README, or the
  file of docs/ for its topic.
- Before a PR: read the diff against main; say which findings change (for a rule change, on a real code base too:
  `make bench`); every fix has a row that failed before it, and a new or changed rule has rows in
  `specs/clean_c.feature`; a path rule (locks, ownership) does not grow the walk state (check a loop and a repeated
  macro in `specs/limits.feature`); run `make check`, `make fmt-check` and the specs you touched, not the whole
  `make test` (CI runs it); the PR body matches the head.
- Commits carry no attribution lines.
