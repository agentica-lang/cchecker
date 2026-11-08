# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Settings, read from the first of `-c FILE` (its `[tool.cchecker]` table when it has one), `cchecker.toml`, the
  `[tool.cchecker]` table of `agentica.toml`, and the defaults; `config` in `--json` says which. `[library]` turns the
  families of blocking calls off one by one (`libc_blocking`, `pthread_blocking`, `libuv_blocking`, `libgc_blocking`),
  and `source` in `--json` names the one of a finding. `[roots]` names `CC_SHORT` and `CC_HOT` roots without a mark.
- Inferred roots: a function passed as a callback to a libuv call that runs it on the loop thread is a `CC_SHORT` root
  (`libuv_callbacks_short`, `--no-infer`). Its finding gives the call in `root`; a callback that leads to no function
  is listed in `unresolved_callbacks` of `--json`.
- The `rules` tool (on by default): one call graph of the project from clang's JSON AST, function pointers included
  where the project stores a function in a field, a variable or a parameter. `CC-EFFECT-SHORT-BLOCKS`: a `CC_SHORT`
  function reaches a blocking call (a `CC_BLOCKING` function, or a known blocking call of libc, pthread or libuv).
  `CC-EFFECT-HOT-ALLOCATES` and `CC-EFFECT-HOT-SYSCALL`: a `CC_HOT` function allocates or makes a system call. The
  printed line and the new `path` field of `--json` give the call path; the baseline matches the message without it.
  A table too large to read that names no function in its first million lines is skipped (it may name one past them)
  and counted in `skipped_declarations` of `--json`.
- **Breaking:** the default tools are now `gcc,clang-tidy,rules`, so `clang` is needed too; `--tools gcc,clang-tidy`
  runs without it.
- Suppressions with a reason: a comment `cchecker: ignore CODE: reason` after the code of a finding's line or alone on
  the line above, and `CC_IGNORE("CODE", "reason")` on a function for the rules. `--json` lists them under
  `suppressed`; one that matches no finding is `CC-UNUSED-IGNORE`; neither goes into the baseline.
- `--clang PROGRAM`, the clang that dumps the AST. Under `CCHECKER_AST`, `cchecker.h` writes the annotations as
  `deprecated` attributes, whose text clang 19 keeps in its JSON AST.

- `cchecker`: runs `gcc -fanalyzer` and `clang-tidy` on the C files of a compile database (or of the command line) in
  parallel, and prints their findings in one format with stable `CC-GCC-` and `CC-TIDY-` codes, as lines or `--json`.
- A baseline file (`--baseline`, `--update-baseline`) that accepts findings by code, file and message, not by line. An
  update keeps the entries of the tools and files the run did not cover.
- A non-zero exit of a tool is a tool error (exit 2), a file that does not compile is never a finding, only the
  analyzer warnings of gcc are findings, and a timeout stops the tool's children too (with `timeout` installed).
- A gcc killed after analyzer errors (`-Werror`) is a tool error, not a finding; `-Werror` of the database does not
  turn the other warnings into tool errors.
- `--update-baseline` is refused when a file of the database was skipped, and a header that a partial run did not name
  keeps the larger count of its entry. `fixed` does not count the files whose job failed.
- A run of a database that ignored a non-C entry (`.cc`) is not a full run, so it keeps the entries it did not name. A
  gcc killed halfway is reported with its `fatal error` line.
- Exit codes: 0 no new findings, 1 new findings, 2 usage or tool error.
- `include/cchecker.h`: the annotation macros `CC_SHORT`, `CC_BLOCKING`, `CC_HOT`, `CC_OWNS`, `CC_PAIR` and
  `CC_NO_SYSCALL_UNDER`, an `annotate` attribute for clang and empty for other compilers.
