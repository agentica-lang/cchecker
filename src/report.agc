## What a run prints.

import {Entry, VersionChange} from "baseline"
import {Finding, IncompleteFunction, ToolError, UncheckedFile, UnresolvedCallback} from "findings"
import {Suppressed} from "suppressions"

## The result of a run. `findings` are the new ones; `baselined` were accepted by the baseline, and `fixed` are
## accepted findings of the tools and files of the run that no tool found this time. `skipped` counts the files that
## were left out because they are outside the working directory, and `skipped_declarations` the declarations the rules
## did not read because they are too large and name no function (tables of numbers, mostly). `incomplete_functions`
## are the functions with more paths than the path rules follow. `suppressed` are the findings that a suppression
## took out. `config` is the settings file that was read, or "defaults". `unresolved_callbacks` are the callbacks of
## libuv calls that the inference of roots could not follow to a function. `unchecked_files` are the files that were
## not checked because a header they include is not found. `stale` are the entries of the baseline behind `fixed`,
## and `failing` those of them that fail the run (`--strict-baseline`); `rules_off` says that a check of the rules was
## off, so the entries of the rules did not fail it and an update needs every check of the rules on. `version_changes`
## are the tools that ran with another version than the one that made the baseline. `folded` counts the entries of
## the compile database that were not run because they repeat a file with the same flags (see `Commands.fold`).
## `inferred_short_locks` are the classes of the locks that the rules found short by their critical sections, or none
## when that inference is off (then `--json` leaves the key out).
struct Report
  findings: List[Finding]
  baselined: Int
  fixed: Int
  errors: List[ToolError]
  skipped: Int
  skipped_declarations: Int = 0
  incomplete_functions: List[IncompleteFunction] = []
  suppressed: List[Suppressed] = []
  config: String = "defaults"
  unresolved_callbacks: List[UnresolvedCallback] = []
  unchecked_files: List[UncheckedFile] = []
  stale: List[Entry] = []
  failing: List[Entry] = []
  rules_off: Bool = false
  version_changes: List[VersionChange] = []
  folded: Int = 0
  inferred_short_locks: Optional[List[String]] = none
end

## Returns the report for people: one line for each finding, a summary line, then one line for each stale entry of
## the baseline and, when they fail the run, how to drop them.
def text(report: Report) -> String
  lines = report.findings.map do |f| "#{f.file}:#{f.line}:#{f.column} #{f.code} #{f.message}#{path_text(f)}" end
  lines = lines.push(summary(report)).concat(report.stale.map(&stale_line))
  if failed_stale?(report)
    gone = report.failing.reduce(0) do |total, entry| total + entry.count end
    how = "--update-baseline"
    if report.rules_off
      how = "--update-baseline with every check of the rules on"
    end

    lines = lines.push(
      "cchecker: --strict-baseline: the baseline accepts #{gone} #{plural(gone, "finding")} that the run did not " +
      "find again; run #{how} to drop them",
    )
  end

  lines.join("\n")
end

## Returns whether the stale entries of the baseline fail the run.
def failed_stale?(report: Report) -> Bool = not report.failing.empty?

## Returns the report as one JSON object for tools and agents.
def json(report: Report) -> String
  encoded = JSON.encode(
    Encoded(
      clean: report.findings.empty? and report.errors.empty? and not failed_stale?(report),
      findings: report.findings,
      baselined: report.baselined,
      fixed: report.fixed,
      stale: report.stale,
      errors: report.errors,
      skipped: report.skipped,
      skipped_declarations: report.skipped_declarations,
      incomplete_functions: report.incomplete_functions,
      suppressed: report.suppressed,
      config: report.config,
      unresolved_callbacks: report.unresolved_callbacks,
      unchecked_files: report.unchecked_files,
      version_changes: report.version_changes,
      folded: report.folded,
    ),
  )

  # The key of an experimental inference is in the object only when it ran: the object ends with its `}`.
  case report.inferred_short_locks
    some(classes) -> "#{encoded.slice(0, encoded.size - 1)},\"inferred_short_locks\":#{JSON.encode(classes)}}"
    none -> encoded
  end
end

## Returns the lines for standard error: one for each tool error.
def error_lines(report: Report) -> List[String]
  report.errors.map do |e| "cchecker: error: #{e.tool} on #{e.file}: #{e.message}" end
end

