# The check, the format check and the tests. They need `agentica` (the release pinned in .github/workflows/ci.yml) and,
# for the tests, gcc, clang and clang-tidy on PATH.

JOBS ?= 4

.PHONY: check fmt-check test

# `agentica check` with no path checks every .agc file of the repository.
check:
	@agentica check

# `agentica fmt --check` lists the files that `agentica fmt` would change, and fails if there are any.
fmt-check:
	@agentica fmt --check

# The features of specs/ and the unit tests of test/, up to JOBS files at once. Run it from the root of the repository:
# the steps of the features start cchecker from there.
test:
	@agentica test --jobs $(JOBS)
