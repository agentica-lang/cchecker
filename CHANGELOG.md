# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- A `.clang-tidy` with `UseColor: true`, or a `-fdiagnostics-color=always` in the flags, no longer drops every finding
  of that tool without a word: cchecker turns the colours off after the project's settings, and a diagnostic line that
  it cannot read is a tool error (exit 2).

## [0.2.0] - 2026-11-09

### Added

- `--strict-baseline`: a stale baseline entry (its finding is gone) of the tools and files that the run covered exits
  1. Every run now names its stale entries after the summary and in `stale` of `--json`.
- `CC_MAY_JUMP` and `[assume] may_jump`: a call of a function that may jump out (`longjmp` on an error) is also a way
  out of its caller, where a pointer that still owns is `CC-OWN-LEAK` and a lock held is `CC-PATH-LOCK-NOT-RELEASED`.
- `CC_OWNS_OUT` on a parameter (`char **out`): `*out = p` hands `p` out to the caller, and `take(&p)` makes `p` own
  what the call left. `argv[i] = p` in an array that owns hands `p` on to the array.
- A baseline records the versions of the tools. An `--update-baseline` of every file (no FILE, no `--exclude`) writes
  those of the tools it ran (`gcc`, `clang`, `clang-tidy`) into `tools`, and a run with another version number warns on
  standard error and lists the change in `version_changes` of `--json`. The exit code does not change; a baseline of
  0.1.0 still reads.

### Changed

- `include/cchecker.h`: the macros are empty unless cchecker dumps the AST (`CCHECKER_AST`), so a normal clang build no
  longer carries an `annotate` attribute on every marked field and local. **Breaking:** a project that read the
  `annotate` attribute defines the macros itself.

## [0.1.0] - 2026-11-08

The first release.

### Added

- `cchecker`: runs `gcc -fanalyzer`, `clang-tidy` and its own `rules` on the C files of a compile database (or of the
  command line) in parallel, and prints their findings in one format with stable codes (`CC-GCC-`, `CC-TIDY-`,
  `CC-EFFECT-`, `CC-PATH-`, `CC-OWN-`), as lines or `--json`. The default tools are `gcc,clang-tidy,rules`, so
  `clang` is needed too; `--tools gcc,clang-tidy` runs without it, and `--clang PROGRAM` names the clang that dumps
  the AST.
- Exit codes: 0 no new findings, 1 new findings, 2 usage or tool error. A non-zero exit of a tool is a tool error, a
  file that does not compile is never a finding, only the analyzer warnings of gcc are findings (a gcc killed after
  analyzer errors or halfway is a tool error, with its `fatal error` line), and a timeout stops the tool's children
  too (with `timeout` installed).
- A file whose `#include` is not found is not checked, with `cchecker: warning: FILE not checked: HEADER not found`
  and an entry in `unchecked_files` of `--json`; the other files are checked and the exit code does not change.
- A baseline file (`--baseline`, `--update-baseline`) that accepts findings by code, file and message, not by line.
  An update keeps the entries of the tools and files the run did not cover, and a header that a partial run did not
  name keeps the larger count of its entry. It is refused when a file of the database was skipped, while `--checks`,
  `--no-infer` or a `[library]` flag set to false turns a check off, and with a `-c FILE` that leaves out a `short` or
  `hot` name of `[roots]` of the project settings.
- `include/cchecker.h`: the annotation macros (`CC_SHORT`, `CC_BLOCKING`, `CC_HOT`, `CC_OWNS`, `CC_PAIR`,
  `CC_NO_SYSCALL_UNDER`, ...), an `annotate` attribute for clang and empty for other compilers. Under `CCHECKER_AST`
  they are `deprecated` attributes, whose text clang 19 keeps in its JSON AST.
- The `rules` tool: one call graph of the project from clang's JSON AST, function pointers included where the project
  stores a function in a field, a variable or a parameter. `CC-EFFECT-SHORT-BLOCKS`: a `CC_SHORT` function reaches a
  blocking call (a `CC_BLOCKING` function, or a known blocking call of libc, pthread or libuv; a `uv_fs_*` call with
  no callback blocks only when its libc call does, else it is a system call). `CC-EFFECT-HOT-ALLOCATES` and
  `CC-EFFECT-HOT-SYSCALL`: a `CC_HOT` function allocates or makes a system call. The printed line and the `path` field
  of `--json` give the call path; the baseline matches the message without it. `--all-paths` gives a finding for each
  distinct bad call, each with its shortest path.
- The effect walk does not go into an error exit: a function that is `_Noreturn`, `[[noreturn]]`, `CC_NORETURN`,
  `__attribute__((noreturn))` (also through a typedef, or with a calling convention after it) or
  `__attribute__((cold))`, or a library call that never returns (`_exit`, `abort`, ...). `[effects] follow_cold =
  true` follows it; a `CC_BLOCKING` mark on such a function still counts.
