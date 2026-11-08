# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `cchecker`: runs `gcc -fanalyzer` and `clang-tidy` on the C files of a compile database (or of the command line) in
  parallel, and prints their findings in one format with stable `CC-GCC-` and `CC-TIDY-` codes, as lines or `--json`.
- A baseline file (`--baseline`, `--update-baseline`) that accepts findings by code, file and message, not by line. An
  update keeps the entries of the tools and files the run did not cover.
- A non-zero exit of a tool is a tool error (exit 2), a file that does not compile is never a finding, only the
  analyzer warnings of gcc are findings, and a timeout stops the tool's children too (with `timeout` installed).
- Exit codes: 0 no new findings, 1 new findings, 2 usage or tool error.
- `include/cchecker.h`: the annotation macros `CC_SHORT`, `CC_BLOCKING`, `CC_HOT`, `CC_OWNS`, `CC_PAIR` and
  `CC_NO_SYSCALL_UNDER`, an `annotate` attribute for clang and empty for other compilers.
