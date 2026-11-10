# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **Breaking:** the ownership rules follow the `CC_OWNS` fields of a local struct up to where the struct escapes (its
  address passed, a copy, a by-value argument, a return, `p = q`), and hand them on there: a leak before the escape,
  or a field that still owns when the whole struct gets a new value, is a CC-OWN-LEAK. Run `--update-baseline` once
  after upgrading.
- **Breaking:** a local struct with a `cleanup` function, or whose `CC_OWNS` field has its address taken
  (`free_and_null(&p.left)`, `take(&p.left)`), is followed too; the cleanup function, `pair_free(&p)` at a `CC_FREES`
  parameter, `memset(&p, 0, sizeof p)` and `p = (struct pair){...}` free or clear its fields. A field freed twice, or
  one that still owns at a clear, is a finding. Run `--update-baseline` once after upgrading.
- **Breaking:** the ownership rules find the struct of a local variable, an initializer and a compound literal by its
  declaration, as C finds a tag or a typedef, not by its name: a struct declared in a function body, an unnamed one and
  one that shadows another of the same name are followed, and an initializer of a union or of an unnamed member hands
  its pointer on. Run `--update-baseline` once after upgrading.
- **Breaking:** a `CC_OWNS` field of a local struct set from a local (`p.left = b`, `{ .left = b }`) stands for the
  local: freeing both is a CC-OWN-DOUBLE-FREE, and when the struct escapes the local is lent with it
  (`find(&key); free(name);` is clean). A field or a local that gets a pointer already freed or handed on
  (`free(b); char *c = b;`) is a CC-OWN-USE-AFTER-FREE, and a call that clears only an alias (`zap(&c)`,
  `zap(&p.left)`) frees the pointer it stands for. Run `--update-baseline` once after upgrading.
- **Breaking:** a struct in a local struct by value (`p.inner.left`, up to 8 levels and 16 `CC_OWNS` fields in all;
  over that only its own fields) and a field of an unnamed struct member (`c.buf`) are followed as the fields of the
  struct are: `keep(&p.inner)`, `p.inner = q`, `memset(&p.inner, 0, sizeof p.inner)` and `pair_free(&p.inner)` work on
  the fields of that member, and a nested initializer (`{ .inner = { .left = b } }`) gives each its item. Run
  `--update-baseline` once after upgrading.
- **Breaking:** a local array of structs of a constant size (`struct pair a[2]`, up to 16 `CC_OWNS` fields in all) is
  followed item by item by a constant index (`a[0].left`); an index that is not a constant, the array read whole
  (`keep(a)`, `a + 1`) or `&a[0]` hands every item on, and `memset(a, 0, sizeof a)` clears it. Run
  `--update-baseline` once after upgrading.
- **Breaking:** `CC_OWNS` on a struct parameter passed by value (`void f(CC_OWNS struct pair p)`) says that the
  function owns its `CC_OWNS` fields from the entry (`p.left`), not the struct as one pointer; a caller that passes a
  struct there hands its fields on. Run `--update-baseline` once after upgrading.
- The items of `p = (struct pair){...}` that read a field of `p` (`p.left ? p.left : make(n)`) are read before the
  store, and a `case` or `default` label inside a block of a `switch` keeps the pointers of that block, as a `goto`
  into it does.

## [0.4.0] - 2026-11-09

### Added

- The docs as a site, <https://agentica-lang.github.io/cchecker/>, with search and a Markdown copy of each page.
- `[assume] owned_locks` names the pointer fields and globals that point to a mutex of their own
  (`lock.mutex`): the inference of short locks gives such a lock the class of the pointer instead of stopping.

### Changed

- **Breaking:** cchecker needs Agentica 0.27.0 or later (native-gen makes the C side of its scan module).
- **Breaking:** the ownership rules follow the `CC_OWNS` fields of a local struct that the function uses only field by
  field (`p.left`, also from an initializer): a field that is not freed or handed on is a CC-OWN-LEAK, where a store
  into it used to hand the pointer on. Run `--update-baseline` once after upgrading.
- **Breaking:** after `old = p;`, a new value of `p` (`p = make()`, `p = NULL`, `take(&p)`) leaves the old pointer to
  `old`: its leak is reported on `old`, no longer as an overwrite of `p`. Run `--update-baseline` once after upgrading.
- A leak of a pointer declared in an inner block is reported where the path leaves the block (its end, a `break`,
  `continue`, `goto` or `return`), not at the end of the function.
- The path rules forget a condition after its last test: many independent flags (`if (a) lock(); if (a) unlock();`)
  no longer multiply the states, nor fall back to the walk without conditions, which gave false findings.

### Fixed

- The TAKE_PTR idiom (`old = p; p = NULL;`), and a pointer that an initializer or a compound literal puts in a
  `CC_OWNS` field, are no longer a false CC-OWN-LEAK or CC-OWN-DOUBLE-FREE.
- A local that shadows another (a parameter, a global, a local of an outer block) has its own state, so it no longer
  gives false CC-OWN or lock findings or hides real ones.
- A statement expression returned, passed to a call or in a `?:` (`return ({ ...; p; })`, `free(({ ...; p; }))`) hands
  on or frees `p`: no longer a false CC-OWN-LEAK.
- A statement-expression macro used many times into one variable (`s = TAKE(); if (s) free(s);`) no longer leaves the
  function in `incomplete_functions`.