- `open` and `openat` with `O_NONBLOCK`, and `recv`, `send`, `recvfrom` and `sendto` with `MSG_DONTWAIT`, are not
  blocking for `CC_SHORT` when the flag is a constant, with the values of the target (Linux and macOS);
  `[library] libc_nonblocking_flags` turns it off.
- Settings, read from the first of `-c FILE` (its `[tool.cchecker]` table when it has one), `cchecker.toml`, the
  `[tool.cchecker]` table of `agentica.toml`, and the defaults; `config` in `--json` says which. `[library]` turns the
  families of library knowledge off one by one, and `source` in `--json` names the one of a finding. `[roots]` names
  `CC_SHORT` and `CC_HOT` roots without a mark.
- Inferred roots: a function passed as a callback to a libuv call that runs it on the loop thread (timers, handles,
  streams, UDP, DNS, `uv_fs_*` requests and more; the lists match libuv 1.50) is a `CC_SHORT` root
  (`libuv_callbacks_short`, `--no-infer`). Its finding gives the call in `root`; a callback that leads to no function
  is listed in `unresolved_callbacks` of `--json`.
- Assumptions of a project: `CC_ASSUME_SHORT` and `[assume] short` name a function that counts as fine for
  `CC_SHORT`; `CC_STOP` and `[assume] stop` one that no rule walks into; `[assume] stop_fields` the function-pointer
  fields whose calls no rule follows; short locks (`CC_NO_SYSCALL_UNDER()` or `[assume] short_locks`) are not
  blocking for `CC_SHORT`. A name that no function of the compile database declares is an error.
- Locks on every path: a control flow graph of each function that takes or releases a lock.
  `CC-PATH-LOCK-NOT-RELEASED`: a path returns with a lock the function took; `CC-PATH-LOCK-NOT-HELD`: a path releases
  a lock it did not take. `CC_ACQUIRES(lock)` and `CC_RELEASES(lock)` mark the helpers that take or drop a lock for
  their caller. A function with more paths than the rules follow is listed in `incomplete_functions` of `--json`
  (`file`, `line`, `function`) and on standard error; one too large for a graph is an error of the `rules` tool.
- What runs under a lock: `CC_NO_SYSCALL_UNDER()` on the field of a lock (or `CC_NO_SYSCALL_UNDER(lock)` on a
  function) and `CC-PATH-SYSCALL-UNDER-LOCK` for a system or blocking call made or reached under it, a `CC_RELEASES`
  helper included; `CC_LOCK_LEVEL(n)` and `CC-PATH-LOCK-ORDER` for a lock taken while one of the same or a higher
  level is held. A lock mark that cannot be read is one error of the `rules` tool, on the file of the mark.
- Pairs of calls: `CC_PAIR(set, restore)` on a function (or on `set` itself, for all its callers).
  `CC-PATH-PAIR-NOT-RESTORED`: a path returns after `set` without `restore`; `CC-PATH-PAIR-NOT-SET`: a `restore` with
  no `set` before it.
- Ownership on every path: `CC_OWNS` on a local, a parameter, a function (it returns an owned pointer) or a field,
  and `CC_FREES` on a parameter. `CC-OWN-LEAK`, `CC-OWN-DOUBLE-FREE` and `CC-OWN-USE-AFTER-FREE`.
- Values of the collector: `CC_GC` on a type and `CC_GC_ALLOC` on an allocator (the Boehm allocators are known,
  `[library] libgc_alloc`). `CC-OWN-GC-IN-MALLOC` and `CC-OWN-GC-IN-STATIC`: such a value stored in memory from
  `malloc` or in a static.
- Suppressions with a reason: a comment `cchecker: ignore CODE: reason` after the code of a finding's line or alone on
  the line above (`//`, `///`, `//!`, `/* */`), and `CC_IGNORE("CODE", "reason")` on a function for the codes of the
  rules. `--json` lists them under `suppressed`; a code that matches no finding is `CC-UNUSED-IGNORE`; neither goes
  into the baseline.
- Speed: a native module in C scans clang's AST, which clang writes into a FIFO. The 84 files of the VM of Agentica
  take 17.9 s and 411 MB at `-j 2`, and a chain of 3000 else-if 4 s and 170 MB. `-j` defaults to the number of cores,
  and the jobs of the largest files start first.

[Unreleased]: https://github.com/agentica-lang/cchecker/compare/0.2.0...HEAD
[0.2.0]: https://github.com/agentica-lang/cchecker/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/agentica-lang/cchecker/releases/tag/0.1.0
