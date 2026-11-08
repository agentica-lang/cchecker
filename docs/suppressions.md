# Baseline and suppressions

## Baseline

```sh
agentica cchecker.agc -p build --baseline cchecker-baseline.json --update-baseline   # writes the file, exit 0
agentica cchecker.agc -p build --baseline cchecker-baseline.json                     # fails on new findings only
```

A finding matches the baseline by its code, its file and its message, never its
line, so edits above it do not break the baseline. The file holds a count for
each kind, so a second finding of a kind the baseline holds once is new. The
file is read before any tool runs, and written in one rename.

A run covers the tools and the files whose job ended well. Only a full run,
which is every file of a database with no `--exclude`, no FILE subset, no
skipped file and no failed job, covers the headers and the files that left the
database. `fixed` counts the accepted findings of that scope that no tool found
this time, and `--update-baseline` replaces the entries of that scope and keeps
the others, so `--tools gcc` or a subset of FILEs updates only what it ran. A
header that the run did not name keeps the larger count of its entry, as other
flags can show other findings in it (`#ifdef`); only a full run lowers it. It
refuses to write, and leaves the file as it was, when a tool failed, when the
database has a file that was skipped (outside the working directory), with
`--checks` (a baseline made with other checks would lose the findings of the
default ones), and, when the rules run, with `--no-infer` or a `[library]` flag
set to false (see [Settings](settings.md)), for the same reason. The exit code
is `2` in each case.

## Suppressions

A finding that is a false positive, where the check cannot be made smarter, is
suppressed next to the code, with the reason. A comment that trails code holds
for the findings of its line; a comment alone on its line holds for its line and
the line below it. Only a comment that starts with `cchecker: ignore` counts
(not a string or a comment that mentions it); a doc comment (`///`, `//!`,
`/**`) and a line inside a block comment that starts with it count too, as the
line of that comment. It takes one or more codes, separated by commas or blanks,
each of a tool (`CC-GCC-`, `CC-TIDY-`, `CC-EFFECT-`, `CC-PATH-` or `CC-OWN-`),
and a code that ends with `*` is a prefix (a `*` anywhere else is a usage error,
and so is a word that only starts with `ignore`, such as `ignore:` or
`ignored`):

```c
/* cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: conn_free frees it through the struct */
p = malloc(n);
q = malloc(n); // cchecker: ignore CC-GCC-ANALYZER-*, CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC: same as above
```

Name only the codes that fire there: each code that matches nothing is reported
(`CC-UNUSED-IGNORE`, below).

A finding of the rules belongs to a function:
`CC_IGNORE("CC-EFFECT-SHORT-BLOCKS", "reason")` on any declaration of the
function suppresses it (see [Annotations](rules.md#annotations)); it takes codes
of the rules only (checked when the rules run, so a run with `--tools gcc` does
not see a wrong one). A suppression without a code or a reason, or with a code
of no tool, is a usage error (exit 2). When two suppressions hold for a finding,
the reason of the nearer one is shown, and both count as used. `--json` lists
the suppressed findings under `suppressed`, each with its `reason`, and the
summary line counts them. A code of a suppression that matches no finding gives
a finding, `CC-UNUSED-IGNORE`, at the comment or the function (one for each
suppression, naming its stale codes), once the run covered the tool of that code
on that file, as the baseline does (for the rules, a full run of a compile
database): a stale one shows when the code changes or a check gets better.
Suppressions apply before the baseline, so a suppressed finding never goes into
it, and neither does a `CC-UNUSED-IGNORE`: the fix is to edit or remove the
comment.

A suppression is per code, not per message: one `CC-GCC-ANALYZER-MALLOC-LEAK` on
a line hides every leak of that line, a new one too. A finding is where its tool
puts it: gcc reports one inside a macro at the line of the `#define`, so the
comment goes there, not at the use. A suppression in a block that a
configuration leaves out (`#ifdef` of a macro that is not defined) is reported
unused on a run of that configuration; a project that checks several
configurations sees it reported in those that skip the block. A `//` comment
that ends with `\` goes on to the next line, and that line counts as a line of
the comment.
