# Output, options and exit codes

## Output

A finding is one line, `file:line:column CODE message`, then a summary line and
a line for each stale entry of the baseline (see
[Baseline](suppressions.md#baseline)). `--json` prints one object for tools and
agents: `clean`, `findings` (each has `code`, `tool`, `file`, `line`, `column`,
`message`, `path`, the call path of a finding of the rules, `source`, the
`[library]` flag that made it or `""`, and `root`, where an inferred root comes
from or `""`), `baselined`, `fixed`, `stale` (the entries of the baseline behind
`fixed`: `code`, `file`, `message` and `count`), `errors` (a tool that did not
run or could not compile a file: `tool`, `file` and `message`), `skipped`,
`suppressed` (see [Suppressions](suppressions.md#suppressions)), `config`, the
settings file that was read or `"defaults"` (see [Settings](settings.md)),
`unresolved_callbacks` (see [Roots](settings.md#roots)), `unchecked_files`:
the files that were not checked because a header they include is not found
(`file` and `missing`, the header as the `#include` wrote it), and
`version_changes`: the tools whose version is not the one that made the baseline
(`tool`, `baseline` and `current`; see
[Baseline](suppressions.md#versions-of-the-tools)). A file that was not checked
is skipped with a warning on standard error and does not change the exit code.
The rules also add `incomplete_functions` and `skipped_declarations` (see
[Rules](rules.md)).

## Exit codes

`0` no new findings, `1` new findings (or stale entries of the baseline with
`--strict-baseline`, and then `clean` is false), `2` a usage error or a tool
error. A tool error is a tool that is missing, ends in a timeout or exits with a
non-zero code, except for the `1` of a compiler that found errors in the file (a
file that does not compile is an error, never a finding: gcc 14 refuses an
implicit function declaration, for example). gcc reports its analyzer only
(`CC-GCC-ANALYZER-...`); the other warnings of the build flags (`-Wall`) are not
findings, as they are not for clang-tidy.

`-Werror` in the flags of a database does not turn the other warnings of gcc
into tool errors: cchecker adds `-Wno-error` after the flags, and
`-Werror=analyzer-...` stays an error, which is a finding. A gcc that exits with
`1` after analyzer errors counts as a finding only when it ends with `cc1: some
warnings being treated as errors`; a `cc1` killed halfway prints `gcc: fatal
error: Killed signal terminated program cc1`, and that is a tool error.

Colours and links are off whatever the project says: cchecker gives clang-tidy
`--use-color=false` (over `UseColor: true` in a `.clang-tidy`), and adds
`-fdiagnostics-color=never -fdiagnostics-urls=never` for gcc and
`-fno-color-diagnostics` for the clang of the rules after the flags of the
build. A line of a tool that looks like a diagnostic but that cchecker cannot
read (one with escape sequences) is a tool error, so a lost finding never looks
like a clean run.

## Files

Only the C files of a database are run (a `.cc` or `.S` entry is ignored, and a
run that ignored one is not a full run: it keeps the baseline entries of
everything it did not name). The paths are relative to the working directory: a
file outside it is skipped (a line on standard error and `skipped` in `--json`),
and a finding in a header outside it (a system or third-party header) is
dropped.

## Codes

A code is stable: a baseline holds it. `CC-GCC-` is followed by the gcc warning
option in capitals (`-Wanalyzer-malloc-leak` is `CC-GCC-ANALYZER-MALLOC-LEAK`,
also when `-Werror` made it `-Werror=analyzer-malloc-leak`), and `CC-TIDY-` by
the clang-tidy check (`clang-analyzer-unix.Malloc` is
`CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC`). A diagnostic without a name is
`CC-GCC-WARNING` or `CC-TIDY-WARNING`. The codes of the rules are listed in the
README and described in [Rules](rules.md) and [Ownership](ownership.md).

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

The value of an option can be the next word even when it starts with `-`, as
with getopt: `--checks '-*,bugprone-*'` is `--checks='-*,bugprone-*'`.

The default checks are `-*`, `clang-analyzer-core.*`, `clang-analyzer-unix.*`
and `clang-analyzer-security.*` (without `insecureAPI`), and the bugprone checks
`sizeof-expression`, `integer-division`, `suspicious-memory-comparison`,
`signed-char-misuse`, `misplaced-widening-cast` and `unused-return-value`. The
tools run with `LC_ALL=C`, so the messages are in English on any machine.

A timeout stops the tool and everything it started (gcc runs `cc1` as a child)
when `timeout` of coreutils is installed, and kills what ignores the signal two
seconds later. Without it (macOS has none) only the tool itself is stopped. The
limit: Agentica cannot yet start a child in its own process group, so Ctrl-C on
cchecker does not stop the tools that are running (they end by themselves or at
the timeout); see
[agentica#1204](https://github.com/agentica-lang/agentica/issues/1204).