## [0.3.0] - 2026-11-09

### Added

- `waitpid`, `wait3`, `wait4` and `waitid` with `WNOHANG` are not blocking calls for `CC_SHORT`
  (`libc_nonblocking_flags`).
- The flag of `libc_nonblocking_flags` may be in a local variable that gets only constants and gets one before the
  call on every path (`options = WNOHANG; waitpid(pid, &status, options)`).
- `[assume] nonblocking = ["uv__read"]`: the calls on a descriptor (`read`, `write`, `recv`, `send`, `accept`, ...)
  that these functions make are not blocking for `CC_SHORT`, for code whose descriptors are all non-blocking.
- `[assume] acquires` and `releases` (`"my_lock(0)"`, `"name@path(N)"`) mark a lock wrapper of code that cannot be
  edited as `CC_ACQUIRES` and `CC_RELEASES` do, with the parameter that holds the lock. `short_locks` takes the same
  `name(N)` for a wrapper whose lock cannot be named: every lock taken through it is short.
- `[database] fold_ignoring = ["NAME"]`: two entries of one file that differ only in those defines (any value) are
  checked once, the first of the database, like the `-D<target>_EXPORTS` of a shared library (libuv's
  `BUILDING_UV_SHARED`). A define that changes the C the rules read hides it from the entries left out.
- `[assume] stop_calls = ["caller>callee"]` cuts the calls of `callee` in `caller` out of the call graph, for every rule
  that walks it (effects, the lock rules' system path, the inference of `may_jump_callers`); the callee stays reachable
  from its other callers, where `stop` removes it for all. Each side takes `name@path`, and a pair that matches no
  call is exit 2.
- `uv_walk`: its callback, and a function stored in the `exit_cb` of `uv_process_options_t`, are `CC_SHORT` roots like the
  other callbacks of libuv that run on the loop (`libuv_callbacks_short`).
- `[roots]` and `[assume]` (`short`, `stop`, `may_jump`, `jumps`, `catches`, `jump_releases`) take `name@path`, the
  function of that name whose file ends with `path`, so a name shared by static functions of several files no longer
  marks all of them.
- `CC_JUMPS` and `[assume] jumps`: a call of a function that always jumps out and never returns (an interpreter's raise
  with `longjmp`) is a way out of its caller, where a pointer that still owns is `CC-OWN-LEAK` and a lock held is
  `CC-PATH-LOCK-NOT-RELEASED`, and the path ends there.
- A function that calls a function that may jump out or jumps may jump out too, unless it calls `setjmp` or
  `sigsetjmp` or is marked `CC_CATCHES` (or `[assume] catches`): only the raisers need a mark. The last step of `path`
  names the chain of calls (`may jump in path_of (as_string, wrong_tag)`), and such a finding has
  `"source":"may_jump_callers"`; `[library] may_jump_callers = false` turns the inference off. **Breaking:** a project
  with `CC_MAY_JUMP` marks may get new findings that its baseline does not hold.
- `CC_JUMP_RELEASES` and `[assume] jump_releases` on a `CC_ACQUIRES` or `CC_RELEASES` helper whose lock the catcher
  of a jump gives back: a jump with that lock held or released is no lock finding when the function takes and
  releases it only through such helpers; a return still is.
- Experimental, off by default: with `[library] short_lock_sections = true`, a lock whose critical sections reach no
  blocking call, in a full run of a compile database, is short for `CC_SHORT`, as with `[assume] short_locks`;
  `inferred_short_locks` of `--json` lists them and the text report counts them. It may call a lock short wrongly in
  cases it does not handle yet; turn it on only to try it.

### Changed

- `uv_run` with a constant `UV_RUN_NOWAIT` is no longer a blocking call for `CC_SHORT` (`libc_nonblocking_flags`);
  `UV_RUN_ONCE`, `UV_RUN_DEFAULT` and a mode in a variable still are.
- **Breaking:** `CC_MAY_JUMP` or `[assume] may_jump` on a function that never returns (`_Noreturn`, `CC_NORETURN`) now
  means `CC_JUMPS`: its calls are checked as a way out, where before they only ended the path and found nothing. A
  project with that combination may get new findings that its baseline does not hold.
- A file listed more than once with the same flags is checked once; flags that differ only by `-fPIC`, `-fPIE` and
  CMake's `-D<target>_EXPORTS` count as the same (a static and a shared library of CMake), any other define does not
  (libuv's `BUILDING_UV_SHARED` keeps both entries). `folded` of `--json` counts the repeated entries left out.

### Fixed

- A `.clang-tidy` with `UseColor: true`, or a `-fdiagnostics-color=always` or `-fdiagnostics-urls=always` in the
  flags, no longer drops or renames the findings of that tool without a word: cchecker turns colours and links off
  after the project's settings, and a diagnostic line that it cannot read is a tool error (exit 2).
- A value that starts with `-` is taken from the next word, as getopt does: `--checks '-*,bugprone-*'` works like
  `--checks='-*,bugprone-*'` instead of saying that `--checks` needs a value (and `-j -1` now says that `-1` is too
  small).

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

[Unreleased]: https://github.com/agentica-lang/cchecker/compare/0.4.0...HEAD
[0.4.0]: https://github.com/agentica-lang/cchecker/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/agentica-lang/cchecker/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/agentica-lang/cchecker/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/agentica-lang/cchecker/releases/tag/0.1.0
