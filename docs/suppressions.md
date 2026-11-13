# Baseline and suppressions

## Baseline

```sh
agentica cchecker.agc -p build --baseline cchecker-baseline.json --update-baseline   # writes the file, exit 0
agentica cchecker.agc -p build --baseline cchecker-baseline.json                     # fails on new findings only
```

A finding matches the baseline by its code, its file and its message, never its
line. The file holds a count for each kind, so a second finding of a kind the
baseline holds once is new. The file is read before any tool runs, and written
in one rename.

A run covers the tools and the files whose job ended well. Only a full run
(every file of a database, with no `--exclude`, no FILE subset, no skipped file
and no failed job) covers the headers and the files that left the database.
`fixed` counts the accepted findings of that scope that no tool found this time,
and `--update-baseline` replaces the entries of that scope and keeps the others,
so `--tools gcc` or a subset of FILEs updates only what it ran. A header that
the run did not name keeps the larger count of its entry (other flags can show
other findings in it); only a full run lowers it.

`--update-baseline` refuses to write, exits `2` and leaves the file as it was
when a tool failed, when the database has a file that was skipped (outside the
working directory), with `--checks` (a baseline made with other checks would
lose the findings of the default ones), and, when the rules run, with
`--no-infer`, a `[library]` flag set to false, or a file of `-c` that leaves out
a name of `short` or `hot` of the project's `[roots]` (only `[roots]` is
compared, not `follow_cold` or `[assume]`).

A baseline entry whose finding is gone is stale: a new finding of the same code,
file and message would match it later and be accepted unseen. A run names each
stale entry of its scope (the entries that `fixed` counts and
`--update-baseline` drops): one line each after the summary, and `stale` in
`--json`, with the `count` that was not found again. With `--strict-baseline`
they make the run exit `1` (and `clean` false); an entry outside the scope never
fails the run. `--strict-baseline` needs `--baseline` and the default `--checks`
(fewer checks make the entries of the others look stale), and does not go with
`--update-baseline`. With a check of the rules off (`--no-infer`, a `[library]`
flag set to false, a file of `-c` that leaves out the project's `[roots]`), the
stale entries of the rules do not fail the run, with a warning on standard
error; those of the other tools still do.

### Versions of the tools

The findings of `gcc -fanalyzer` and `clang-tidy` change with the version of the
tool. An `--update-baseline` of every file (no FILE and no `--exclude`) writes
the first line of `--version` of each tool it ran into `tools` of the file
(`gcc`, `clang-tidy`, and `clang` for the rules):

```json
{"version": 1, "tools": {"clang":"Debian clang version 19.1.7 (3+b1)","clang-tidy":"Debian LLVM version 19.1.7","gcc":"gcc (Debian 14.2.0-19) 14.2.0"}, "findings": [...]}
```

A run with a tool of another version prints a warning on standard error, before
the summary, that names both lines; `version_changes` of `--json` lists them.
Versions are compared by their number (`14.2.0`), so another build of the same
version (Debian and Ubuntu) is no change. It is not an error: the counts decide
the exit code. When the run also has stale entries, the warning says they may
come from the change: write the baseline again with the tools of the project
(the ones CI uses) before you trust `--strict-baseline`.

Only the tools that the run ran are compared, and a tool that prints no version
is not. A version is written only by an update of every file (`--tools gcc`
counts as every file of gcc; FILEs and `--exclude` do not): a partial update
keeps the stored versions. After an update of every file, a tool that ran and
printed no version loses its stored one (the update says so on standard error),
and a tool that did not run keeps it. A baseline with no `tools` reads with no
warning, and the next update of every file adds them.

## Suppressions

A finding that is a false positive is suppressed next to the code, with the
reason. A comment that trails code holds for the findings of its line; a comment
alone on its line holds for its line and the line below it. Only a comment that
starts with `cchecker: ignore` counts (not a string or a comment that mentions
it); a doc comment (`///`, `//!`, `/**`) and a line inside a block comment that
starts with it count too, as the line of that comment. It takes one or more
codes, separated by commas or blanks, each of a tool (`CC-GCC-`, `CC-TIDY-`,
`CC-EFFECT-`, `CC-PATH-` or `CC-OWN-`); a code that ends with `*` is a prefix (a
`*` anywhere else is a usage error, and so is a word that only starts with
`ignore`, such as `ignore:` or `ignored`):

```c
/* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: conn_free frees it through the struct */
p = malloc(n);
q = malloc(n); // cchecker: ignore CC-GCC-ANALYZER-*, CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC: same as above
```

A finding of the rules belongs to a function:
`CC_IGNORE("CC-EFFECT-SHORT-BLOCKS", "reason")` on any declaration of the
function suppresses it (see [Annotations](rules.md#annotations)). It takes codes
of the rules only (checked when the rules run, so a run with `--tools gcc` does
not see a wrong one). A suppression without a code or a reason, or with a code
of no tool, is a usage error (exit 2).

When two suppressions hold for a finding, the reason of the nearer one is shown,
and both count as used. `--json` lists the suppressed findings under
`suppressed`, each with its `reason`, and the summary line counts them.
Suppressions apply before the baseline, so a suppressed finding never goes into
it.

| Code | |
|---|---|
| `CC-UNUSED-IGNORE` | a code of a suppression matches no finding, once the run covered the tool of that code on that file (for the rules, a full run of a compile database) |

It is at the comment or the function, one for each suppression, naming its stale
codes. It never goes into the baseline: the fix is to edit or remove the
comment.

A suppression is per code, not per message: one `CC-GCC-ANALYZER-MALLOC-LEAK` on
a line hides every leak of that line, a new one too, so name only the codes that
fire there. A finding is where its tool puts it: gcc reports one inside a macro
at the line of the `#define`, so the comment goes there, not at the use. A
suppression in a block that a configuration leaves out (`#ifdef` of a macro that
is not defined) is reported unused on a run of that configuration. A suppression
in a header is never reported unused: a header is read through the files that
include it, each with its own configuration. A `//` comment that ends with `\`
goes on to the next line, and that line counts as a line of the comment.
