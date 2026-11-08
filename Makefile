# The check, the format check and the tests. They need `agentica` (the release pinned in .github/workflows/ci.yml) and,
# for the tests, gcc, clang and clang-tidy on PATH.

JOBS ?= 4

.PHONY: check fmt-check test

# The Agentica files of the repository, named so that nothing else under the root is read.
SOURCES = cchecker.agc src specs test

check:
	@agentica check $(SOURCES)

# `agentica fmt --check` lists the files that `agentica fmt` would change, and fails if there are any.
fmt-check:
	@agentica fmt --check $(SOURCES)

# The features of specs/ and the unit tests of test/, up to JOBS files at once. Run it from the root of the repository:
# the steps of the features start cchecker from there.
test:
	@agentica test --jobs $(JOBS) specs test

# The Agentica commit that `make bench` checks: the merge of 0.26.2.
AGENTICA_BENCH_COMMIT ?= fe9b9bdcf7e042d1d139d6c105e1b6457944ca93
# Tool runs at once in the bench; empty is cchecker's default, the number of cores.
BENCH_JOBS ?=

.PHONY: bench

# The rules on the C VM of Agentica (bench/run.sh): its wall time and peak RSS. It fetches Agentica into .bench/.
bench:
	@sh bench/run.sh $(AGENTICA_BENCH_COMMIT) $(BENCH_JOBS)
