# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.8.0] - 2026-11-13

### Added

- `CC_ACQUIRES_IF(lock, *flag)`, `CC_RELEASES_IF(lock, flag)` and `CC_TRIES(lock)`, and `[assume] tries`: lock helpers
  that take the lock only where they set a flag (`bool *locked`), release it only where a flag is not 0, or take it
  where they return 0. A call takes the side of the flag or the result, which later tests of the flag follow.
  On the side where the helper does nothing to its lock, the rules on what runs under a lock skip its releases of its
  own lock and still read the rest of its body.

### Changed

- **Breaking:** needs Agentica 0.31.0 (`agentica = "0.31.0"` in `agentica.toml`; an older one stops with
  `PKG-AGENTICA-TOO-OLD`), and the packages `prop-0.3.0` and `native-gen-0.4.0`. CI tests with Agentica 0.31.0. The
  findings, the codes and the options are the same.

## [0.7.0] - 2026-11-12

### Changed

- **Breaking:** the result of a trylock kept in a local variable (`r = pthread_mutex_trylock(&q->mu); if (r == 0)`,
  also `bool ok = ... == 0` and `if ((r = ...) != 0)`) takes the lock where the call gave 0, and a later test of the
  variable (`!r`, `r == EBUSY`, `switch (r)`, a copy `int busy = r;`) goes the same way; a new value of the variable
  forgets it, and a release where the call failed shows the path from the call (`6:11 fails`). A whole number written
  to a local whose test guards a lock or a way out (`taken = true`) is a value the path knows, so a trylock spin with a
  blocking fallback passes; a local whose address is taken, a `volatile` and a `static` one never are. Run
  `--update-baseline` once after upgrading.
- A function walked again without its conditions, as its paths take more than 200 000 states, is listed in
  `incomplete_functions`.

## [0.6.1] - 2026-11-12

### Fixed

- The sources compile with the next Agentica, which refuses a method call right after the `end` of a `do` block
  (`CHECK-CHAIN-AFTER-END`); they still need Agentica 0.29.0 or later.
- `c = b; zap(&b);` (a call that frees and clears `b` through its address) no longer clears `c` too: `free(c)` or
  `work(c)` after it is a CC-OWN-DOUBLE-FREE or a CC-OWN-USE-AFTER-FREE.
- A self-assignment of an owning pointer or field (`p.right = p.right`) is no longer a false CC-OWN-LEAK.

Older versions (0.6.0 and before) are in the release notes: https://github.com/agentica-lang/cchecker/releases

[Unreleased]: https://github.com/agentica-lang/cchecker/compare/0.8.0...HEAD
[0.8.0]: https://github.com/agentica-lang/cchecker/compare/0.7.0...0.8.0
[0.7.0]: https://github.com/agentica-lang/cchecker/compare/0.6.1...0.7.0
[0.6.1]: https://github.com/agentica-lang/cchecker/compare/0.6.0...0.6.1
