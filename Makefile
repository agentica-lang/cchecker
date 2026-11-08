# The check, the format check and the tests. They need `agentica` (the release pinned in .github/workflows/ci.yml) and,
# for the tests, gcc, clang and clang-tidy on PATH.

JOBS ?= 4

.PHONY: check fmt-check test test-slow

# The Agentica files of the repository, named so that nothing else under the root is read.
SOURCES = cchecker.agc src specs test

check:
	@agentica check $(SOURCES)

# `agentica fmt --check` lists the files that `agentica fmt` would change, and fails if there are any.
fmt-check:
	@agentica fmt --check $(SOURCES)

# The features of specs/ and the unit tests of test/, up to JOBS files at once, without the scenarios tagged @slow. Run
# it from the root of the repository: the steps of the features start cchecker from there. `--tags` leaves the unit
# tests out, so they run on their own.
test:
	@agentica test --jobs $(JOBS) --tags "not @slow" specs
	@agentica test --jobs $(JOBS) test

# The scenarios tagged @slow (large generated inputs with bounds on time and memory), one file at a time so that the
# bounds hold: the slow job of CI.
test-slow:
	@agentica test --tags "@slow" specs

# The Agentica commit that `make bench` checks: the merge of 0.26.2.
AGENTICA_BENCH_COMMIT ?= fe9b9bdcf7e042d1d139d6c105e1b6457944ca93
# Tool runs at once in the bench; empty is cchecker's default, the number of cores.
BENCH_JOBS ?=

.PHONY: bench

# The rules on the C VM of Agentica (bench/run.sh): its wall time and peak RSS. It fetches Agentica into .bench/.
bench:
	@sh bench/run.sh $(AGENTICA_BENCH_COMMIT) $(BENCH_JOBS)
