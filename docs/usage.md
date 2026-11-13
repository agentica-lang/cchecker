# Output, options and exit codes

## Output

A finding is one line, `file:line:column CODE message`, then a summary line and
a line for each stale entry of the baseline (see
[Baseline](suppressions.md#baseline)). `--json` prints one object:

- `clean`;
- `findings`: each has `code`, `tool`, `file`, `line`, `column`, `message`,
  `path` (the call path of a finding of the rules), `source` (the `[library]`
  flag that made it, or `""`) and `root` (where an inferred root comes from, or
  `""`);
- `baselined`, `fixed`, and `stale` (the entries behind `fixed`: `code`, `file`,
  `message` and `count`);
- `errors`: a tool that did not run or could not compile a file (`tool`, `file`
  and `message`);
- `skipped`: the files outside the working directory, which were not run;
- `suppressed` (see [Suppressions](suppressions.md#suppressions));
- `config`: the settings file that was read, or `"defaults"` (see
  [Settings](settings.md));
- `unresolved_callbacks` (see [Roots](settings.md#roots));
- `unchecked_files`: the files not checked because a header they include is not
  found (`file` and `missing`, the header as the `#include` wrote it); they are
  skipped with a warning on standard error and do not change the exit code;
- `version_changes`: the tools whose version is not the one that made the
  baseline (`tool`, `baseline` and `current`; see
  [Baseline](suppressions.md#versions-of-the-tools));
- `folded`: the repeated entries left out (see [Options](#options));
- from the rules, `incomplete_functions` and `skipped_declarations` (see
  [Rules](rules.md)), and `inferred_short_locks`, only with
  `short_lock_sections` on (see [Settings](settings.md)).

## Exit codes

`0` no new findings, `1` new findings (or stale entries of the baseline with
`--strict-baseline`, and then `clean` is false), `2` a usage error or a tool
error.

A tool error is a tool that is missing, ends in a timeout or exits with a
non-zero code, except for the `1` of a compiler that found errors in the file. A
file that does not compile is an error, never a finding (gcc 14 refuses an
implicit function declaration, for example). gcc reports its analyzer only
(`CC-GCC-ANALYZER-...`): the other warnings (`-Wall`) are not findings, nor are
they for clang-tidy.

`-Werror` in the flags of a database does not turn the other gcc warnings into
tool errors: cchecker adds `-Wno-error` after the flags, and
`-Werror=analyzer-...` stays an error, which is a finding. A gcc that exits with
`1` after analyzer errors counts as a finding only when it ends with `cc1: some
warnings being treated as errors`; a `cc1` killed halfway prints `gcc: fatal
error: Killed signal terminated program cc1`, and that is a tool error.

Colours and links are off whatever the project says (`--use-color=false` for
clang-tidy, `-fdiagnostics-color=never -fdiagnostics-urls=never` for gcc and
`-fno-color-diagnostics` for the clang of the rules, after the flags of the
build). A line of a tool that looks like a diagnostic but that cchecker cannot
read is a tool error, so a lost finding never looks like a clean run. The tools
run with `LC_ALL=C`, so the messages are in English on any machine.

## Files and codes

Only the C files of a database are run (a `.cc` or `.S` entry is ignored, and a
run that ignored one is not a full run: it keeps the baseline entries of
everything it did not name). The paths are relative to the working directory: a
file outside it is skipped (a line on standard error and `skipped` in `--json`),
and a finding in a header outside it (a system or third-party header) is
dropped.

A code is stable: a baseline holds it. `CC-GCC-` is followed by the gcc warning
option in capitals (`-Wanalyzer-malloc-leak`, also as
`-Werror=analyzer-malloc-leak`, is `CC-GCC-ANALYZER-MALLOC-LEAK`), and
`CC-TIDY-` by the clang-tidy check (`clang-analyzer-unix.Malloc` is
`CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC`). A diagnostic without a name is
`CC-GCC-WARNING` or `CC-TIDY-WARNING`. The codes of the rules are in
[Rules](rules.md) and [Ownership](ownership.md), and `CC-UNUSED-IGNORE` in
[Suppressions](suppressions.md#suppressions).

## Options

| Option | |
|---|---|
| `-p, --compile-commands PATH` | the compile database: a file or its folder (default: `compile_commands.json` here) |
| `-t, --tools LIST` | `gcc`, `clang-tidy` and `rules`, comma separated (default all three) |
| `--checks LIST` | the clang-tidy checks, after those of a `.clang-tidy` file; default below |
| `-j, --jobs N` | tool runs at once (default: the number of cores) |
| `--timeout SECONDS` | for one tool on one file (default 300); a timeout is a tool error |
| `-b, --baseline FILE`, `--update-baseline`, `--strict-baseline` | see [Baseline](suppressions.md#baseline) |
| `--exclude LIST` | files or folders to skip, comma separated (`src/vendor`, `./gen/a.c`): whole path parts |
| `--gcc PROGRAM`, `--clang-tidy PROGRAM` | the programs to run, for a versioned name such as `gcc-14` |
| `--clang PROGRAM` | the clang that dumps the AST for the rules |
| `--json` | one JSON object |
| `-c, --config FILE` | the settings file (see [Settings](settings.md)) |
| `--no-infer` | no roots inferred from the callbacks of libuv (see [Roots](settings.md#roots)) |
| `--all-paths` | a finding of the rules for each bad call that a root reaches, not only the nearest (see [Rules](rules.md#effects)) |

An option value can be the next word even when it starts with `-`, as with
getopt (`--checks '-*,bugprone-*'`).

An entry that repeats a file (the same file and folder with the same flags, from
the database or the FILEs) is left out and counted in `folded`; the flags that
do not tell two entries apart are in [`[database]`](settings.md#database).

The default checks are `-*`, `clang-analyzer-core.*`, `clang-analyzer-unix.*`
and `clang-analyzer-security.*` (without `insecureAPI`), and the bugprone checks
`sizeof-expression`, `integer-division`, `suspicious-memory-comparison`,
`signed-char-misuse`, `misplaced-widening-cast` and `unused-return-value`.

A timeout stops the tool and everything it started (gcc runs `cc1` as a child)
when `timeout` of coreutils is installed, and kills what ignores the signal two
seconds later. Without it (macOS has none) only the tool itself is stopped. A
SIGINT to cchecker stops the tool that is running the same way: with `timeout`
the tool and its children (gcc and its `cc1`) end with it; without it only the
tool itself ends, and a child it started keeps running until it ends by itself.
