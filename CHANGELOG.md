# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- `libuv_callbacks_short` also infers the callbacks of `uv_listen`, the idle, prepare, check and signal handles,
  `uv_tcp_close_reset`, UDP, `uv_getaddrinfo`, `uv_getnameinfo`, `uv_random`, the fs event and poll handles, and the
  `uv_fs_*` requests; the libuv lists match libuv 1.50.
- `--update-baseline` with `-c FILE` is refused when the file leaves out a `short` or `hot` name of `[roots]` of the
  project settings, and the refusal names only its causes.
- The `first:` unresolved callback shown is one inside the working directory when there is one.
- The note about a missing `[tool.cchecker]` table is shown only for a `-c` file that has a `name`, as a manifest does.
- `CC_IGNORE` takes codes of the rules only (another code is a usage error), and each code of a suppression is used
  on its own: a stale second code is `CC-UNUSED-IGNORE`.
- Suppression comments read `///`, `//!` and tabs between codes, and refuse near-miss markers (`ignored`).
- The rules run 2.6 times faster with 44% less memory (the 84 files of the VM of Agentica at -j 2: 47.0 s and 732 MB
  before, 17.9 s and 411 MB now): a native module in C scans clang's AST. `-j` defaults to the number of cores, and
  the jobs of the largest files start first.
- A `uv_fs_*` call run at once whose libc call does not block (`uv_fs_close`, `uv_fs_stat`,
  `uv_fs_unlink`, `uv_fs_mkdir`, ...) is a system call (`CC-EFFECT-HOT-SYSCALL`), no longer a blocking call
  (`CC-EFFECT-SHORT-BLOCKS`): a baseline that holds such a finding counts it fixed.

### Added

- Assumptions of a project: `CC_ASSUME_SHORT` and `[assume] short` name a function that counts as fine for
  `CC_SHORT` (the short rule does not walk into it); `CC_STOP` and `[assume] stop` one that no rule walks into. A name
  of `[assume]` that no function of the compile database declares is an error.
- `open` and `openat` with `O_NONBLOCK`, and `recv`, `send`, `recvfrom` and `sendto` with `MSG_DONTWAIT`, are not
  blocking for `CC_SHORT` when the flag is a constant, with the values of the target (Linux and macOS);
  `[library] libc_nonblocking_flags` turns it off. `open` of a regular file can still wait for the disk.
- `[assume] stop_fields`: the function-pointer fields (`request.call`) whose calls no rule follows.
- Short locks: taking a lock marked `CC_NO_SYSCALL_UNDER()`, or named in `[assume] short_locks` (`queue.mu`), is not
  blocking for `CC_SHORT`.
- A file whose `#include` is not found is not checked, with `cchecker: warning: FILE not checked: HEADER not
  found` and an entry in `unchecked_files` of `--json`; the other files are checked and the exit code does not change.
- `--all-paths`: a finding of the rules for each distinct bad call that a root reaches, each with its shortest path.
  The nearest one keeps its baseline key; the others are keyed by the call their message names.
- The effect walk does not go into a function that is `_Noreturn`, `[[noreturn]]`, `CC_NORETURN`,
  `__attribute__((noreturn))` (also through a typedef) or `__attribute__((cold))`: an error exit. `[effects]
  follow_cold = true` follows it; a `CC_BLOCKING` mark on such a function still counts.
- Settings, read from the first of `-c FILE` (its `[tool.cchecker]` table when it has one), `cchecker.toml`, the
  `[tool.cchecker]` table of `agentica.toml`, and the defaults; `config` in `--json` says which. `[library]` turns the
  families of blocking calls off one by one (`libc_blocking`, `pthread_blocking`, `libuv_blocking`, `libgc_blocking`),
  and `source` in `--json` names the one of a finding. `[roots]` names `CC_SHORT` and `CC_HOT` roots without a mark.
- Inferred roots: a function passed as a callback to a libuv call that runs it on the loop thread is a `CC_SHORT` root
  (`libuv_callbacks_short`, `--no-infer`). Its finding gives the call in `root`; a callback that leads to no function
  is listed in `unresolved_callbacks` of `--json`. `--update-baseline` is refused while `--no-infer` or a `[library]`
  flag set to false turns a check of the rules off.
- The `rules` tool (on by default): one call graph of the project from clang's JSON AST, function pointers included
  where the project stores a function in a field, a variable or a parameter. `CC-EFFECT-SHORT-BLOCKS`: a `CC_SHORT`
  function reaches a blocking call (a `CC_BLOCKING` function, or a known blocking call of libc, pthread or libuv).
  `CC-EFFECT-HOT-ALLOCATES` and `CC-EFFECT-HOT-SYSCALL`: a `CC_HOT` function allocates or makes a system call. The
  printed line and the new `path` field of `--json` give the call path; the baseline matches the message without it.
  A table too large to read that names no function is skipped and counted in `skipped_declarations` of `--json`; one
  that names a function, even past its first million lines, is a tool error.
- The default tools are now `gcc,clang-tidy,rules`, so `clang` is needed too; `--tools gcc,clang-tidy`
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
  value of a `CC_OWNS` function; `CC-OWN-DOUBLE-FREE` and `CC-OWN-USE-AFTER-FREE`. Each side of `?:` and the last
  expression of a statement expression give their own value, `*p` of a `CC_FREES char **p` is the pointer, and a
  pointer freed through its address (`free_and_null(&p)`) is freed or null.
- Values of the collector: `CC_GC` on a type and `CC_GC_ALLOC` on an allocator (the Boehm allocators are known,
  `[library]` `libgc_alloc`).
  `CC-OWN-GC-IN-MALLOC` and `CC-OWN-GC-IN-STATIC`: such a value stored in memory from `malloc` or in a static, or a
  static of a collector type, also through a typedef of a pointer. A store of `NULL` or `0` is no such value.
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
