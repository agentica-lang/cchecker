# The check, the format check and the tests. They need `agentica` (the release pinned in .github/workflows/ci.yml) and,
# for the tests, gcc, clang and clang-tidy on PATH.

JOBS ?= 4

.PHONY: check lint fmt-check test test-slow native deps header header-check

# The Agentica files of the repository, named so that nothing else under the root is read.
SOURCES = cchecker.agc src specs test

# `agentica check`, then the style suggestions of `agentica lint`: `--strict` makes a suggestion fail the target.
check: deps
	@agentica check $(SOURCES)
	@$(MAKE) --no-print-directory lint

lint: deps
	@agentica lint --strict $(SOURCES)

# `agentica fmt --check` lists the files that `agentica fmt` would change, and fails if there are any.
fmt-check:
	@agentica fmt --check $(SOURCES)

# The features of specs/ and the unit tests of test/, up to JOBS files at once, without the scenarios tagged @slow. Run
# it from the root of the repository: the steps of the features start cchecker from there. `--tags` leaves the unit
# tests out, so they run on their own.
test: deps native
	@agentica test --jobs $(JOBS) --tags "not @slow" specs
	@agentica test --jobs $(JOBS) test

# The scenarios tagged @slow (large generated inputs with bounds on time and memory, and the property tests on many
# cases), one file at a time so that the bounds hold: the slow job of CI.
test-slow: deps native
	@agentica test --tags "@slow" specs

# The packages of agentica.lock into deps/: prop (property tests) and native-gen (`make header`). cchecker itself needs none.
deps:
	@agentica install > /dev/null

# The C header of the native module (the wrappers, the argument checks and the tables), made from the `extern module`
# block of src/scan.agc by native-gen (a dependency, in deps/). Make it again after each change to the block;
# `header-check` fails when the committed one is stale.
header: deps
	@agentica deps/native-gen/cli.agc src/scan.agc --output native/cchecker_scan_native.h

header-check: deps
	@agentica deps/native-gen/cli.agc src/scan.agc --output native/cchecker_scan_native.h --check

# One run of cchecker builds its native module (agentica.toml) into the build cache before the tests start many runs
# at once: on an empty cache, two runs that build it together can fail to make the same folder.
native:
	@agentica cchecker.agc --help > /dev/null

# The Agentica commit that `make bench` checks: the merge of 0.26.2.
AGENTICA_BENCH_COMMIT ?= fe9b9bdcf7e042d1d139d6c105e1b6457944ca93
# Tool runs at once in the bench; empty is cchecker's default, the number of cores.
BENCH_JOBS ?=

.PHONY: bench

# The rules on the C VM of Agentica (bench/run.sh): its wall time and peak RSS. It fetches Agentica into .bench/.
bench:
	@sh bench/run.sh $(AGENTICA_BENCH_COMMIT) $(BENCH_JOBS)
