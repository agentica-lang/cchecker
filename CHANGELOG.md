# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
- Locks on every path: a control flow graph of each function that takes or releases a lock.
  `CC-PATH-LOCK-NOT-RELEASED`: a path returns with a lock the function took; `CC-PATH-LOCK-NOT-HELD`: a path releases
  a lock it did not take. `CC_ACQUIRES(lock)` and `CC_RELEASES(lock)` mark the helpers that take or drop a lock for
  their caller, and `CC_NORETURN` a function that never comes back. A function with more paths than the rules follow
  is counted in `incomplete_functions` of `--json`; one too large for a graph is an error of the `rules` tool.
- What runs under a lock: `CC_NO_SYSCALL_UNDER()` on the field of a lock (or `CC_NO_SYSCALL_UNDER(lock)` on a
  function) and `CC-PATH-SYSCALL-UNDER-LOCK` for a system or blocking call made or reached under it;
  `CC_LOCK_LEVEL(n)` and `CC-PATH-LOCK-ORDER` for a lock taken while one of the same or a higher level is held.
  Calls through function pointers are followed; a lock mark that cannot be read is an error of the `rules` tool.
- Pairs of calls: `CC_PAIR(set, restore)` on a function (or on `set` itself, for all its callers) and
  `CC-PATH-PAIR-NOT-RESTORED` for a path that returns after `set` without `restore`.
- Ownership on every path: `CC_OWNS` on a local, a parameter, a function (it returns an owned pointer) or a field,
  and `CC_FREES` on a parameter. `CC-OWN-LEAK`: a path returns while a pointer still owns, overwrites it, or drops the
  value of a `CC_OWNS` function; `CC-OWN-DOUBLE-FREE` and `CC-OWN-USE-AFTER-FREE`.
- Values of the collector: `CC_GC` on a type and `CC_GC_ALLOC` on an allocator (the Boehm allocators are known).
  `CC-OWN-GC-IN-MALLOC` and `CC-OWN-GC-IN-STATIC`: such a value stored in memory from `malloc` or in a static, or a
  static of a collector type.
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