## Returns the line for standard error about the tools whose version is not the one that made the baseline, or none.
## The findings of the analyzers change with their version, so the new and fixed ones may come from it.
def version_line(report: Report) -> Optional[String]
  return none if report.version_changes.empty?

  changes = report.version_changes.map do |c| "#{c.tool} was #{c.baseline}, is #{c.current}" end
  changed = changes.join("; ")
  line = (
    "cchecker: warning: the tools are not the ones that made the baseline (#{changed}); " +
    "its new and fixed findings may come from that"
  )

  if not report.stale.empty?
    line = line + ", and so may its stale entries"
  end

  some(line)
end

## Returns the lines for standard error: one for each file that was not checked.
def unchecked_lines(report: Report) -> List[String]
  report.unchecked_files.map do |u| "cchecker: warning: #{u.file} not checked: #{u.missing} not found" end
end

## Returns the line for standard error that says how many locks the rules found short by their critical sections, or
## none.
def inferred_line(report: Report) -> Optional[String]
  classes = report.inferred_short_locks.unwrap_or([])
  count = classes.size
  return none if count == 0

  first = classes.first
  some(
    "cchecker: #{count} #{plural(count, "lock")} found short by #{plural_its(count)} critical sections (first: " +
    "#{first}); --json lists them",
  )
end

## Returns the line for standard error about the callbacks that the inference of roots could not follow, or none.
def unresolved_line(report: Report) -> Optional[String]
  count = report.unresolved_callbacks.size
  return none if count == 0

  # A callback inside the working directory first: its path is the short one, and the code the project can change.
  inside = report.unresolved_callbacks.select do |u| not u.file.start_with?("/") end
  first = inside.concat(report.unresolved_callbacks).first
  some(
    "cchecker: #{count} #{plural(count, "callback")} of a libuv call could not be followed to a function, so " +
    "#{plural_it(count)} no root (first: #{first.call} at #{first.file}:#{first.line}); --json lists them",
  )
end

private

# The JSON form of a report, which says in `clean` whether the run is clean.
struct Encoded
  clean: Bool
  findings: List[Finding]
  baselined: Int
  fixed: Int
  stale: List[Entry]
  errors: List[ToolError]
  skipped: Int
  skipped_declarations: Int
  incomplete_functions: List[IncompleteFunction]
  suppressed: List[Suppressed]
  config: String
  unresolved_callbacks: List[UnresolvedCallback]
  unchecked_files: List[UncheckedFile]
  version_changes: List[VersionChange]
  folded: Int
end

# A stale entry of the baseline: its file, code and message, and how many of it were not found when more than one.
def stale_line(entry: Entry) -> String
  times = ""
  if entry.count > 1
    times = " (#{entry.count} of them)"
  end

  "cchecker: fixed since the baseline: #{entry.file} #{entry.code} #{entry.message}#{times}"
end

# The call path of a finding of the rules, and the place of an inferred root, which the message leaves out.
def path_text(f: Finding) -> String
  return "" if f.path.empty?

  return ": #{f.path.join(" -> ")} (root: #{f.root})" if f.root != ""

  ": #{f.path.join(" -> ")}"
end

def plural_it(n: Int) -> String
  return "it is" if n == 1

  "they are"
end

def summary(report: Report) -> String
  count = report.findings.size
  found_files = report.findings.map do |f| f.file end
  files = found_files.uniq.size
  notes: List[String] = []
  if report.baselined > 0
    notes = notes.push("#{report.baselined} baselined")
  end

  if report.fixed > 0
    notes = notes.push("#{report.fixed} fixed since the baseline")
  end

  if not report.suppressed.empty?
    notes = notes.push("#{report.suppressed.size} suppressed")
  end

  tail = ""
  if not notes.empty?
    tail = " (#{notes.join(", ")})"
  end

  if count == 0 and not report.errors.empty?
    return (
      "cchecker: #{report.errors.size} tool #{plural(report.errors.size, "error")}, the findings are incomplete#{tail}"
    )
  end

  return "cchecker: no new findings#{tail}" if count == 0

  "cchecker: #{count} new #{plural(count, "finding")} in #{files} #{plural(files, "file")}#{tail}"
end

def plural_its(count: Int) -> String
  return "its" if count == 1

  "their"
end

def plural(n: Int, word: String) -> String
  return word if n == 1

  word + "s"
end
